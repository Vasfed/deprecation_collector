# frozen_string_literal: true

require_relative "deprecation_collector/version"
require 'time'
require 'redis'

class DeprecationCollector
  @instance_mutex = Mutex.new
  @installed = false
  private_class_method :new

  def self.instance
    return @instance if defined?(@instance) && @instance

    @instance_mutex.synchronize do
      # переиспользовать мутекс не обязательно, но он используется ровно один раз
      @instance ||= new($redis, mutex: @instance_mutex)
    end
    @instance
  end

  def self.collect(message, backtrace, realm)
    instance.collect(message, backtrace, realm)
  end

  # inside dev env may be called multiple times
  def self.install
    instance # to make it created, configuration comes later

    @instance_mutex.synchronize do
      unless @installed
        at_exit { instance.write_to_redis(force: true) }
        @installed = true
      end

      yield instance if block_given?

      # TODO: a more polite hook
      ActiveSupport::Deprecation.behavior = lambda do |message, callstack, deprecation_horizon, gem_name|
        # not polite to turn off all other possible behaviors, but otherwise may get duplicate calls
        DeprecationCollector.collect(message, callstack, :rails)
        ActiveSupport::Deprecation::DEFAULT_BEHAVIORS[Rails.application&.config&.active_support&.deprecation || :log].call(
          message, callstack, deprecation_horizon, gem_name
        )
      end

      Kernel.class_eval do
        # module is included in others thus prepend does not work
        remove_method :warn
        class << self
          remove_method :warn
        end
        module_function(define_method(:warn) do |*messages, **kwargs|
          KernelWarningCollector.warn(*messages, backtrace: caller, **kwargs)
        end)
      end

      Warning.singleton_class.prepend(DeprecationCollector::WarningCollector)
      Warning[:deprecated] = true if Warning.respond_to?(:[]=) # turn on ruby 2.7 deprecations
    end

    @instance
  end

  module MultipartWarningJoiner
    module_function

    # Ruby sometimes has two warnings for one actual occurence
    # Example:
    # caller.rb:1: warning: Passing the keyword argument as the last hash parameter is deprecated
    # calleee.rb:1: warning: The called method `method_name' is defined here
    def two_part_warning?(str)
      # see ruby src - `rb_warn`, `rb_compile_warn`
      str.end_with?(
        "uses the deprecated method signature, which takes one parameter\n", # respond_to?
        # 2.7 kwargs:
        "maybe ** should be added to the call\n",
        "Passing the keyword argument as the last hash parameter is deprecated\n", # бывает и не двойной
        "Splitting the last argument into positional and keyword parameters is deprecated\n"
      ) ||
        str.include?("warning: already initialized constant") ||
        str.include?("warning: method redefined; discarding old")
    end

    def handle(new_str)
      old_str = Thread.current[:multipart_warning_str]
      Thread.current[:multipart_warning_str] = nil
      if old_str
        return yield(old_str + new_str) if new_str.include?('is defined here') || new_str.include?(' was here')
        yield(old_str)
      end

      if two_part_warning?(new_str)
        Thread.current[:multipart_warning_str] = new_str
        return
      end

      yield(new_str)
    end
  end

  # taps into ruby core Warning#warn
  module WarningCollector
    def warn(str)
      backtrace = caller
      MultipartWarningJoiner.handle(str) do |multi_str|
        DeprecationCollector.collect(multi_str, backtrace, :warning)
      end
    end
  end

  module KernelWarningCollector
    module_function

    def warn(*messages, backtrace: nil, **_kwargs)
      backtrace ||= caller
      str = messages.map(&:to_s).join("\n").strip
      DeprecationCollector.collect(str, backtrace, :kernel)
      # not passing to `super` - it will pass to Warning#warn, we do not want that
    end
  end

  class Deprecation
    attr_reader :message, :realm, :gem_traceline, :app_traceline, :occurences, :full_backtrace

    def initialize(message, realm = nil, backtrace = [], cleanup_prefixes = [])
      # backtrace is Thread::Backtrace::Location or array of strings for other realms
      @message = message.dup
      @realm = realm
      @occurences = 0
      @gem_traceline = backtrace.find { |line| !line.to_s.include?('kernel_warn') }&.to_s&.dup ||
                       backtrace.first.to_s.dup
      cleanup_prefixes.each do |path|
        @gem_traceline.delete_prefix!(path)
        @message.gsub!(path, '')
      end

      app_root = "#{DeprecationCollector.instance.app_root}/" # rubocop:disable Rails/FilePath
      @app_traceline = backtrace.find do |line|
        line = line.to_s
        (!line.start_with?('/') || line.start_with?(app_root)) && !line.include?('/gems/')
      end&.to_s&.dup&.delete_prefix(app_root)

      # rails views generated methods names are unique per-worker
      @gem_traceline&.gsub!(/_app_views_(\w+)__(\d+)_(\d+)/, "_app_views_\\1__")
      @app_traceline&.gsub!(/_app_views_(\w+)__(\d+)_(\d+)/, "_app_views_\\1__")

      # repl line numbers are not important, may be ignore all repl at all
      @app_traceline&.gsub!(/\A\((pry|irb)\):\d+/, '(\1)')
      @gem_traceline&.gsub!(/\A\((pry|irb)\):\d+/, '(\1)') # may contain app traceline, so filter too

      @full_backtrace = backtrace.map(&:to_s) if DeprecationCollector.instance.save_full_backtrace
    end

    def touch
      @occurences += 1
    end

    def ignored?
      false
    end

    def message_for_digest
      # some gems like rest-client put data in warnings, need to aggregate
      # + some bactrace per-worker unique method names may be there
      @message.gsub(/"(?:[^"\\]|\\.)*"/, '""').gsub(/__\d+_\d+/, '___').gsub(/\((pry|irb)\):\d+/, '(\1)')
    end

    def digest
      @digest ||= Digest::MD5.hexdigest(digest_base)
    end

    def digest_base
      "1:#{RUBY_VERSION}:#{Rails.version}:#{message_for_digest}:#{gem_traceline}:#{app_traceline}"
    end

    def as_json(_options = {})
      {
        message: message,
        realm: realm,
        app_traceline: app_traceline,
        gem_traceline: (gem_traceline != app_traceline && gem_traceline) || nil,
        full_backtrace: full_backtrace,
        ruby_version: RUBY_VERSION,
        rails_version: Rails.version,
        hostname: Socket.gethostname,
        revision: DeprecationCollector.instance.app_revision,
        count: @occurences, # output anyway for frequency estimation (during write_interval inside single process)
        digest_base: digest_base # for debug purposes
      }.compact
    end
  end

  attr_accessor :count, :raise_on_deprecation, :save_full_backtrace,
                :exclude_realms,
                :write_interval, :write_interval_jitter,
                :app_revision, :app_root

  def initialize(redis, mutex: nil)
    @redis = redis
    # on cruby hash itself is threadsafe, but we need to prevent races
    @deprecations_mutex = mutex || Mutex.new
    @deprecations = {}
    @known_digests = Set.new
    @last_write_time = current_time
    @enabled = true

    load_default_config
    fetch_known_digests # prevent fresh process from wiring frequent already known messages
  end

  def load_default_config
    @count = false
    @raise_on_deprecation = false
    @exclude_realms = []
    @ignore_message_regexp = nil
    @app_root = defined?(Rails) && Rails.root.present? && Rails.root || Dir.pwd
    # NB: in production with hugreds of workers may easily overload redis with writes, so more delay needed:
    @write_interval = 900 # 15.minutes
    @write_interval_jitter = 60
  end

  def ignored_messages=(val)
    @ignore_message_regexp = (val && Regexp.union(val)) || nil
  end

  def cleanup_prefixes
    @cleanup_prefixes ||= Gem.path + ["#{app_root}/"] # rubocop:disable Rails/FilePath
  end

  def collect(message, backtrace, realm = :unknown)
    return unless @enabled
    return if exclude_realms.include?(realm)
    return if @ignore_message_regexp&.match?(message)
    raise "Deprecation: #{message}" if @raise_on_deprecation

    deprecation = Deprecation.new(message, realm, backtrace, cleanup_prefixes)
    return if deprecation.ignored?

    @deprecations_mutex.synchronize do
      (@deprecations[deprecation.digest] ||= deprecation).touch
    end

    write_to_redis if current_time - @last_write_time > (@write_interval + rand(@write_interval_jitter))

    $stderr.puts(message) if defined?(Rails) && Rails.env.development? # rubocop:disable Style/StderrPuts
  end

  def unsent_data?
    @deprecations.any?
  end

  def count?
    @count
  end

  def fetch_known_digests
    @known_digests.merge(@redis.hkeys('deprecations:data'))
  end

  def write_to_redis(force: false)
    return unless @enabled || force

    deprecations_to_flush = nil
    @deprecations_mutex.synchronize do
      # check in this section to prevent multiple check requests
      unless enabled_in_redis?
        @enabled = false
        @deprecations = {}
        return
      end

      return unless force || current_time > @last_write_time + @write_interval

      deprecations_to_flush = @deprecations
      @deprecations = {}
      @last_write_time = current_time
    end

    # count is expensive in production env (but possible if needed) - a lot of redis writes
    if count?
      @redis.pipelined do
        deprecations_to_flush.each_pair do |digest, deprecation|
          @redis.hincrby("deprecations:counter", digest, deprecation.occurences)
        end
      end
    end

    # make as few writes as possible, other workers may already have reported our warning
    # TODO: at some point turn off writes?
    fetch_known_digests
    deprecations_to_flush.reject! { |digest, _val| @known_digests.include?(digest) }
    return unless deprecations_to_flush.any?

    @known_digests.merge(deprecations_to_flush.keys)
    @redis.mapped_hmset("deprecations:data", deprecations_to_flush.transform_values(&:to_json))
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
      @redis.hget("deprecations:data", digest),
      @redis.hget("deprecations:counter", digest),
      @redis.hget("deprecations:notes", digest)
    )
  end

  def delete_deprecations(remove_digests)
    @redis.pipelined do
      @redis.hdel("deprecations:data", *remove_digests)
      @redis.hdel("deprecations:notes", *remove_digests)
      @redis.hdel("deprecations:counter", *remove_digests) if @count
    end
  end

  def cleanup
    cursor = 0
    removed = 0
    total = 0
    loop do
      cursor, data_pairs = @redis.hscan("deprecations:data", cursor)

      if data_pairs.any?
        remove_digests = []
        total += data_pairs.size
        data_pairs.each do |(digest, data)|
          data = JSON.parse(data, symbolize_names: true)
          remove_digests << digest if !block_given? || yield(data)
        end

        if remove_digests.any?
          delete_deprecations(remove_digests)
          removed += remove_digests.size
        end
      end
      break if cursor == "0"
    end
    "#{removed} removed, #{total - removed} left"
  end

  private

  def current_time
    return Time.zone.now if Time.respond_to?(:zone) && Time.zone
    Time.now
  end

  def decode_deprecation(digest, data, count, notes)
    data = JSON.parse(data, symbolize_names: true)
    data[:digest] = digest
    data[:notes] = JSON.parse(notes, symbolize_names: true) if notes
    data[:count] = count.to_i if count
    data
  end
end
