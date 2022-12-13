# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeprecationCollector do
  subject(:collector) { described_class.instance }

  let(:message) { "some message" }
  let(:backtrace) { caller_locations }
  let(:redis) { described_class.instance.redis }

  before(:all) do
    DeprecationCollector.install do |instance|
      instance.redis = Redis.new
      instance.app_revision = "somerevisionabc123"
      instance.app_root = File.expand_path("..", __dir__)
      instance.count = false
      instance.save_full_backtrace = true
      instance.context_saver do
        { some: "context" }
      end
    end
  end

  before do
    # если вдруг в тестах что-то насобиралось почему-то
    collector.write_to_redis(force: true) # сбрасываем кеш процесса
    # expect(collector.read_each.to_a).to eq([]) # - так можно посмотреть что там насобиралось
    collector.flush_redis(enable: true)
  end

  describe "collection" do
    it "writing and reading redis" do
      allow(redis).to receive(:hincrby).and_call_original

      expect { collector.collect(message, backtrace) }.to change(collector, :unsent_data?).from(false).to(true)
      2.times { collector.collect(message, backtrace) }
      expect(collector.read_each.to_a).to be_empty

      Timecop.travel(20.minutes.from_now) do
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
        rails_version: Rails.version,
        ruby_version: RUBY_VERSION
      )

      expect { collector.flush_redis }.to change { collector.read_each.to_a }.to([])
    end

    it "from activesupport" do
      allow(described_class).to receive(:stock_activesupport_behavior).and_return(:raise)
      expect do
        app_code = proc { ActiveSupport::Deprecation.warn("Test deprecation") }
        app_code[]
      rescue ActiveSupport::DeprecationException
        # в тестах это нормально
      end.to change(collector, :unsent_data?).from(false).to(true)

      collector.write_to_redis(force: true)
      item = collector.read_each.first
      expect(item).to include(
        message: include(
          "DEPRECATION WARNING: Test deprecation (called from block (4 levels) in <top (required)> at "\
          "spec/deprecation_collector_spec.rb:"
        ),
        realm: "rails"
      )
      expect(item[:gem_traceline]).to be_nil
      expect(item[:context]).to eq({ some: "context" })
      expect(item).not_to have_key(:gem_traceline)
    end

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
        app_traceline: %r{^spec/deprecation_collector_spec\.rb:\d+:in `block \(4 levels\) in <top \(required\)>'}
      )
      expect(item).not_to have_key(:gem_traceline)
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

    context "when deprecation_collector itself has a deprecation" do
      it "does not loop" do
        allow(collector).to receive(:log_deprecation_if_needed) { collector.collect("internal deprecation") }
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
        digest['Overriding "Content-Type" header "multipart/form-data" with '\
               '"multipart/form-data; boundary=----RubyFormBoundaryAfyRG13v44BT3gmJ"']
      ).to eq(digest['Overriding "" header "" with "lala"'])
    end

    it "ignores temporary views method names" do
      expect(digest[
        "Rails 6.1 will return Content-Type header without modification. "\
        "If you want just the MIME type, please use `#media_type` instead. "\
        "(called from _app_views_back_office_control_documents_utd_pdf_prawn__2671113783120882194_118963520 "\
        "at app/views/back_office/control/documents/utd.pdf.prawn:1)",
        "rails", [
          "app/views/some/view.pdf.prawn:170 block in _app_views_some_view_pdf_prawn__1733852578922288085_742240"
        ]]).to eq(
          digest[
            "Rails 6.1 will return Content-Type header without modification. "\
            "If you want just the MIME type, please use `#media_type` instead. "\
            "(called from _app_views_back_office_control_documents_utd_pdf_prawn__4007970162645015293_1241740 "\
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
  end
end
