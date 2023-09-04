# frozen_string_literal: true

require "spec_helper"
require "deprecation_collector/web"
require "rack/test"

RSpec.describe DeprecationCollector::Web do
  include Rack::Test::Methods

  def app
    described_class.new
  end

  it "returns a 200 status code and text/html content type" do
    get "/"
    expect(last_response.status).to eq(200)
    expect(last_response.headers["Content-Type"]).to eq("text/html")
  end
end
