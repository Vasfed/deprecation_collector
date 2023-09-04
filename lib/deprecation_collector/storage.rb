# frozen_string_literal: true

require "redis"

class DeprecationCollector
  module Storage
    # :nodoc:
    class Base
      # rubocop:disable Style/SingleLineMethods
      def enabled?; true; end
      def enable; end
      def disable; end

      def unsent_deprecations; []; end
      def fetch_known_digests; end

      def delete(digests); end
      def clear(enable: false); end

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

      def initialize(redis, mutex: nil, count: false, write_interval: 900, write_interval_jitter: 60)
        super()
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

      def unsent_deprecations
        @deprecations
      end

      def enabled?
        @redis.get("deprecations:enabled") != "false"
      end

      def enable
        @redis.set("deprecations:enabled", "true")
      end

      def disable
        @redis.set("deprecations:enabled", "false")
      end

      def delete(remove_digests)
        return 0 unless remove_digests.any?

        @redis.pipelined do |pipe|
          pipe.hdel("deprecations:data", *remove_digests)
          pipe.hdel("deprecations:notes", *remove_digests)
          pipe.hdel("deprecations:counter", *remove_digests) if @count
        end.first
      end

      def clear(enable: false)
        @redis.del("deprecations:data", "deprecations:counter", "deprecations:notes")
        @redis.del("deprecations:enabled") if enable
        @known_digests.clear
        @deprecations.clear
      end

      def fetch_known_digests
        # FIXME: use `.merge!`?
        @known_digests.merge(@redis.hkeys("deprecations:data"))
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
        @redis.mapped_hmset("deprecations:data", deprecations_to_flush.transform_values(&:to_json))
      end

      def read_each
        cursor = 0
        loop do
          cursor, data_pairs = @redis.hscan("deprecations:data", cursor)

          if data_pairs.any?
            data_pairs.zip(
              @redis.hmget("deprecations:counter", data_pairs.map(&:first)),
              @redis.hmget("deprecations:notes", data_pairs.map(&:first))
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
            pipe.hget("deprecations:data", digest)
            pipe.hget("deprecations:counter", digest)
            pipe.hget("deprecations:notes", digest)
          end
        ]
      end

      def import(dump_hash)
        @redis.mapped_hmset("deprecations:data", dump_hash.transform_values(&:to_json))
      end

      def cleanup(&_block)
        cursor = 0
        removed = total = 0
        loop do
          cursor, data_pairs = @redis.hscan("deprecations:data", cursor) # NB: some pages may be empty
          total += data_pairs.size
          removed += delete(
            data_pairs.to_h.select { |_digest, data| yield(JSON.parse(data, symbolize_names: true)) }.keys
          )
          break if cursor == "0"
        end
        "#{removed} removed, #{total - removed} left"
      end

      protected

      def current_time
        return Time.zone.now if Time.respond_to?(:zone) && Time.zone

        Time.now
      end

      def write_count_to_redis(deprecations_to_flush)
        @redis.pipelined do |pipe|
          deprecations_to_flush.each_pair do |digest, deprecation|
            pipe.hincrby("deprecations:counter", digest, deprecation.occurences)
          end
        end
      end
    end
  end
end
