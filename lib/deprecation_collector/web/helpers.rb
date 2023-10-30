# frozen_string_literal: true

class DeprecationCollector
  class Web
    # :nodoc:
    module Helpers
      def collector_instance
        @collector_instance || DeprecationCollector.instance
      end

      def import_enabled?
        @web.import_enabled
      end

      def root_path
        # request.base_url ?
        "#{env['SCRIPT_NAME']}/"
      end

      def current_path
        @current_path ||= request.path_info.gsub(%r{^/}, "")
      end

      def deprecations_path
        root_path # /
      end

      def deprecation_path(id, format: nil)
        ["#{root_path}#{id}", format].compact.join(".")
      end

      def enable_deprecations_path
        "#{root_path}enable"
      end

      def disable_deprecations_path
        "#{root_path}disable"
      end

      def dump_deprecations_path
        "#{root_path}dump.json"
      end

      def import_deprecations_path
        "#{root_path}import"
      end

      def trigger_kwargs_error_warning(foo: nil); end

      def trigger_rails_deprecation
        return unless defined?(ActiveSupport::Deprecation)

        deprecator = ActiveSupport::Deprecation
        deprecator = ActiveSupport::Deprecation.new("0.0", "deprecation_collector") if Rails.gem_version >= Gem::Version.new("7.1")

        -> { deprecator.warn("Test deprecation") } []
      end

      def current_color_theme
        return "dark" if params["dark"]
        return "light" if params["light"]
        return "dark" if request.get_header("HTTP_Sec_CH_Prefers_Color_Scheme").to_s.downcase.include?("dark")

        "auto"
      end

      def detect_tag(deprecation)
        msg = deprecation[:message].to_s
        return :kwargs if msg.include?("Using the last argument as keyword parameters is deprecated") ||
                          msg.include?("Passing the keyword argument as the last hash parameter is deprecated")

        nil
      end

      def test_deprecation?(deprecation)
        %w[trigger_kwargs_error_warning trigger_rails_deprecation].any? do |method|
          deprecation[:message].to_s.include?(method)
        end
      end

      def deprecation_tags(deprecation)
        tags = Set.new
        if (detected_tag = detect_tag(deprecation))
          tags << detected_tag
        end
        tags << :test if test_deprecation?(deprecation)
        tags << deprecation[:realm] if deprecation[:realm] && deprecation[:realm] != "rails"
        tags.merge(deprecation.dig(:notes, :tags) || [])

        tags.map do |tag|
          if tag == :test
            [tag, "bg-success"]
          else
            [tag, "bg-secondary"]
          end
        end.to_h
      end
    end
  end
end
