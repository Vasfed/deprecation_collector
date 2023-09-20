# frozen_string_literal: true

require "timecop"

unless ENV["REALREDIS"]
  require "fakeredis"
  require "fakeredis/rspec"
end

begin
  require "rails"
  require "active_support"
rescue LoadError
  puts "No rails"
end

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_group("Lib") { |src| !src.filename.include?("lib/deprecation_collector/web") }
    add_group "Web", "lib/deprecation_collector/web"
    # add_group "Tests", "spec"
    add_filter "spec"
  end
end

require "deprecation_collector"

ENV["RAILS_ENV"] = "test"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:all) do
    DeprecationCollector.instance_variable_set(:@instance, nil)
    DeprecationCollector.instance_variable_set(:@installed, true) # to skip at_exit
    DeprecationCollector.install do |instance|
      instance.storage = DeprecationCollector::Storage::StdErr
      instance.app_revision = "somerevisionabc123"
      instance.app_root = File.expand_path("..", __dir__)
    end
  end
end
