# frozen_string_literal: true

require_relative 'router'
require_relative 'helpers'
require 'pp'

class DeprecationCollector
  class Web
    class Application
      extend Web::Router
      helpers Helpers

      def initialize
        unless defined?(Temple::Utils) || ENV['DEPRECATION_COLLECTOR_RELOAD_WEB_TEMPLATES']
          # used for escaping in compiled slim templates
          require_relative 'utils'
        end
      end

      def call(env)
        self.class.call(env)
      end

      root do # index
        @deprecations = collector_instance.read_each.to_a.compact
        @deprecations = @deprecations.sort_by { |dep| dep[:message] } unless params[:sort] == '0'

        if params[:reject]
          @deprecations = @deprecations.reject { |dep| dep[:message].match?(Regexp.union(Array(params[:reject]))) }
        end

        if params[:realm]
          @deprecations = @deprecations.select { |dep| dep[:realm].match?(Regexp.union(Array(params[:realm]))) }
        end

        render slim: "index.html"
      end

      get '/dump.json' do
        render json: collector_instance.read_each.to_a
      end

      get '/:id' do # show
        @deprecation = collector_instance.read_one(params[:id])
        render slim: "show.html"
      end

      delete '/all' do
        collector_instance.flush_redis
        redirect_to deprecations_path
      end

      post '/enable' do
        collector_instance.enable
        redirect_to deprecations_path
      end

      delete '/disable' do
        collector_instance.disable
        redirect_to deprecations_path
      end

      # NB: order for wildcards is important
      delete '/:id' do # destroy
        collector_instance.delete_deprecations([params[:id]])
        redirect_to deprecations_path
      end

      post '/trigger' do # trigger
        trigger_kwargs_error_warning({ foo: nil }) if RUBY_VERSION.start_with?('2.7')
        trigger_rails_deprecation
        collector_instance.collect(
          "TestFoo#assign_attributes called (test attr_spy) trigger_rails_deprecation", caller_locations, :attr_spy
        )
        collector_instance.write_to_redis(force: true)
        redirect_to deprecations_path
      end
    end
  end
end
