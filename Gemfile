# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in deprecation_collector.gemspec
gemspec

gem "rake", "~> 13.0"

gem "rack-test"
gem "rspec", "~> 3.0"
gem "timecop"

unless defined?(Appraisal)
  gem "appraisal"

  group :lint do
    gem "rubocop", "~> 1.21"
    gem "rubocop-performance"
    gem "rubocop-rails"
    gem "rubocop-rake"
    gem "rubocop-rspec"
  end

  gem "rails", "~>7.1.1"
  gem "simplecov"
  gem "sqlite3"

  gem "pry"
  gem "pry-byebug"
end

gem "fakeredis"
gem "redis", "~>4.8"

# for web tests
gem "rack"
gem "webrick"

gem "slim" # not used in production, for compiling templates
