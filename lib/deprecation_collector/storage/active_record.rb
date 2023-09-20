# frozen_string_literal: true

class DeprecationCollector
  module Storage
    # NB: this will not work in tests because of transactions, and may be affected by transactions of the app
    # TODO: use separate db connection to mitigate this
    class ActiveRecord < DeprecationCollector::Storage::Base
      def initialize(model: nil, mutex: nil, count: false, write_interval: 900, write_interval_jitter: 60,
                     key_prefix: nil)
        super
        raise "key prefix not supported in AR" if key_prefix && key_prefix != "deprecations"

        self.model = model if model
        @last_write_time = current_time
        @count = count
        @write_interval = write_interval
        @write_interval_jitter = write_interval_jitter
        # on cruby hash itself is threadsafe, but we need to prevent races
        @deprecations_mutex = mutex || Mutex.new
        @deprecations = {}
        @known_digests = Set.new
      end

      def model=(model)
        expected_class_methods = %i[column_names where pluck delete_all upsert_all find_in_batches find_by]
        unless expected_class_methods.all? { |method_name| model.respond_to?(method_name) }
          raise ArgumentError, "model expected to be a AR-like class responding to #{expected_class_methods.join(', ')}"
        end
        expected_fields = %w[digest data notes created_at updated_at]
        unless expected_fields.all? { |column_name| model.column_names.include?(column_name) }
          raise ArgumentError, "model expected to be a AR-like class with fields #{expected_fields.join(', ')}"
        end

        @model = model
      end

      def model
        @model ||= ::Deprecation
      end

      attr_writer :key_prefix

      def unsent_deprecations
        @deprecations
      end

      def delete(remove_digests)
        model.where(digest: remove_digests).delete_all
      end

      def clear(enable: false) # rubocop:disable Lint/UnusedMethodArgument
        model.delete_all
        @known_digests.clear
        @deprecations.clear
      end

      def fetch_known_digests
        @known_digests.merge(model.pluck(:digest))
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

        # write_count_to_redis(deprecations_to_flush) if @count

        # make as few writes as possible, other workers may already have reported our warning
        fetch_known_digests
        deprecations_to_flush.reject! { |digest, _val| @known_digests.include?(digest) }
        return unless deprecations_to_flush.any?

        @known_digests.merge(deprecations_to_flush.keys)

        model.upsert_all(
          deprecations_to_flush.map do |key, deprecation|
            {
              digest: key, data: deprecation.as_json,
              created_at: timestamp_to_time(deprecation.first_timestamp),
              updated_at: timestamp_to_time(deprecation.first_timestamp)
            }
          end,
          unique_by: :digest # , update_only: %i[data updated_at] # rails 7
        )
      end

      def read_each
        model.find_in_batches do |batch| # this is find_each, but do not require it to be implemented
          batch.each do |record|
            yield(record.digest, record.data.to_json, record.data&.dig("count"), record.notes)
          end
        end
      end

      def read_one(digest)
        return [nil]*4 unless (record = model.find_by(digest: digest))

        [record.digest, record.data.to_json, record.data&.dig("count"), record.notes]
      end

      def import(dump_hash)
        attrs = dump_hash.map do |key, deprecation|
          time = (deprecation["first_timestamp"] || deprecation[:first_timestamp])&.then { |tme| timestamp_to_time(tme) } ||
                 current_time
          { digest: key, data: deprecation, created_at: time, updated_at: time }
        end
        model.upsert_all(attrs, unique_by: :digest) # , update_only: %i[data updated_at])
      end

      def cleanup(&_block)
        removed = total = 0

        model.find_in_batches do |batch|
          total += batch.size
          removed += delete(
            batch.select { |record| yield(record.data.deep_symbolize_keys) }.map(&:digest)
          )
        end
        "#{removed} removed, #{total - removed} left"
      end

      protected

      def current_time
        return Time.zone.now if Time.respond_to?(:zone) && Time.zone

        Time.now
      end

      def timestamp_to_time(timestamp)
        return Time.zone.at(timestamp) if Time.respond_to?(:zone) && Time.zone

        Time.at(timestamp)
      end
    end
  end
end
