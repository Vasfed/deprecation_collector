# frozen_string_literal: true

require_relative "deprecation_collector/version"
require_relative "deprecation_collector/deprecation"
require_relative "deprecation_collector/collectors"
require "time"
require "redis"
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
  attr_accessor :count, :raise_on_deprecation, :save_full_backtrace,
                :exclude_realms,
                :write_interval, :write_interval_jitter,
                :app_revision, :app_root,
                :print_to_stderr, :print_recurring
  attr_writer :redis, :context_saver, :fingerprinter

  def initialize(mutex: nil)
    # on cruby hash itself is threadsafe, but we need to prevent races
    @deprecations_mutex = mutex || Mutex.new
    @deprecations = {}
    @known_digests = Set.new
    @last_write_time = current_time
    @enabled = true

    load_default_config
  end

  def load_default_config
    @redis = defined?($redis) && $redis # rubocop:disable Style/GlobalVars
    @count = false
    @raise_on_deprecation = false
    @exclude_realms = []
    @ignore_message_regexp = nil
    @app_root = (defined?(Rails) && Rails.root.present? && Rails.root) || Dir.pwd
    # NB: in production with hugreds of workers may easily overload redis with writes, so more delay needed:
    @write_interval = 900 # 15.minutes
    @write_interval_jitter = 60
    @context_saver = nil
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

  def redis
    raise "DeprecationCollector#redis is not set" unless @redis

    @redis
  end

  def write_to_redis(force: false)
    return unless force || (@enabled && (current_time > @last_write_time + @write_interval))

    deprecations_to_flush = nil
    @deprecations_mutex.synchronize do
      deprecations_to_flush = @deprecations
      @deprecations = {}
      @last_write_time = current_time
      # checking in this section to prevent multiple parallel check requests
      return (@enabled = false) unless enabled_in_redis?
    end

    write_count_to_redis(deprecations_to_flush) if count?

    # make as few writes as possible, other workers may already have reported our warning
    fetch_known_digests
    deprecations_to_flush.reject! { |digest, _val| @known_digests.include?(digest) }
    return unless deprecations_to_flush.any?

    @known_digests.merge(deprecations_to_flush.keys)
    @redis.mapped_hmset("deprecations:data", deprecations_to_flush.transform_values(&:to_json))
  end

  # prevent fresh process from wiring frequent already known messages
  def fetch_known_digests
    @known_digests.merge(@redis.hkeys("deprecations:data"))
  end

  def flush_redis(enable: false)
    @redis.del("deprecations:data", "deprecations:counter", "deprecations:notes")
    @redis.del("deprecations:enabled") if enable
    @deprecations.clear
    @known_digests.clear
  end

  def enabled_in_redis?
    @redis.get("deprecations:enabled") != "false"
  end

  def enable
    @enabled = true
    @redis.set("deprecations:enabled", "true")
  end

  def disable
    @enabled = false
    @redis.set("deprecations:enabled", "false")
  end

  def dump
    read_each.to_a.to_json
  end

  def read_each
    return to_enum(:read_each) unless block_given?

    cursor = 0
    loop do
      cursor, data_pairs = @redis.hscan("deprecations:data", cursor)

      if data_pairs.any?
        data_pairs.zip(
          @redis.hmget("deprecations:counter", data_pairs.map(&:first)),
          @redis.hmget("deprecations:notes", data_pairs.map(&:first))
        ).each do |(digest, data), count, notes|
          yield decode_deprecation(digest, data, count, notes)
        end
      end
      break if cursor == "0"
    end
  end

  def read_one(digest)
    decode_deprecation(
      digest,
      *@redis.pipelined do |pipe|
        pipe.hget("deprecations:data", digest)
        pipe.hget("deprecations:counter", digest)
        pipe.hget("deprecations:notes", digest)
      end
    )
  end

  def delete_deprecations(remove_digests)
    return 0 unless remove_digests.any?

    @redis.pipelined do |pipe|
      pipe.hdel("deprecations:data", *remove_digests)
      pipe.hdel("deprecations:notes", *remove_digests)
      pipe.hdel("deprecations:counter", *remove_digests) if @count
    end.first
  end

  def cleanup
    cursor = 0
    removed = total = 0
    loop do
      cursor, data_pairs = @redis.hscan("deprecations:data", cursor) # NB: some pages may be empty
      total += data_pairs.size
      removed += delete_deprecations(
        data_pairs.to_h.select { |_digest, data| !block_given? || yield(JSON.parse(data, symbolize_names: true)) }.keys
      )
      break if cursor == "0"
    end
    "#{removed} removed, #{total - removed} left"
  end

  protected

  def unsent_deprecations
    @deprecations
  end

  def store_deprecation(deprecation, allow_context: true)
    return if deprecation.ignored?

    deprecation.context = context_saver.call if context_saver && allow_context
    deprecation.custom_fingerprint = fingerprinter.call(deprecation) if fingerprinter && allow_context

    fresh = !@deprecations.key?(deprecation.digest)
    @deprecations_mutex.synchronize do
      (@deprecations[deprecation.digest] ||= deprecation).touch
    end

    write_to_redis if current_time - @last_write_time > (@write_interval + rand(@write_interval_jitter))
    fresh
  end

  def log_deprecation_if_needed(deprecation, fresh)
    return unless print_to_stderr && !deprecation.ignored?
    return unless fresh || print_recurring

    msg = deprecation.message
    msg = "DEPRECATION: #{msg}" unless msg.start_with?("DEPRECAT")
    $stderr.puts(msg) # rubocop:disable Style/StderrPuts
  end

  def current_time
    return Time.zone.now if Time.respond_to?(:zone) && Time.zone

    Time.now
  end

  def decode_deprecation(digest, data, count, notes)
    return nil unless data

    data = JSON.parse(data, symbolize_names: true)
    unless data.is_a?(Hash)
      # this should not happen (this means broken Deprecation#to_json or some data curruption)
      return nil
    end

    data[:digest] = digest
    data[:notes] = JSON.parse(notes, symbolize_names: true) if notes
    data[:count] = count.to_i if count
    data
  end

  def write_count_to_redis(deprecations_to_flush)
    @redis.pipelined do |pipe|
      deprecations_to_flush.each_pair do |digest, deprecation|
        pipe.hincrby("deprecations:counter", digest, deprecation.occurences)
      end
    end
  end
end
