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

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_group "Lib", "lib"
    add_group "Tests", "spec"
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

  config.before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    DeprecationCollector.install do |instance| # rubocop:disable RSpec/DescribedClass
      instance.redis = Redis.new
      instance.app_revision = "somerevisionabc123"
      instance.app_root = File.expand_path("..", __dir__)
      instance.count = false
      instance.save_full_backtrace = true
      instance.context_saver do
        { some: "context" }
      end
    end
  end
end
