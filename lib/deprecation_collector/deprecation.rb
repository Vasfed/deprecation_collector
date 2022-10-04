# frozen_string_literal: true

class DeprecationCollector
  # :nodoc:
  class Deprecation
    attr_reader :message, :realm, :gem_traceline, :app_traceline, :occurences, :first_timestamp, :full_backtrace
    attr_accessor :context

    CLEANUP_REGEXES = {
      # rails views generated methods names are unique per-worker
      /_app_views_(\w+)__(\d+)_(\d+)/ => "_app_views_\\1__",

      # repl line numbers are not important, may be ignore all repl at all
      /\A\((pry|irb)\):\d+/ => '(\1)'
    }.freeze

    def initialize(message, realm = nil, backtrace = [], cleanup_prefixes = [])
      # backtrace is Thread::Backtrace::Location or array of strings for other realms
      @message = message.dup
      @realm = realm
      @occurences = 0
      @gem_traceline = find_gem_traceline(backtrace)
      @app_traceline = find_app_traceline(backtrace)
      @first_timestamp = Time.now.to_i

      cleanup_prefixes.each do |path|
        @gem_traceline.delete_prefix!(path)
        @message.gsub!(path, "")
      end

      CLEANUP_REGEXES.each_pair do |regex, replace|
        @gem_traceline&.gsub!(regex, replace)
        @app_traceline&.gsub!(regex, replace)
      end

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
      @message.gsub(/"(?:[^"\\]|\\.)*"/, '""').gsub(/__\d+_\d+/, "___").gsub(/\((pry|irb)\):\d+/, '(\1)')
    end

    def digest
      @digest ||= Digest::MD5.hexdigest(digest_base)
    end

    def digest_base
      "1:#{RUBY_VERSION}:#{defined?(Rails) && Rails.version}:#{message_for_digest}:#{gem_traceline}:#{app_traceline}"
    end

    def as_json(_options = {})
      {
        message: message,
        realm: realm,
        app_traceline: app_traceline,
        gem_traceline: (gem_traceline != app_traceline && gem_traceline) || nil,
        full_backtrace: full_backtrace,
        ruby_version: RUBY_VERSION,
        rails_version: (defined?(Rails) && Rails.version),
        hostname: Socket.gethostname,
        revision: DeprecationCollector.instance.app_revision,
        count: @occurences, # output anyway for frequency estimation (during write_interval inside single process)
        first_timestamp: first_timestamp, # this may not be accurate, a worker with later timestamp may dump earlier
        digest_base: digest_base, # for debug purposes
        context: context
      }.compact
    end

    protected

    def find_app_traceline(backtrace)
      app_root = DeprecationCollector.instance.app_root_prefix
      backtrace.find do |line|
        line = line.to_s
        (!line.start_with?("/") || line.start_with?(app_root)) && !line.include?("/gems/")
      end&.to_s&.dup&.delete_prefix(app_root)
    end

    def find_gem_traceline(backtrace)
      backtrace.find { |line| !line.to_s.include?("kernel_warn") }&.to_s&.dup || backtrace.first.to_s.dup
    end
  end
end
