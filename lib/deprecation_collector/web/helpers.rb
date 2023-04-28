# frozen_string_literal: true

class DeprecationCollector
  class Web
    module Helpers
      def collector_instance
        @collector_instance || DeprecationCollector.instance
      end

      def import_enabled?
        @web.import_enabled
      end

      def root_path
        # request.base_url ?
        "#{env["SCRIPT_NAME"]}/"
      end

      def current_path
        @current_path ||= request.path_info.gsub(/^\//, "")
      end

      def deprecations_path
        "#{root_path}"
      end

      def deprecation_path(id)
        "#{root_path}#{id}"
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
        -> { ActiveSupport::Deprecation.warn("Test deprecation") } []
      end

      def current_color_theme
        return 'dark' if params['dark']
        return 'light' if params['light']
        return 'dark' if request.get_header('HTTP_Sec_CH_Prefers_Color_Scheme').to_s.downcase.include?("dark")
        'auto'
      end

      def deprecation_tags(deprecation)
        {}.tap do |tags|
          tags[:kwargs] = 'bg-secondary' if deprecation[:message].include?("Using the last argument as keyword parameters is deprecated") ||
                                            deprecation[:message].include?("Passing the keyword argument as the last hash parameter is deprecated")

          tags[:test] = 'bg-success' if deprecation[:message].include?("trigger_kwargs_error_warning") ||
                                        deprecation[:message].include?("trigger_rails_deprecation")
            
          tags[deprecation[:realm]] = 'bg-secondary' if deprecation[:realm] && deprecation[:realm] != 'rails'

          deprecation.dig(:notes, :tags)&.each { |tag| tags[tag] = 'bg-secondary' }
        end
      end
    end
  end
end
