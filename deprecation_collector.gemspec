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
  spec.required_ruby_version = ">= 2.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Vasfed/deprecation_collector"
  spec.metadata["changelog_uri"] = "https://github.com/Vasfed/deprecation_collector/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "redis", ">= 3.0"
  spec.add_development_dependency "appraisal"
end
