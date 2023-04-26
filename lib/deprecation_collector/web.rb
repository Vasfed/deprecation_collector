# frozen_string_literal: true

require "erb"
require "rack/content_length"
require "rack/builder"

require_relative 'web/application'

class DeprecationCollector
  class Web
    def self.call(env)
      @app ||= new
      @app.call(env)
    end

    def call(env)
      app.call(env)
    end

    def app
      @app ||= build
    end

    private
    def build
      ::Rack::Builder.new do
        # use Rack::Static etc goes here

        run Web::Application.new
      end
    end
  end
end
