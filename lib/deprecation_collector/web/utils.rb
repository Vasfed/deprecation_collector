
begin
  require 'cgi/escape'
rescue LoadError
end

module Temple
  # @api public
  module Utils
    extend self

    # Returns an escaped copy of `html`.
    # Strings which are declared as html_safe are not escaped.
    #
    # @param html [String] The string to escape
    # @return [String] The escaped string
    def escape_html_safe(html)
      s = html.to_s
      s.html_safe? || html.html_safe? ? s : escape_html(s)
    end

    if defined?(CGI.escapeHTML)
      # Returns an escaped copy of `html`.
      #
      # @param html [String] The string to escape
      # @return [String] The escaped string
      def escape_html(html)
        CGI.escapeHTML(html.to_s)
      end
    else
      # Used by escape_html
      # @api private
      ESCAPE_HTML = {
        '&'  => '&amp;',
        '"'  => '&quot;',
        '\'' => '&#39;',
        '<'  => '&lt;',
        '>'  => '&gt;'
      }.freeze

      ESCAPE_HTML_PATTERN = Regexp.union(*ESCAPE_HTML.keys)

      # Returns an escaped copy of `html`.
      #
      # @param html [String] The string to escape
      # @return [String] The escaped string
      def escape_html(html)
        html.to_s.gsub(ESCAPE_HTML_PATTERN, ESCAPE_HTML)
      end
    end
  end
end
