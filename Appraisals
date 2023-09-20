# frozen_string_literal: true

# use `bundle _2.3.26_ exec appraisal update` to keep correct version in lock
appraise "rails_none" do
  gem "bundler", "<2.4" # 2.4 needs ruby 2.6+, 2.5 is not dropped yet
  # none here
end

appraise "rails_6" do
  gem "rails", "~>6.0"
  gem "sqlite3"
end

appraise "rails_7" do
  gem "rails", "~>7.0"
  gem "sqlite3"
end
