# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError # rubocop:disable Lint/SuppressedException
end

task default: %i[spec rubocop]

desc "Compile slim templates (so that slim is not needed as dependency)"
task :precompile_templates do
  require "slim"
  # Slim::Template.new { '.lala' }.precompiled_template
  Dir["lib/deprecation_collector/web/views/*.slim"].each do |file|
    target = file.sub(/\.slim\z/, ".template.rb")
    puts "Compiling #{file} -> #{target}"
    content = Slim::Template.new(file).precompiled_template # maybe send(:precompiled, []) is more correct

    File.write(target, content)
  end
end

Rake::Task[:spec].enhance [:precompile_templates]
Rake::Task[:build].enhance [:precompile_templates]
