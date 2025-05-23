# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::Analytics::MrrsController, type: :request do # rubocop:disable RSpec/FilePath
  describe "GET /analytics/mrr" do
    subject { get_with_token(organization, "/api/v1/analytics/mrr", params) }

    let(:customer) { create(:customer, organization:) }
    let(:organization) { create(:organization) }
    let(:billing_entity) { create(:billing_entity, organization: organization) }
    let(:params) { {} }

    before do
      allow(Analytics::MrrsService).to receive(:call).and_call_original
    end

    context "when license is premium" do
      around { |test| lago_premium!(&test) }

      include_examples "requires API permission", "analytic", "read"

      it "returns the mrr" do
        subject

        expect(response).to have_http_status(:success)

        month = DateTime.parse json[:mrrs].first[:month]

        expect(month).to eq(DateTime.current.beginning_of_month)
        expect(json[:mrrs].first[:currency]).to eq(nil)
        expect(json[:mrrs].first[:amount_cents]).to eq(nil)
        expect(Analytics::MrrsService).to have_received(:call).with(organization, billing_entity_id: nil, currency: nil, months: nil)
      end

      context "when sending params" do
        let(:params) { {billing_entity_code: billing_entity.code} }

        it "calls the service with the billing_entity_id" do
          subject
          expect(Analytics::MrrsService).to have_received(:call).with(organization, billing_entity_id: billing_entity.id, currency: nil, months: nil)
        end
      end
    end

    context "when license is not premium" do
      it "returns forbidden status" do
        subject
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
