# frozen_string_literal: true

require_relative "deprecation_collector/version"
require_relative "deprecation_collector/deprecation"
require_relative "deprecation_collector/collectors"
require_relative "deprecation_collector/storage"
require "time"
require "json"
require "set"

# singleton class for collector
class DeprecationCollector
  @instance_mutex = Mutex.new
  @installed = false
  private_class_method :new

  def self.instance
    return @instance if defined?(@instance) && @instance

    create_instance
  end

  def self.create_instance
    @instance_mutex.synchronize do
      # no real need to reuse the mutex, but it is used only once here anyway
      @instance ||= new(mutex: @instance_mutex)
    end
    @instance
  end

  def self.collect(message, backtrace, realm)
    instance.collect(message, backtrace, realm)
  end

  # inside dev env may be called multiple times
  def self.install
    create_instance # to make it created, configuration comes later

    @instance_mutex.synchronize do
      unless @installed
        at_exit { instance.write_to_redis(force: true) }
        @installed = true
      end

      yield instance if block_given?
      instance.fetch_known_digests

      install_collectors
    end

    @instance
  end

  # NB: count is expensive in production env (but possible if needed) - produces a lot of redis writes
  attr_accessor :raise_on_deprecation, :save_full_backtrace,
                :exclude_realms,
                :app_name, :app_revision, :app_root,
                :print_to_stderr, :print_recurring
  attr_reader :count, :write_interval, :write_interval_jitter, :key_prefix
  attr_writer :context_saver, :fingerprinter

  def initialize(mutex: nil)
    @enabled = true
    @instance_mutex = mutex

    load_default_config
  end

  def load_default_config
    if (redis = defined?($redis) && $redis) # rubocop:disable Style/GlobalVars
      self.redis = redis
    end
    @raise_on_deprecation = false
    @exclude_realms = []
    @ignore_message_regexp = nil
    @app_root = (defined?(Rails) && Rails.root.present? && Rails.root) || Dir.pwd
    # NB: in production with hugreds of workers may easily overload redis with writes, so more delay needed:
    self.count = false
    self.write_interval = 900 # 15.minutes
    self.write_interval_jitter = 60
    self.key_prefix = "deprecations"
    @context_saver = nil
  end

  def redis=(val)
    raise ArgumentError, "redis should not be nil" unless val
    self.storage = DeprecationCollector::Storage::Redis unless storage.respond_to?(:redis=)
    storage.redis = val
  end

  def model=(val)
    require "deprecation_collector/storage/active_record" unless defined?(DeprecationCollector::Storage::ActiveRecord)
    self.storage = DeprecationCollector::Storage::ActiveRecord
    storage.model = val
  end

  def count=(val)
    storage.count = val if storage.respond_to?(:count=)
    @count = val
  end

  def write_interval=(val)
    storage.write_interval = val if storage.respond_to?(:write_interval=)
    @write_interval = val
  end

  def write_interval_jitter=(val)
    storage.write_interval_jitter = val if storage.respond_to?(:write_interval_jitter=)
    @write_interval_jitter = val
  end

  def key_prefix=(val)
    storage.key_prefix = val if storage.respond_to?(:key_prefix=)
    @key_prefix = val
  end

  def storage
    @storage ||= DeprecationCollector::Storage::StdErr.new
  end

  def storage=(val)
    return @storage = val unless val.is_a?(Class)

    @storage = val.new(mutex: @instance_mutex, count: count,
                       write_interval: write_interval, write_interval_jitter: write_interval_jitter,
                       key_prefix: key_prefix)
  end

  def ignored_messages=(val)
    @ignore_message_regexp = (val && Regexp.union(val)) || nil
  end

  def context_saver(&block)
    return @context_saver unless block

    @context_saver = block
  end

  def fingerprinter(&block)
    return @fingerprinter unless block

    @fingerprinter = block
  end

  def app_root_prefix
    "#{app_root}/"
  end

  def cleanup_prefixes
    @cleanup_prefixes ||= Gem.path + [app_root_prefix]
  end

  def collect(message, backtrace = caller_locations, realm = :unknown)
    return if !@enabled || exclude_realms.include?(realm) || @ignore_message_regexp&.match?(message)
    raise "Deprecation: #{message}" if @raise_on_deprecation

    recursion_iterations_detected = backtrace.count { |l| l.path == __FILE__ && l.base_label == __method__.to_s }
    return if recursion_iterations_detected > 1 # we have a loop, ignore deep nested deprecations

    deprecation = Deprecation.new(message, realm, backtrace, cleanup_prefixes)
    fresh = store_deprecation(deprecation, allow_context: recursion_iterations_detected.zero?)
    log_deprecation_if_needed(deprecation, fresh)
  end

  def unsent_data?
    unsent_deprecations.any?
  end

  def count?
    @count
  end

  def write_to_redis(force: false)
    return unless force || @enabled

    storage.flush(force: force)
  end

  # prevent fresh process from wiring frequent already known messages
  def fetch_known_digests
    storage.fetch_known_digests
  end

  def flush_redis(enable: false)
    storage.clear(enable: enable)
  end

  # deprecated, use storage.enabled?
  def enabled_in_redis?
    storage.enabled?
  end

  def enabled?
    @enabled
  end

  def enable
    storage.enable
    @enabled = true
  end

  def disable
    @enabled = false
    storage.disable
  end

  def dump
    read_each.to_a.compact.to_json
  end

  def import_dump(json)
    dump = JSON.parse(json)
    # TODO: some checks

    digests = dump.map { |dep| dep["digest"] }
    raise "need digests" unless digests.none?(&:nil?)

    dump_hash = dump.map { |dep| [dep.delete("digest"), dep] }.to_h

    storage.import(dump_hash)
  end

  def read_each
    return to_enum(:read_each) unless block_given?

    storage.read_each do |digest, data, count, notes|
      yield decode_deprecation(digest, data, count, notes)
    end
  end

  def read_one(digest)
    decode_deprecation(*storage.read_one(digest))
  end

  def delete_deprecations(remove_digests)
    storage.delete(remove_digests)
  end

  def cleanup(&block)
    raise ArgumentError, "provide a block to filter deprecations" unless block

    storage.cleanup(&block)
  end

  protected

  def unsent_deprecations
    storage.unsent_deprecations
  end

  def store_deprecation(deprecation, allow_context: true)
    return if deprecation.ignored?

    deprecation.context = context_saver.call if context_saver && allow_context
    deprecation.custom_fingerprint = fingerprinter.call(deprecation) if fingerprinter && allow_context
    deprecation.app_name = app_name if app_name

    storage.store(deprecation)
  end

  def log_deprecation_if_needed(deprecation, fresh)
    return unless print_to_stderr && !deprecation.ignored?
    return unless fresh || print_recurring

    log_deprecation(deprecation)
  end

  def log_deprecation(deprecation)
    msg = deprecation.message
    msg = "DEPRECATION: #{msg}" unless msg.start_with?("DEPRECAT")
    $stderr.puts(msg) # rubocop:disable Style/StderrPuts
  end

  def decode_deprecation(digest, data, count, notes)
    return nil unless data

    data = JSON.parse(data, symbolize_names: true)
    # this should not happen (this means broken Deprecation#to_json or some data curruption)
    return nil unless data.is_a?(Hash)

    data[:digest] = digest
    data[:notes] = JSON.parse(notes, symbolize_names: true) if notes
    data[:count] = count.to_i if count
    data
  end
end
