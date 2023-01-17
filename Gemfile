# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in deprecation_collector.gemspec
gemspec

gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"
gem "timecop"

unless defined?(Appraisal)
  group :lint do
    gem "rubocop", "~> 1.21"
    gem "rubocop-performance"
    gem "rubocop-rails"
    gem "rubocop-rake"
    gem "rubocop-rspec"
  end

  gem "rails", "~>6.0.0"
  gem 'simplecov'
end

gem "fakeredis"
gem "redis", "~>4.8"
