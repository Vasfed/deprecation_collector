# frozen_string_literal: true

begin
  require "active_record"
rescue LoadError
  return
end

require "spec_helper"
# require "deprecation_collector/storage/active_record"

class Deprecation < ActiveRecord::Base; end
class WrongTable < ActiveRecord::Base; end

RSpec.describe "DeprecationCollector::Storage::ActiveRecord" do
  subject(:storage) { collector.storage }

  before(:context) do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    # ActiveRecord::Base.logger = Logger.new(STDOUT)
    ActiveRecord::Schema.define do
      create_table :deprecations, force: true do |t|
        t.string :digest, null: false
        # t.jsonb :data, null: false
        t.json :data, null: false # sqlite does not work with jsonb
        t.text :notes
        t.timestamps
        t.index :digest, unique: true
      end

      create_table :wrong_tables, force: true
    end

    DeprecationCollector.instance_variable_set(:@instance, nil)
    DeprecationCollector.instance_variable_set(:@installed, true) # to skip at_exit
    DeprecationCollector.install do |instance|
      # instance.storage = DeprecationCollector::Storage::ActiveRecord.new(model: ::Deprecation)
      instance.model = ::Deprecation # rubocop:disable Style/RedundantConstantBase
      # instance.app_revision = "somerevisionabc123"
      instance.app_root = File.expand_path("..", __dir__)
    end
  end

  let(:collector) { DeprecationCollector.instance }
  let(:model) { Deprecation }

  before do
    storage.flush(force: true)
    storage.clear
  end

  describe "model validation" do
    it "checks methods" do
      expect { storage.model = Class.new }.to raise_error(/column_names/)
      expect { storage.model = WrongTable }.to raise_error(/fields/)
    end
  end

  it "green way" do
    expect do
      2.times do
        collector.collect("Test")
      end
    end.to change(collector, :unsent_data?).to(true)

    expect { storage.flush(force: true) }.to change(model, :count).by(1)

    expect(collector.read_each.to_a.first).to include(message: "Test")
    expect { storage.clear }.to change(model, :count).by(-1)
  end

  describe "cleanup" do
    before do
      collector.collect("Test1")
      collector.collect("Test2")
      storage.flush(force: true)
    end

    it "cleans" do
      expect do
        collector.cleanup { |d| d[:message] == "Test2" }
      end.to change(model, :count).by(-1)
    end
  end

  describe "readone" do
    let(:deprecation_record) do
      collector.collect("Test1")
      storage.flush(force: true)
      model.last
    end
    let!(:digest) { deprecation_record.digest }

    it "reads" do
      expect(collector.read_one("1234not_existent")).to be_nil
      expect(collector.read_one(digest)).to include(message: "Test1")
    end
  end

  describe "dump/import" do
    before do
      2.times { |i| collector.collect("Test#{i}") }
      storage.flush(force: true)
    end

    it "imports" do
      dump = collector.dump
      expect { storage.clear }.to change(model, :count).to(0)
      expect { collector.import_dump(dump) }.to change(model, :count).from(0).to(2)
    end
  end
end
