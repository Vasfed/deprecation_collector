# frozen_string_literal: true

require_relative "lib/deprecation_collector/version"

Gem::Specification.new do |spec|
  spec.name = "deprecation_collector"
  spec.version = DeprecationCollector::VERSION
  spec.authors = ["Vasily Fedoseyev"]
  spec.email = ["vasilyfedoseyev@gmail.com"]

  spec.summary = "Collector for ruby/rails deprecations and warnings, suitable for production"
  spec.description = "Collects and aggregates warnings and deprecations. Optimized for production environment."
  spec.homepage = "https://github.com/Vasfed/deprecation_collector"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.5.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Vasfed/deprecation_collector"
  spec.metadata["changelog_uri"] = "https://github.com/Vasfed/deprecation_collector/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "sig/**/*", "*.md", "*.txt", "*.gemspec"].select { |filename| File.file?(filename) }
  spec.require_paths = ["lib"]

  spec.add_dependency "redis", ">= 3.0"
end
