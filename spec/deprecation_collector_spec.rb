# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeprecationCollector do
  subject(:collector) { described_class.instance }

  let(:message) { "some message" }
  let(:backtrace) { caller_locations }
  let(:redis) { described_class.instance.storage.redis }

  before(:context) do
    $redis ||= Redis.new # rubocop:disable Style/GlobalVars
    described_class.instance_variable_set(:@instance, nil)
    described_class.instance_variable_set(:@installed, false)
    described_class.install do |instance|
      instance.redis = $redis # rubocop:disable Style/GlobalVars
      instance.app_revision = "somerevisionabc123"
      instance.app_root = File.expand_path("..", __dir__)
      instance.count = false
      instance.save_full_backtrace = true
    end
  end

  before do
    # если вдруг в тестах что-то насобиралось почему-то
    collector.write_to_redis(force: true) # сбрасываем кеш процесса
    # expect(collector.read_each.to_a).to eq([]) # - так можно посмотреть что там насобиралось
    collector.flush_redis(enable: true)
  end

  it "singleton creation when not installed yet" do
    described_class.instance_variable_set(:@instance, nil)
    expect(described_class.instance).to be_instance_of(described_class)
    described_class.instance_variable_set(:@instance, nil)
  end

  describe "collection" do
    it "writing and reading redis" do
      allow(redis).to receive(:hincrby).and_call_original

      expect { collector.collect(message, backtrace) }.to change(collector, :unsent_data?).from(false).to(true)
      2.times { collector.collect(message, backtrace) }
      expect(collector.read_each.to_a).to be_empty

      Timecop.travel(Time.now + 1200) do # 20.minutes.from_now
        # тут оно сбросит в редиску
        expect { collector.collect(message, backtrace) }.to change(collector, :unsent_data?).from(true).to(false)

        # а тут не должно
        expect do
          collector.collect("other message", backtrace)
        end.to change(collector, :unsent_data?).from(false).to(true)
      end

      if collector.count?
        expect(redis).to have_received(:hincrby).once
      else
        expect(redis).not_to have_received(:hincrby)
      end

      data = collector.read_each.to_a
      expect(data.size).to eq(1)
      item = data.first

      expect(item).to include(
        count: 4,
        message: message,
        app_traceline: %r{^spec/deprecation_collector_spec\.rb:\d+:in `block \(4 levels\) in <top \(required\)>'},
        gem_traceline:
          %r{^/gems/rspec-core-[0-9.]+/lib/rspec/core/memoized_helpers\.rb:\d+:in `block \(2 levels\) in let'},
        ruby_version: RUBY_VERSION
      )
      expect(item).to include(rails_version: Rails.version) if defined?(Rails)

      expect { collector.flush_redis }.to change { collector.read_each.to_a }.to([])
    end

    context "when disabled in redis just before write" do
      around do |ex|
        ex.run
      ensure
        collector.enable
      end

      it "disables self" do
        redis.set("deprecations:enabled", "false")
        Timecop.travel(Time.now + 1200) do # 20.minutes.from_now
          expect { collector.collect(message, backtrace) }.to change(collector, :enabled?).from(true).to(false)
        end
      end
    end

    describe "activesupport" do
      let(:deprecator) do
        if Rails.gem_version >= "7.1"
          ActiveSupport::Deprecation._instance
        else
          ActiveSupport::Deprecation
        end
      end
      let(:trigger_deprecation) do
        allow(described_class).to receive(:stock_activesupport_behavior).and_return(:raise)
        lambda do
          deprecator.warn("Test deprecation")
        rescue ActiveSupport::DeprecationException
          # when stock_activesupport_behavior is raise we are here
        end
      end

      before do
        skip "testing without ActiveSupport" unless defined? ActiveSupport
      end

      it "stock_activesupport_behavior is symbol" do
        expect(described_class.send(:stock_activesupport_behavior)).to be_a(Symbol)
      end

      it "from activesupport" do
        expect do
          # typically is set up in #install on app startup
          collector.context_saver { { some: "context" } }
        end.to change(collector, :context_saver)

        expect { trigger_deprecation[] }.to change(collector, :unsent_data?).from(false).to(true)

        collector.write_to_redis(force: true)
        item = collector.read_each.first
        expect(item).to include(
          message: include(
            "DEPRECATION WARNING: Test deprecation (called from block (5 levels) in <top (required)> at " \
            "spec/deprecation_collector_spec.rb:"
          ),
          realm: "rails"
        )
        expect(item[:gem_traceline]).to be_nil
        expect(collector.context_saver).to be_present
        expect(item[:context]).to eq({ some: "context" })
        expect(item).not_to have_key(:gem_traceline)
      end

      context "when rails 7.1 deprecator installed" do
        let(:deprecator) do
          ActiveSupport::Deprecation.new("0.0", "deprecation_collector").tap do |dep|
            Rails.application.deprecators[:deprecation_collector] = dep
          end
        end

        it "also collects" do
          skip unless Rails.gem_version >= "7.1"

          expect { trigger_deprecation[] }.to change(collector, :unsent_data?).from(false).to(true)

          collector.write_to_redis(force: true)
          item = collector.read_each.first
          expect(item).to include(
            message: include(
              "DEPRECATION WARNING: Test deprecation (called from block (6 levels) in <top (required)> at " \
              "spec/deprecation_collector_spec.rb:"
            ),
            realm: "rails"
          )
        end
      end

      context "when rails 7.1 deprecator NOT installed" do
        let(:deprecator) do
          ActiveSupport::Deprecation.new("0.0", "deprecation_collector")
        end

        it "also collects" do
          skip unless Rails.gem_version >= "7.1"
          expect { trigger_deprecation[] }.to change(collector, :unsent_data?).from(false).to(true)

          collector.write_to_redis(force: true)
          item = collector.read_each.first
          expect(item).to include(
            message: include(
              "DEPRECATION WARNING: Test deprecation (called from block (6 levels) in <top (required)> at " \
              "spec/deprecation_collector_spec.rb:"
            ),
            realm: "rails"
          )
        end
      end
    end

    describe "WarningCollector" do
      it "from ruby" do
        expect do
          Warning.warn "Test warning"
        rescue ActiveSupport::DeprecationException
          # тут не должно быть по идее, но вдруг решим кидать
        end.to change(collector, :unsent_data?).from(false).to(true)
        collector.write_to_redis(force: true)
        item = collector.read_each.first
        expect(item).to include(
          message: include("Test warning"),
          realm: "warning",
          app_traceline: %r{^spec/deprecation_collector_spec\.rb:\d+:in `block \(5 levels\) in <top \(required\)>'}
        )
        expect(item).not_to have_key(:gem_traceline)
      end

      it "joins multiline warnings" do
        expect do
          Warning.warn "foo.rb:3: warning: already initialized constant Foo"
          Warning.warn "foo.rb:1: warning: previous definition of Foo was here"
        end.to change { collector.send(:unsent_deprecations).size }.by(1)
      end

      it "does not join false-positive multiparts" do
        expect do
          Warning.warn "foo.rb:3: warning: already initialized constant Foo"
          Warning.warn "foo.rb:1: warning: another warning"
        end.to change { collector.send(:unsent_deprecations).size }.by(2)
      end
    end

    it "from kernel#warn" do
      expect do
        warn "Test warning"
      rescue ActiveSupport::DeprecationException
        # тут не должно быть, но на всякий случай
      end.to change(collector, :unsent_data?).from(false).to(true)
      collector.write_to_redis(force: true)
      item = collector.read_each.first
      expect(item).to include(
        message: include("Test warning"),
        realm: "kernel",
        app_traceline: %r{^spec/deprecation_collector_spec\.rb:\d+:in `block \(4 levels\) in <top \(required\)>'}
      )
      expect(item).not_to have_key(:gem_traceline)
    end

    it "is able to exclude realms" do
      collector.exclude_realms = [:kernel]
      expect do
        warn "Test kernel warning"
      end.not_to change(collector, :unsent_data?)
    ensure
      collector.exclude_realms.clear
    end

    it "is able to ignore by pattern" do
      collector.ignored_messages = ["ignored", /foo+/]
      expect do
        warn "ignored warning"
        warn "some fooooo"
      end.not_to change(collector, :unsent_data?)
      expect { warn "other warning" }.to change(collector, :unsent_data?)
    ensure
      collector.ignored_messages = nil
    end

    context "when context_saver has a deprecation inside" do
      let(:context_saver) do
        lambda do
          # no lambda in stacktrace, but the following call is, prevent deadloop
          raise "do not want loop here" if caller_locations.any? { |l| l.path == __FILE__ && l.lineno == __LINE__ + 1 } # rubocop:disable Layout/EmptyLineAfterGuardClause
          collector.collect("some deprecation in context_saver", caller_locations, :context_saver)
          { some: "context" }
        end
      end

      around do |example|
        prev_saver = collector.context_saver
        collector.context_saver = context_saver
        example.run
      ensure
        collector.context_saver = prev_saver
      end

      it "saves secondary deprecation without context" do
        expect do
          collector.collect("primary deprecation")
        end.to change { collector.send(:unsent_deprecations).size }.by(2)
      end
    end

    context "when fingerprinter set" do
      let(:fingerprinter) do
        double
      end

      around do |example|
        prev = collector.fingerprinter
        collector.fingerprinter = fingerprinter
        example.run
      ensure
        collector.fingerprinter = prev
      end

      it "can be set with block" do
        collector.fingerprinter do
          :foo
        end
        expect(collector.fingerprinter.call).to eq(:foo)
      end

      it "saves variants" do
        allow(fingerprinter).to receive(:call).with(an_instance_of(DeprecationCollector::Deprecation)).and_return(1, 2)
        expect do
          3.times { collector.collect("deprecation") }
        end.to change { collector.send(:unsent_deprecations).size }.by(2)
        expect(fingerprinter).to have_received(:call).exactly(3).times
      end
    end

    context "when deprecation_collector itself has a deprecation" do
      it "does not loop" do
        allow(collector).to receive(:log_deprecation_if_needed) { collector.collect("internal deprecation") } # rubocop:disable RSpec/SubjectStub
        expect do
          collector.collect("primary deprecation")
        end.to change { collector.send(:unsent_deprecations).size }.by(2)
      end
    end
  end

  describe "aggregation digest" do
    subject(:digest) { ->(*args) { described_class::Deprecation.new(*args).digest_base } }

    it "ignores quoted data in messages" do
      expect(
        digest['Overriding "Content-Type" header "multipart/form-data" with ' \
               '"multipart/form-data; boundary=----RubyFormBoundaryAfyRG13v44BT3gmJ"']
      ).to eq(digest['Overriding "" header "" with "lala"'])
    end

    it "ignores temporary views method names" do
      expect(digest[
        "Rails 6.1 will return Content-Type header without modification. " \
        "If you want just the MIME type, please use `#media_type` instead. " \
        "(called from _app_views_back_office_control_documents_utd_pdf_prawn__2671113783120882194_118963520 " \
        "at app/views/back_office/control/documents/utd.pdf.prawn:1)",
        "rails", [
          "app/views/some/view.pdf.prawn:170 block in _app_views_some_view_pdf_prawn__1733852578922288085_742240"
        ]]).to eq(
          digest[
            "Rails 6.1 will return Content-Type header without modification. " \
            "If you want just the MIME type, please use `#media_type` instead. " \
            "(called from _app_views_back_office_control_documents_utd_pdf_prawn__4007970162645015293_1241740 " \
            "at app/views/back_office/control/documents/utd.pdf.prawn:1)",
            "rails", [
              "app/views/some/view.pdf.prawn:170 block in _app_views_some_view_pdf_prawn__1234_5678"
            ]]
        )
    end

    it "ignores line numbers in pry" do
      expect(digest[
        "(pry):475: warning: already initialized constant Foo", "warning", ["(pry):475:in `<class:Bar>'"]
      ]).to eq(digest[
        "(pry):123: warning: already initialized constant Foo", "warning", ["(pry):123:in `<class:Bar>'"]
      ])
    end
  end

  context "when print_to_stderr enabled" do
    around do |example|
      old = collector.print_to_stderr
      collector.print_to_stderr = true
      example.run
    ensure
      collector.print_to_stderr = old
    end

    it "prints to stderr" do
      expect($stderr).to receive(:puts).with(/DEPRECATION: /)
      collector.collect("test stderr")
    end
  end

  context "when count is enabled" do
    around do |example|
      old = collector.count
      collector.count = true
      example.run
    ensure
      collector.count = old
    end

    it "flushes count to redis" do
      2.times do |count|
        expect do
          collector.collect("test")
          collector.write_to_redis(force: true)
        end.to change { redis.hgetall("deprecations:counter").values }.to([(count + 1).to_s])
      end
    end
  end

  it "#delete_deprecations" do
    expect(collector.storage).to receive(:delete).with("abc123")
    collector.delete_deprecations("abc123")
  end

  describe "#cleanup" do
    before do
      collector.collect(message, backtrace)
      collector.collect("other message", backtrace)
      collector.write_to_redis(force: true)
    end

    it "removes with filter" do
      expect do
        expect(collector.cleanup { |wrn| wrn[:message].include?(message) }).to eq "1 removed, 1 left"
      end.to change { collector.read_each.to_a.size }.from(2).to(1)

      expect(collector.cleanup { |wrn| wrn[:message].include?(message) }).to eq "0 removed, 1 left"
      expect(collector.cleanup { |wrn| wrn[:message].include?("other message") }).to eq "1 removed, 0 left"
    end

    it "requires a block" do
      expect { collector.cleanup }.to raise_error(ArgumentError)
    end
  end

  describe "#dump" do
    it "dumps" do
      expect(collector.dump).to eq("[]")
    end

    describe "import" do
      let(:dump_json) do
        [
          {
            digest: "lala",
            foo: "bar"
          }
        ].to_json
      end

      it "import" do
        expect { collector.import_dump(dump_json) }.to change { collector.read_each.to_a.size }.from(0).to(1)
        expect(collector.read_one("lala")).to eq({ digest: "lala", foo: "bar" })
      end
    end
  end

  it "enable/disable" do
    expect(collector.storage).to be_support_disabling
    expect { collector.disable }.to change(collector.storage, :enabled?).to(false)
    expect { collector.enable }.to change(collector, :enabled_in_redis?).to(true)
  end
end
