# frozen_string_literal: true

require "bundler/setup"
require "deprecation_collector"

$redis = Redis.new # rubocop:disable Style/GlobalVars
DeprecationCollector.install do |instance|
  instance.redis = $redis # rubocop:disable Style/GlobalVars
  instance.app_revision = "some_revision_in_console"
  instance.count = false
  instance.save_full_backtrace = true
  instance.raise_on_deprecation = false
  instance.write_interval = 1
  instance.exclude_realms = []
  instance.ignored_messages = []
  instance.print_to_stderr = true
end
