# frozen_string_literal: true

require "erb"
require "rack/content_length"
require "rack/builder"

require_relative "web/application"

class DeprecationCollector
  # rack app with a html interface to deprecation collector with a persistent storage like redis
  class Web
    attr_accessor :import_enabled

    def initialize(import_enabled: nil)
      @import_enabled = import_enabled
    end

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
      web = self
      ::Rack::Builder.new do
        # use Rack::Static etc goes here

        run Web::Application.new(web)
      end
    end
  end
end
