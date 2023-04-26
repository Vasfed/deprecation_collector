# frozen_string_literal: true

require "bundler/setup"
require "deprecation_collector"

# rubocop:disable Style/GlobalVars
$redis = Redis.new
DeprecationCollector.install do |instance|
  instance.redis = $redis
  instance.app_revision = "some_revision_in_console"
  instance.count = false
  instance.save_full_backtrace = true
  instance.raise_on_deprecation = false
  instance.write_interval = 1
  instance.exclude_realms = []
  instance.ignored_messages = []
  instance.print_to_stderr = true
end
