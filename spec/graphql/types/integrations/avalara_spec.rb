# frozen_string_literal: true

require "rails_helper"

RSpec.describe Types::Integrations::Avalara do
  subject { described_class }

  it do
    expect(subject).to have_field(:id).of_type("ID!")

    expect(subject).to have_field(:license_key).of_type("ObfuscatedString!")
    expect(subject).to have_field(:account_id).of_type("String")
    expect(subject).to have_field(:code).of_type("String!")
    expect(subject).to have_field(:company_code).of_type("String!")
    expect(subject).to have_field(:failed_invoices_count).of_type("Int")
    expect(subject).to have_field(:has_mappings_configured).of_type("Boolean")
    expect(subject).to have_field(:name).of_type("String!")
  end
end
