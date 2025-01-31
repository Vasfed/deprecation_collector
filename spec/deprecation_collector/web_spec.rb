# frozen_string_literal: true

require "spec_helper"
require "deprecation_collector/web"
require "rack/test"

RSpec.describe DeprecationCollector::Web do
  include Rack::Test::Methods

  let(:settings) { {} }
  let(:app) { described_class.new(**settings) }
  let(:collector) { DeprecationCollector.instance }
  let(:fat_deprecation) do
    {
      message: "Fat deprecation with all fields\nAnd\nMultiple\nlines",
      app_traceline: "app/some/file.rb:123 in 'foo'",
      gem_traceline: "/gems/foo-1.2.3/lib/some/file.rb:123 in 'bar'",
      notes: { comment: 'comment' },
      context: { action: 'foo#bar', params: { controller: 'foo', action: 'bar', id: 123 } },
      digest: '123abc',
      revision: 'gitrevision',
      hostname: 'localhost',
      first_timestamp: Time.now.to_i,
      count: 123,
      realm: 'realm',
      ruby_version: '3.4.1',
      rails_version: '8.0.1',
      full_backtrace: [
        'foo.rb:1',
        'foo.rb:2',
      ]
    }
  end

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
        {
          message: "Using the last argument as keyword parameters is deprecated",
          context: { params: { controller: 'deprecated_in_params', action: 'bar' } },
        },
        fat_deprecation
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

    describe "no items but import" do
      let(:settings) { { import_enabled: true } }
      let(:deprecations) { [] }

      it "returns a 200 status code and text/html content type" do
        get "/"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('no deprecations')
        expect(last_response.body).to include('import')
      end
    end

    describe "filters" do
      it "filter" do
        get "/?realm=some&reject=rejectthis"
        expect(last_response.status).to eq(200)
      end

      it 'empty filter' do
        get "/?realm=&reject="
        expect(last_response.status).to eq(200)        
      end
    end

    context "when DEPRECATION_COLLECTOR_RELOAD_WEB_TEMPLATES" do
      it "compiles" do
        require "temple/utils"

        allow_any_instance_of(DeprecationCollector::Web::Router::ActionContext).to(
          receive(:_recompile_enabled?).and_return(true)
        )
        allow_any_instance_of(DeprecationCollector::Web::Router::ActionContext).to( # rubocop:disable RSpec/AnyInstance
          receive(:puts).with(a_string_matching(/Recompiling/))
        )
        expect(File).to receive(:write).twice
        get "/"
      end
    end

    context "when disabled" do
      it "shows enable" do
        allow(collector.storage).to receive_messages(support_disabling?: true, enabled?: false)
        get "/"
        expect(last_response.body).to include("/enable")
      end

      it "shows disable" do
        allow(collector.storage).to receive_messages(support_disabling?: true, enabled?: true)
        get "/"
        expect(last_response.body).to include("/disable")
        expect(last_response.body).not_to include("/enable")
      end
    end
  end

  describe "get by digest (aka show)" do
    let(:digest) { "123abc" }
    let(:deprecation_content) do
      fat_deprecation.merge(
        digest: digest,
        message: "Test deprecation"
      )
    end

    context "when slim deprecation" do
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
    if defined?(ActiveSupport)
      if Rails.gem_version >= Gem::Version.new("7.1")
        expect_any_instance_of(ActiveSupport::Deprecation).to receive(:warn).with(a_string_matching(/Test/))
      else
        expect(ActiveSupport::Deprecation).to receive(:warn).with(a_string_matching(/Test/))
      end
    end
    if RUBY_VERSION.start_with?("2.7")
      expect_any_instance_of(DeprecationCollector::Web::Router::ActionContext).to receive(:trigger_kwargs_error_warning)
    end
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
