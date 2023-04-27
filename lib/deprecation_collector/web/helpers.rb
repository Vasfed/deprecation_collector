# frozen_string_literal: true

class DeprecationCollector
  class Web
    module Helpers
      def collector_instance
        @collector_instance || DeprecationCollector.instance
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
    end
  end
end
