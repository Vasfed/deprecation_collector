# frozen_string_literal: true

require "redis"

class DeprecationCollector
  module Storage
    # :nodoc:
    class Base
      # rubocop:disable Style/SingleLineMethods
      def initialize(**); end
      def support_disabling?; false; end
      def enabled?; true; end
      def enable; end
      def disable; end

      def unsent_deprecations; []; end
      def fetch_known_digests; end

      def delete(digests); end
      def clear(enable: false); end
      def flush(**); end

      def store(_deprecation); raise("Not implemented"); end
      # rubocop:enable Style/SingleLineMethods
    end

    # dummy strategy that outputs every deprecation into stderr
    class StdErr < Base
      def store(deprecation)
        DeprecationCollector.instance.send(:log_deprecation, deprecation)
      end
    end

    # storing in redis with deduplication by fingerprint
    class Redis < Base
      attr_accessor :write_interval, :write_interval_jitter, :redis, :count

      def initialize(redis: nil, mutex: nil, count: false, write_interval: 900, write_interval_jitter: 60,
                            key_prefix: nil)
        super
        @key_prefix = key_prefix || "deprecations"
        @redis = redis
        @last_write_time = current_time
        @count = count
        @write_interval = write_interval
        @write_interval_jitter = write_interval_jitter
        # on cruby hash itself is threadsafe, but we need to prevent races
        @deprecations_mutex = mutex || Mutex.new
        @deprecations = {}
        @known_digests = Set.new
      end

      def support_disabling?
        true
      end

      def unsent_deprecations
        @deprecations
      end

      def enabled?
        @redis.get(enabled_flag_key) != "false"
      end

      def enable
        @redis.set(enabled_flag_key, "true")
      end

      def disable
        @redis.set(enabled_flag_key, "false")
      end

      def delete(remove_digests)
        return 0 unless remove_digests.any?

        @redis.pipelined do |pipe|
          pipe.hdel(data_hash_key, *remove_digests)
          pipe.hdel(notes_hash_key, *remove_digests)
          pipe.hdel(counter_hash_key, *remove_digests) if @count
        end.first
      end

      def clear(enable: false)
        @redis.del(data_hash_key, counter_hash_key, notes_hash_key)
        @redis.del(enabled_flag_key) if enable
        @known_digests.clear
        @deprecations.clear
      end

      def fetch_known_digests
        # FIXME: use `.merge!`?
        @known_digests.merge(@redis.hkeys(data_hash_key))
      end

      def store(deprecation)
        fresh = !@deprecations.key?(deprecation.digest)
        @deprecations_mutex.synchronize do
          (@deprecations[deprecation.digest] ||= deprecation).touch
        end

        flush if current_time - @last_write_time > (@write_interval + rand(@write_interval_jitter))
        fresh
      end

      def flush(force: false)
        return unless force || (current_time > @last_write_time + @write_interval)

        deprecations_to_flush = nil
        @deprecations_mutex.synchronize do
          deprecations_to_flush = @deprecations
          @deprecations = {}
          @last_write_time = current_time
          # checking in this section to prevent multiple parallel check requests
          return DeprecationCollector.instance.instance_variable_set(:@enabled, false) unless enabled?
        end

        write_count_to_redis(deprecations_to_flush) if @count

        # make as few writes as possible, other workers may already have reported our warning
        fetch_known_digests
        deprecations_to_flush.reject! { |digest, _val| @known_digests.include?(digest) }
        return unless deprecations_to_flush.any?

        @known_digests.merge(deprecations_to_flush.keys)
        @redis.mapped_hmset(data_hash_key, deprecations_to_flush.transform_values(&:to_json))
      end

      def read_each
        cursor = 0
        loop do
          cursor, data_pairs = @redis.hscan(data_hash_key, cursor)

          if data_pairs.any?
            data_pairs.zip(
              @redis.hmget(counter_hash_key, data_pairs.map(&:first)),
              @redis.hmget(notes_hash_key, data_pairs.map(&:first))
            ).each do |(digest, data), count, notes|
              yield(digest, data, count, notes)
            end
          end
          break if cursor == "0"
        end
      end

      def read_one(digest)
        [
          digest,
          *@redis.pipelined do |pipe|
            pipe.hget(data_hash_key, digest)
            pipe.hget(counter_hash_key, digest)
            pipe.hget(notes_hash_key, digest)
          end
        ]
      end

      def import(dump_hash)
        @redis.mapped_hmset(data_hash_key, dump_hash.transform_values(&:to_json))
      end

      def cleanup(&_block)
        cursor = 0
        removed = total = 0
        loop do
          cursor, data_pairs = @redis.hscan(data_hash_key, cursor) # NB: some pages may be empty
          total += data_pairs.size
          removed += delete(
            data_pairs.to_h.select { |_digest, data| yield(JSON.parse(data, symbolize_names: true)) }.keys
          )
          break if cursor == "0"
        end
        "#{removed} removed, #{total - removed} left"
      end

      def key_prefix=(val)
        @enabled_flag_key = @data_hash_key = @counter_hash_key = @notes_hash_key = nil
        @key_prefix = val
      end

      protected

      def enabled_flag_key
        @enabled_flag_key ||= "#{@key_prefix}:enabled" # usually deprecations:enabled
      end

      def data_hash_key
        @data_hash_key ||= "#{@key_prefix}:data" # usually deprecations:data
      end

      def counter_hash_key
        @counter_hash_key ||= "#{@key_prefix}:counter" # usually deprecations:counter
      end

      def notes_hash_key
        @notes_hash_key ||= "#{@key_prefix}:notes" # usually deprecations:notes
      end

      def current_time
        return Time.zone.now if Time.respond_to?(:zone) && Time.zone

        Time.now
      end

      def write_count_to_redis(deprecations_to_flush)
        @redis.pipelined do |pipe|
          deprecations_to_flush.each_pair do |digest, deprecation|
            pipe.hincrby(counter_hash_key, digest, deprecation.occurences)
          end
        end
      end
    end
  end
end
