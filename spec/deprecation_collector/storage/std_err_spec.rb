# frozen_string_literal: true

require "spec_helper"

RSpec.describe "DeprecationCollector::Storage::StdErr" do
  before(:context) do
    DeprecationCollector.instance_variable_set(:@instance, nil)
    DeprecationCollector.instance_variable_set(:@installed, true) # to skip at_exit
    DeprecationCollector.install do |instance|
      instance.storage = DeprecationCollector::Storage::StdErr.new
      instance.app_root = File.expand_path("..", __dir__)
    end
  end

  let(:collector) { DeprecationCollector.instance }

  it "writes to stderr" do
    expect($stderr).to receive(:puts).with(a_string_matching(/TestDeprecation/)).twice
    2.times { collector.collect("TestDeprecation") }
  end
end
