# frozen_string_literal: true

class DeprecationCollector
  class Web
    module Router
      HTTP_METHODS = %w[GET HEAD POST PUT PATCH DELETE].freeze
      HTTP_METHODS.each do |http_method|
        const_set http_method, http_method
        class_eval <<~RUBY, __FILE__, __LINE__+1
          def #{http_method.downcase}(path, &block)
            route(#{http_method}, path, &block)
          end
        RUBY
      end

      def root(&block)
        route(GET, '/', &block)
      end

      def route(method, path, &block)
        ((@routes ||= {})[method] ||= []) << Route.new(method, path, block)
      end

      def helpers(mod = nil, &block)
        return ActionContext.class_eval(&block) if block
        ActionContext.send(:include, mod)
      end


      ROUTE_PARAMS = "rack.route_params"
      PATH_INFO = "PATH_INFO"

      def match(env)
        request = ::Rack::Request.new(env)
        request_method = request.request_method
        request_method = request.params["_method"] if request.params["_method"]

        path_info = ::Rack::Utils.unescape env[PATH_INFO]
        path_info = "/" if path_info == "" # some buggy servers may pass empty root path

        @routes[request_method.upcase]&.find do |route|
          params = route.match(request_method, path_info)
          next unless params
          env[ROUTE_PARAMS] = params
          break ActionContext.new(request, &route.block)
        end
      end

      def call(env)
        action = match(env)
        unless action
          return [
            404,
            {"content-type" => "text/plain", "x-cascade" => "pass"},
            ["Not Found #{env["REQUEST_METHOD"].inspect} #{env[PATH_INFO].inspect}"]
          ]
        end

        resp = catch(:halt) do
          action.call(env)
        ensure
        end

        return resp if resp.is_a?(Array) # raw rack responses (redirects etc.)

        # rendered content goes here
        headers = {
          "content-type" => "text/html",
          "cache-control" => "private, no-store",
          # TODO:
          # "content-language" => action.locale,
          # "content-security-policy" => CSP_HEADER
        }
        # we'll let Rack calculate Content-Length for us.
        [200, headers, [resp]]
      end

      class Route
        attr_accessor :request_method, :pattern, :block

        NAMED_SEGMENTS_PATTERN = /\/([^\/]*):([^.:$\/]+)/

        def initialize(request_method, pattern, block)
          @request_method = request_method
          @pattern = pattern
          @block = block
        end

        def matcher
          @matcher ||= compile_matcher
        end

        def compile_matcher
          return pattern unless pattern.match?(NAMED_SEGMENTS_PATTERN)
          regex_pattern = pattern.gsub(NAMED_SEGMENTS_PATTERN, '/\1(?<\2>[^$/]+)') # /some/:id => /some/(?<id>[^$/]+)

          Regexp.new("\\A#{regex_pattern}\\Z")
        end

        def match(request_method, path)
          case matcher
          when String
            {} if path == matcher
          else
            path_match = path.match(matcher)
            path_match&.named_captures&.transform_keys(&:to_sym)
          end
        end
      end

      class ActionContext
        attr_accessor :request

        def initialize(request, &block)
          @request = request
          @block = block
        end

        def call(env)
          instance_exec(&@block)
        end

        def env
          request.env
        end

        def route_params
          env[Router::ROUTE_PARAMS]
        end

        def params
          @params ||= Hash.new { |hash, key| hash[key.to_s] if Symbol === key }
                        .merge!(request.params)
                        .merge!(route_params.transform_keys(&:to_s))
        end

        def halt(res)
          throw :halt, [res, {"content-type" => "text/plain"}, [res.to_s]]
        end

        def redirect_to(location)
          throw :halt, [302, {"location" => "#{request.base_url}#{location}"}, []]
        end

        def render(plain: nil, html: nil, json: nil, erb: nil, slim: nil, status: 200, locals: nil, layout: 'layout.html.slim')
          raise ArgumentError, "provide exactly one render format" unless [plain, html, json, erb, slim].compact.size == 1

          return [status, {"content-type" => "application/json"}, [JSON.generate(json)]] if json
          return [status, {"content-type" => "text/plain"}, [plain.to_s]] if plain

          _define_locals(locals) if locals
          template = "#{erb}.erb" if erb
          template = "#{slim}.slim" if slim
          html = render_template(template) if template
          html = render_template(layout) { html } if layout

          color_scheme_headers = {
            'Accept-CH' => 'Sec-CH-Prefers-Color-Scheme',
            'Vary' => 'Sec-CH-Prefers-Color-Scheme',
            'Critical-CH' => 'Sec-CH-Prefers-Color-Scheme'
          }

          return [status, {"content-type" => "text/html"}.merge(color_scheme_headers), [html.to_s]] if html
        end

        VIEW_PATH = "#{__dir__}/views"

        def render_template(template, &block)
          original_template_name = File.join(VIEW_PATH, template.to_s)
          template = template.gsub(/\.slim\z/, '.template.rb')
          template_method_name = "_template_#{template.gsub(/[^\w]/, '_')}"
          template_filename = File.join(VIEW_PATH, template.to_s)

          if ENV['DEPRECATION_COLLECTOR_RELOAD_WEB_TEMPLATES']
            require 'slim'
            puts "Recompiling #{original_template_name}"
            ActionContext.class_eval { undef_method(template_method_name) } if respond_to?(template_method_name)
            if original_template_name.end_with?('.slim')
              File.write(template_filename, Slim::Template.new(original_template_name).precompiled_template)
            end
          end

          unless respond_to?(template_method_name)
            src = File.read(template_filename)
            src = ERB.new(src).src if template_filename.end_with?('.erb')
            ActionContext.class_eval <<-RUBY, template_filename.gsub(/\.template\.rb\z/, '.slim'), 1
              def #{template_method_name}; #{src}
              end
            RUBY
          end

          send(template_method_name, &block)
        end

        private
        def _define_locals(locals)
          locals&.each { |k, v| define_singleton_method(k) { v } unless singleton_methods.include?(k) }
        end
      end
    end
  end
end
