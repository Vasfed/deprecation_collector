# frozen_string_literal: true

# use `bundle _2.3.26_ exec appraisal update` to keep correct version in lock
appraise "rails_none" do
  gem "bundler", "<2.4" # 2.4 needs ruby 2.6+, 2.5 is not dropped yet
  gem "redis", "~>3.3" # also test old redis here
end

# appraise "rails_6" do
#   gem "rails", "~>6.0"
#   gem "sqlite3"
#   gem "redis", "~>4.8"
#   gem "nokogiri", "~>1.15.6" # for ruby 2.7
# end

# appraise "rails_7" do
#   gem "rails", "~>7.0.8"
#   gem "sqlite3"
#   gem "nokogiri", "~>1.15.6" # for ruby 2.7
# end

appraise "rails_71" do
  gem "bundler", "~>2.5"
  gem "rails", "~>7.1.1"
  gem "sqlite3"
end

appraise "rails_72" do
  gem "bundler", "~>2.5"
  gem "rails", "~>7.2.1"
  gem "sqlite3"
end

appraise "rails_80" do
  gem "bundler", "~>2.6"
  gem "rails", "~>8.0.1"
  gem "sqlite3"
end

# NB: after adding appraisals do `appraisal bundle lock --add-platform x86_64-linux` for CI
