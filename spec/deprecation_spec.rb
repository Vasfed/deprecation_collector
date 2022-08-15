# frozen_string_literal: true

require "spec_helper"

RSpec.describe DeprecationCollector::Deprecation do
  subject(:deprecation) { described_class.new(message, :some_realm, backtrace) }

  let(:message) { "some message" }
  let(:backtrace) { caller }
  let(:redis) { described_class.instance.redis }

  it { expect(deprecation.app_traceline).to start_with("spec/deprecation_spec.rb") }
end
