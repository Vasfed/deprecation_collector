# frozen_string_literal: true

require "spec_helper"
require "deprecation_collector/web"
require "rack/test"

RSpec.describe DeprecationCollector::Web do
  include Rack::Test::Methods

  let(:settings) { {} }
  let(:app) { described_class.new(**settings) }
  let(:collector) { DeprecationCollector.instance }

  describe "class method sugar" do
    let(:app) { described_class }

    it "behaves like rack app" do
      get "/"
      expect(last_response.status).to eq(200)
    end
  end

  describe "index" do
    let(:deprecations) do
      [
        {},
        { message: "trigger_rails_deprecation: lala", realm: "<escape>" },
        { message: "Using the last argument as keyword parameters is deprecated" }
      ]
    end

    before do
      allow(collector).to receive(:read_each).and_return(deprecations)
    end

    it "returns a 200 status code and text/html content type" do
      get "/"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to eq("text/html")
    end

    describe "filters" do
      it "filter" do
        get "/?realm=some&reject=rejectthis"
        expect(last_response.status).to eq(200)
      end
    end

    context "when DEPRECATION_COLLECTOR_RELOAD_WEB_TEMPLATES" do
      it "compiles" do
        require "temple/utils"
        allow(ENV).to receive(:[]).with("DEPRECATION_COLLECTOR_RELOAD_WEB_TEMPLATES").and_return("1")
        allow_any_instance_of(DeprecationCollector::Web::Router::ActionContext).to( # rubocop:disable RSpec/AnyInstance
          receive(:puts).with(a_string_matching(/Recompiling/))
        )
        expect(File).to receive(:write).twice
        get "/"
      end
    end

    context "when disabled" do
      it "shows enable" do
        allow(collector.storage).to receive(:support_disabling?).and_return(true)
        allow(collector.storage).to receive(:enabled?).and_return(false)
        get "/"
        expect(last_response.body).to include("/enable")
      end

      it "shows disable" do
        allow(collector.storage).to receive(:support_disabling?).and_return(true)
        allow(collector.storage).to receive(:enabled?).and_return(true)
        get "/"
        expect(last_response.body).to include("/disable")
        expect(last_response.body).not_to include("/enable")
      end
    end
  end

  describe "get by digest" do
    let(:digest) { "123abc" }
    let(:deprecation_content) do
      {
        digest: digest,
        message: "Test deprecation"
      }
    end

    it "renders" do
      expect(collector).to receive(:read_one).with(digest).and_return(deprecation_content)
      get "/#{digest}"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to eq("text/html")
      expect(last_response.body).to include("Test deprecation")
    end

    it "json" do
      expect(collector).to receive(:read_one).with(digest).and_return(deprecation_content)
      get "/#{digest}.json"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to eq("application/json")
    end

    it "404 for missing digest" do
      get "/missing"
      expect(last_response.status).to eq(404)
    end
  end

  it "404 for missing action" do
    post "/missing"
    expect(last_response.status).to eq(404)
  end

  describe "delete" do
    it "by digest" do
      delete "/somedigest"
      expect(last_response.status).to eq(302)
    end

    it "all" do
      delete "/all"
      expect(last_response.status).to eq(302)
    end
  end

  describe "enable/disable" do
    it "by digest" do
      post "/enable"
      expect(last_response.status).to eq(302)
    end

    it "all" do
      delete "/disable"
      expect(last_response.status).to eq(302)
    end
  end

  it "trigger" do
    expect(ActiveSupport::Deprecation).to receive(:warn).with(a_string_matching(/Test/)) if defined?(ActiveSupport)
    expect($stderr).to receive(:puts).with(a_string_matching(/Test/))
    post "/trigger"
    expect(last_response.status).to eq(302)
  end

  it "dump" do
    expect(collector).to receive(:dump).and_return("{}")
    get "/dump.json"
    expect(last_response.status).to eq(200)
    expect(last_response.headers["Content-Type"]).to eq("application/json")
    expect(last_response.body).to eq("{}")
  end

  describe "import" do
    let(:dump_content) { "{}" }
    let(:uploaded_file) do
      Rack::Test::UploadedFile.new(StringIO.new(dump_content), "application/json", original_filename: "1.json")
    end

    context "when not enabled" do
      it { expect(app.import_enabled).not_to be_truthy }

      it "does not show form" do
        get "/import"
        expect(last_response.status).to eq(403)
        expect(last_response.body).not_to include("<form")
      end

      it "does not accept file" do
        expect(collector).not_to receive(:import_dump)
        post "/import", file: uploaded_file
        expect(last_response.status).to eq(403)
      end
    end

    context "when enabled" do
      let(:settings) { { import_enabled: true } }

      it "shows form" do
        get "/import"
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to eq("text/html")
        expect(last_response.body).to include("<form")
      end

      it "accepts json" do
        expect(collector).to receive(:import_dump).with(dump_content)
        post "/import", file: uploaded_file
        expect(last_response.status).to eq(302)
      end

      it "requires file" do
        expect(collector).not_to receive(:import_dump)
        post "/import"
        expect(last_response.status).to eq(422)
      end
    end
  end
end
