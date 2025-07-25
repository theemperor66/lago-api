# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::WalletsController, type: :request do
  let(:organization) { create(:organization, webhook_url: nil) }
  let(:customer) { create(:customer, organization:, currency: "EUR") }
  let(:subscription) { create(:subscription, customer:) }
  let(:expiration_at) { (Time.current + 1.year).iso8601 }

  before { subscription }

  describe "POST /api/v1/wallets" do
    subject do
      post_with_token(organization, "/api/v1/wallets", {wallet: create_params})
    end

    let(:create_params) do
      {
        external_customer_id: customer.external_id,
        rate_amount: "1",
        name: "Wallet1",
        currency: "EUR",
        paid_credits: "10",
        granted_credits: "10",
        expiration_at:,
        invoice_requires_successful_payment: true
      }
    end

    include_examples "requires API permission", "wallet", "write"

    it "creates a wallet" do
      allow(WalletTransactions::CreateFromParamsService).to receive(:call!).and_call_original
      allow(SendWebhookJob).to receive(:perform_later).and_call_original
      stub_pdf_generation

      subject
      perform_all_enqueued_jobs

      expect(response).to have_http_status(:success)

      expect(json[:wallet][:lago_id]).to be_present
      expect(json[:wallet][:name]).to eq(create_params[:name])
      expect(json[:wallet][:external_customer_id]).to eq(customer.external_id)
      expect(json[:wallet][:expiration_at]).to eq(expiration_at)
      expect(json[:wallet][:invoice_requires_successful_payment]).to eq(true)

      expect(SendWebhookJob).to have_received(:perform_later).with("wallet.created", Wallet)

      expect(WalletTransactions::CreateFromParamsService).to have_received(:call!).with(
        organization: organization,
        params: hash_including(
          wallet_id: json[:wallet][:lago_id],
          paid_credits: "10",
          granted_credits: "10",
          source: :manual
        )
      )
    end

    context "with transaction metadata" do
      let(:create_params) do
        {
          external_customer_id: customer.external_id,
          rate_amount: "1",
          name: "Wallet1",
          currency: "EUR",
          paid_credits: "10",
          granted_credits: "10",
          expiration_at:,
          invoice_requires_successful_payment: true,
          transaction_metadata: [{key: "valid_value", value: "also_valid"}]
        }
      end

      before do
        allow(WalletTransactions::CreateJob).to receive(:perform_later).and_call_original
        subject
      end

      it "schedules a WalletTransactions::CreateJob with correct parameters" do
        expect(WalletTransactions::CreateJob).to have_received(:perform_later).with(
          organization_id: organization.id,
          params: hash_including(
            metadata: [{key: "valid_value", value: "also_valid"}]
          )
        )
      end

      context "when transaction metadata is a hash" do
        let(:create_params) do
          {
            external_customer_id: customer.external_id,
            rate_amount: "1",
            name: "Wallet1",
            currency: "EUR",
            paid_credits: "10",
            granted_credits: "10",
            expiration_at:,
            invoice_requires_successful_payment: true,
            transaction_metadata: {}
          }
        end

        it "returns a validation error" do
          expect(response).to have_http_status(:unprocessable_entity)
          expect(json[:error_details][:metadata]).to include("invalid_type")
        end
      end
    end

    context "with recurring transaction rules" do
      around { |test| lago_premium!(&test) }

      let(:create_params) do
        {
          external_customer_id: customer.external_id,
          rate_amount: "1",
          name: "Wallet1",
          currency: "EUR",
          paid_credits: "10",
          granted_credits: "10",
          expiration_at:,
          recurring_transaction_rules: [
            {
              trigger: "interval",
              interval: "monthly"
            }
          ]
        }
      end

      it "returns a success" do
        subject

        recurring_rules = json[:wallet][:recurring_transaction_rules]

        aggregate_failures do
          expect(response).to have_http_status(:success)

          expect(recurring_rules).to be_present
          expect(recurring_rules.first[:interval]).to eq("monthly")
          expect(recurring_rules.first[:paid_credits]).to eq("10.0")
          expect(recurring_rules.first[:granted_credits]).to eq("10.0")
          expect(recurring_rules.first[:method]).to eq("fixed")
          expect(recurring_rules.first[:trigger]).to eq("interval")
        end
      end

      context "when invoice_requires_successful_payment is set at the wallet level but the rule level" do
        let(:create_params) do
          {
            external_customer_id: customer.external_id,
            rate_amount: "1",
            name: "Wallet1",
            currency: "EUR",
            paid_credits: "10",
            expiration_at:,
            invoice_requires_successful_payment: true,
            recurring_transaction_rules: [
              {
                trigger: "interval",
                interval: "monthly"
              }
            ]
          }
        end

        it "follows the wallet configuration to create the rule" do
          subject

          recurring_rules = json[:wallet][:recurring_transaction_rules]

          aggregate_failures do
            expect(response).to have_http_status(:success)

            expect(json[:wallet][:invoice_requires_successful_payment]).to eq(true)
            expect(recurring_rules).to be_present
            expect(recurring_rules.first[:invoice_requires_successful_payment]).to eq(true)
          end
        end
      end

      context "when invoice_requires_successful_payment is set at the rule level but not present at the wallet level" do
        let(:create_params) do
          {
            external_customer_id: customer.external_id,
            rate_amount: "1",
            name: "Wallet1",
            currency: "EUR",
            paid_credits: "10",
            expiration_at:,
            recurring_transaction_rules: [
              {
                trigger: "interval",
                interval: "monthly",
                invoice_requires_successful_payment: true
              }
            ]
          }
        end

        it "follows the wallet configuration to create the rule" do
          subject

          recurring_rules = json[:wallet][:recurring_transaction_rules]
          expect(response).to have_http_status(:success)
          expect(json[:wallet][:invoice_requires_successful_payment]).to eq(false)
          expect(recurring_rules).to be_present
          expect(recurring_rules.first[:invoice_requires_successful_payment]).to eq(true)
        end
      end

      context "with expiration_at transaction rule" do
        let(:create_params) do
          {
            external_customer_id: customer.external_id,
            rate_amount: "1",
            name: "Wallet1",
            currency: "EUR",
            recurring_transaction_rules: [
              {
                trigger: "interval",
                interval: "monthly",
                expiration_at:,
                invoice_requires_successful_payment: true
              }
            ]
          }
        end

        it "create the rule with correct expiration_at" do
          subject

          recurring_rules = json[:wallet][:recurring_transaction_rules]

          aggregate_failures do
            expect(response).to have_http_status(:success)
            expect(recurring_rules).to be_present
            expect(recurring_rules.first[:expiration_at]).to eq(expiration_at)
          end
        end
      end

      context "with transaction metadata" do
        let(:create_params) do
          {
            external_customer_id: customer.external_id,
            rate_amount: "1",
            name: "Wallet1",
            currency: "EUR",
            paid_credits: "10",
            expiration_at:,
            recurring_transaction_rules: [
              {
                trigger: "interval",
                interval: "monthly",
                invoice_requires_successful_payment: true,
                transaction_metadata:
              }
            ]
          }
        end

        let(:transaction_metadata) { [{key: "valid_value", value: "also_valid"}] }

        it "create the rule with correct metadata" do
          subject

          recurring_rules = json[:wallet][:recurring_transaction_rules]

          aggregate_failures do
            expect(response).to have_http_status(:success)
            expect(recurring_rules).to be_present
            expect(recurring_rules.first[:transaction_metadata]).to eq(transaction_metadata)
          end
        end

        context "when transaction metadata is a hash" do
          let(:transaction_metadata) { {key: "valid_value", value: "also_valid"} }

          it "returns a validation error" do
            subject
            expect(response).to have_http_status(:unprocessable_entity)
            expect(json[:error_details][:recurring_transaction_rules]).to include("invalid_recurring_rule")
          end
        end
      end
    end

    context "with limitations" do
      let(:bm) { create(:billable_metric, organization:) }
      let(:create_params) do
        {
          external_customer_id: customer.external_id,
          rate_amount: "1",
          name: "Wallet1",
          currency: "EUR",
          paid_credits: "10",
          granted_credits: "10",
          expiration_at:,
          applies_to: {
            fee_types: %w[charge],
            billable_metric_codes: [bm.code]
          }
        }
      end

      it "returns a success" do
        subject

        limitations = json[:wallet][:applies_to]

        expect(response).to have_http_status(:success)
        expect(limitations).to be_present
        expect(limitations[:fee_types]).to eq(%w[charge])
        expect(limitations[:billable_metric_codes]).to eq([bm.code])
      end
    end
  end

  describe "PUT /api/v1/wallets/:id" do
    subject do
      put_with_token(
        organization,
        "/api/v1/wallets/#{id}",
        {wallet: update_params}
      )
    end

    let(:wallet) { create(:wallet, customer:) }
    let(:id) { wallet.id }
    let(:expiration_at) { (Time.current + 1.year).iso8601 }
    let(:update_params) do
      {
        name: "wallet1",
        expiration_at:,
        invoice_requires_successful_payment: true
      }
    end

    before { wallet }

    include_examples "requires API permission", "wallet", "write"

    it "updates a wallet" do
      subject

      aggregate_failures do
        expect(response).to have_http_status(:success)

        expect(json[:wallet][:lago_id]).to eq(wallet.id)
        expect(json[:wallet][:name]).to eq(update_params[:name])
        expect(json[:wallet][:expiration_at]).to eq(expiration_at)
        expect(json[:wallet][:invoice_requires_successful_payment]).to eq(true)

        expect(SendWebhookJob).to have_been_enqueued.with("wallet.updated", Wallet)
      end
    end

    context "when wallet does not exist" do
      let(:id) { SecureRandom.uuid }

      it "returns not_found error" do
        subject
        expect(response).to have_http_status(:not_found)
        expect(SendWebhookJob).not_to have_been_enqueued.with("wallet.updated", Wallet)
      end
    end

    context "with limitations" do
      let(:bm) { create(:billable_metric, organization:) }
      let(:update_params) do
        {
          name: "wallet1",
          applies_to: {
            fee_types: %w[charge],
            billable_metric_codes: [bm.code]
          }
        }
      end

      it "updates a wallet" do
        subject

        expect(response).to have_http_status(:success)
        expect(json[:wallet][:lago_id]).to eq(wallet.id)
        expect(json[:wallet][:name]).to eq(update_params[:name])
        expect(json[:wallet][:applies_to][:fee_types]).to eq(%w[charge])
        expect(json[:wallet][:applies_to][:billable_metric_codes]).to eq([bm.code])

        expect(SendWebhookJob).to have_been_enqueued.with("wallet.updated", Wallet)
      end
    end

    context "with recurring transaction rules" do
      around { |test| lago_premium!(&test) }

      let(:recurring_transaction_rule) { create(:recurring_transaction_rule, wallet:) }
      let(:update_params) do
        {
          name: "wallet1",
          recurring_transaction_rules: [
            {
              lago_id: recurring_transaction_rule.id,
              method: "target",
              trigger: "interval",
              interval: "weekly",
              paid_credits: "105",
              granted_credits: "105",
              target_ongoing_balance: "300",
              invoice_requires_successful_payment: true
            }
          ]
        }
      end

      before { recurring_transaction_rule }

      it "returns a success" do
        subject

        recurring_rules = json[:wallet][:recurring_transaction_rules]

        aggregate_failures do
          expect(response).to have_http_status(:success)

          expect(json[:wallet][:invoice_requires_successful_payment]).to eq(false)
          expect(recurring_rules).to be_present
          expect(recurring_rules.first[:lago_id]).to eq(recurring_transaction_rule.id)
          expect(recurring_rules.first[:interval]).to eq("weekly")
          expect(recurring_rules.first[:paid_credits]).to eq("105.0")
          expect(recurring_rules.first[:granted_credits]).to eq("105.0")
          expect(recurring_rules.first[:method]).to eq("target")
          expect(recurring_rules.first[:trigger]).to eq("interval")
          expect(recurring_rules.first[:invoice_requires_successful_payment]).to eq(true)

          expect(SendWebhookJob).to have_been_enqueued.with("wallet.updated", Wallet)
        end
      end

      context "when transaction expiration_at is set" do
        let(:expiration_at) { (Time.current + 2.years).iso8601 }
        let(:update_params) do
          {
            name: "wallet1",
            invoice_requires_successful_payment: true,
            recurring_transaction_rules: [
              {
                method: "target",
                trigger: "interval",
                interval: "weekly",
                paid_credits: "105",
                granted_credits: "105",
                target_ongoing_balance: "300",
                expiration_at:
              }
            ]
          }
        end

        it "updates the rule" do
          subject

          recurring_rules = json[:wallet][:recurring_transaction_rules]
          expect(response).to have_http_status(:success)
          expect(recurring_rules).to be_present
          expect(recurring_rules.first[:expiration_at]).to eq(expiration_at)
          expect(SendWebhookJob).to have_been_enqueued.with("wallet.updated", Wallet)
        end
      end

      context "when transaction metadata is set" do
        let(:update_params) do
          {
            name: "wallet1",
            invoice_requires_successful_payment: true,
            recurring_transaction_rules: [
              {
                method: "target",
                trigger: "interval",
                interval: "weekly",
                paid_credits: "105",
                granted_credits: "105",
                target_ongoing_balance: "300",
                transaction_metadata: update_transaction_metadata
              }
            ]
          }
        end

        let(:update_transaction_metadata) { [{key: "update_key", value: "update_value"}] }

        it "updates the rule" do
          subject

          recurring_rules = json[:wallet][:recurring_transaction_rules]
          aggregate_failures do
            expect(response).to have_http_status(:success)
            expect(recurring_rules).to be_present
            expect(recurring_rules.first[:transaction_metadata]).to eq(update_transaction_metadata)

            expect(SendWebhookJob).to have_been_enqueued.with("wallet.updated", Wallet)
          end
        end
      end

      context "when invoice_requires_successful_payment is updated at the wallet level" do
        let(:update_params) do
          {
            name: "wallet1",
            invoice_requires_successful_payment: true,
            recurring_transaction_rules: [
              {
                lago_id: rule_id,
                method: "target",
                trigger: "interval",
                interval: "weekly",
                paid_credits: "105",
                granted_credits: "105",
                target_ongoing_balance: "300",
                expiration_at:
              }
            ]
          }
        end

        context "when the rule exists" do
          let(:rule_id) { recurring_transaction_rule.id }

          it "updates the wallet and the rule" do
            subject

            recurring_rules = json[:wallet][:recurring_transaction_rules]

            aggregate_failures do
              expect(response).to have_http_status(:success)

              expect(json[:wallet][:invoice_requires_successful_payment]).to eq(true)
              expect(recurring_rules).to be_present
              expect(recurring_rules.first[:lago_id]).to eq(recurring_transaction_rule.id)
              expect(recurring_rules.first[:invoice_requires_successful_payment]).to eq(false)
              expect(recurring_rules.first[:expiration_at]).to eq(expiration_at)

              expect(SendWebhookJob).to have_been_enqueued.with("wallet.updated", Wallet)
            end
          end
        end

        context "when the rule does not exist" do
          let(:rule_id) { "does not exists in the db" }

          it "create a new rule and follow the new wallet configuration" do
            subject

            recurring_rules = json[:wallet][:recurring_transaction_rules]

            aggregate_failures do
              expect(response).to have_http_status(:success)

              expect(json[:wallet][:invoice_requires_successful_payment]).to eq(true)
              expect(recurring_rules).to be_present
              expect(recurring_rules.first[:invoice_requires_successful_payment]).to eq(true)

              expect(SendWebhookJob).to have_been_enqueued.with("wallet.updated", Wallet)
            end
          end
        end

        context "when the rule does not exist but the param is passed explicitly" do
          let(:wallet) { create(:wallet, customer:, invoice_requires_successful_payment: true) }
          let(:update_params) do
            {
              name: "wallet1",
              invoice_requires_successful_payment: false,
              recurring_transaction_rules: [
                {
                  lago_id: "does not exists in the db",
                  method: "target",
                  trigger: "interval",
                  interval: "weekly",
                  paid_credits: "105",
                  granted_credits: "105",
                  target_ongoing_balance: "300",
                  invoice_requires_successful_payment: true
                }
              ]
            }
          end

          it "create a new rule and ignores wallet configuration" do
            expect(wallet.invoice_requires_successful_payment).to eq(true)

            subject

            recurring_rules = json[:wallet][:recurring_transaction_rules]

            aggregate_failures do
              expect(response).to have_http_status(:success)

              expect(json[:wallet][:invoice_requires_successful_payment]).to eq(false)
              expect(recurring_rules).to be_present
              expect(recurring_rules.first[:invoice_requires_successful_payment]).to eq(true)

              expect(SendWebhookJob).to have_been_enqueued.with("wallet.updated", Wallet)
            end
          end
        end
      end
    end
  end

  describe "GET /api/v1/wallets/:id" do
    subject { get_with_token(organization, "/api/v1/wallets/#{id}") }

    let(:wallet) { create(:wallet, customer:) }
    let(:id) { wallet.id }

    include_examples "requires API permission", "wallet", "read"

    it "returns a wallet" do
      subject

      expect(response).to have_http_status(:success)
      expect(json[:wallet][:lago_id]).to eq(wallet.id)
      expect(json[:wallet][:name]).to eq(wallet.name)
    end

    context "when wallet does not exist" do
      let(:id) { SecureRandom.uuid }

      it "returns not found" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /api/v1/wallets/:id" do
    subject { delete_with_token(organization, "/api/v1/wallets/#{id}") }

    let(:wallet) { create(:wallet, customer:) }
    let(:id) { wallet.id }

    include_examples "requires API permission", "wallet", "write"

    it "terminates a wallet" do
      subject
      expect(wallet.reload.status).to eq("terminated")
    end

    it "returns terminated wallet" do
      subject

      expect(response).to have_http_status(:success)
      expect(json[:wallet][:lago_id]).to eq(wallet.id)
      expect(json[:wallet][:name]).to eq(wallet.name)
    end

    it "sends a wallet.terminated webhook" do
      expect { subject }.to have_enqueued_job(SendWebhookJob).with("wallet.terminated", Wallet)
    end

    context "when wallet does not exist" do
      let(:id) { SecureRandom.uuid }

      it "returns not_found error" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when wallet id does not belong to the current organization" do
      let(:other_org_wallet) { create(:wallet) }
      let(:id) { other_org_wallet.id }

      it "returns a not found error" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /api/v1/wallets" do
    subject do
      get_with_token(organization, "/api/v1/wallets?external_customer_id=#{external_id}&page=1&per_page=1")
    end

    let!(:wallet) { create(:wallet, customer:) }
    let(:external_id) { customer.external_id }

    include_examples "requires API permission", "wallet", "read"

    it "returns wallets" do
      subject

      expect(response).to have_http_status(:success)
      expect(json[:wallets].count).to eq(1)
      expect(json[:wallets].first[:lago_id]).to eq(wallet.id)
      expect(json[:wallets].first[:name]).to eq(wallet.name)
      expect(json[:wallets].first[:recurring_transaction_rules]).to be_empty
      expect(json[:wallets].first[:applies_to]).to be_present
    end

    context "with pagination" do
      before { create(:wallet, customer:) }

      it "returns wallets with correct meta data" do
        subject

        expect(response).to have_http_status(:success)

        expect(json[:wallets].count).to eq(1)
        expect(json[:meta][:current_page]).to eq(1)
        expect(json[:meta][:next_page]).to eq(2)
        expect(json[:meta][:prev_page]).to eq(nil)
        expect(json[:meta][:total_pages]).to eq(2)
        expect(json[:meta][:total_count]).to eq(2)
      end
    end

    context "when external_customer_id does not belong to the current organization" do
      let(:other_org_customer) { create(:customer) }
      let(:external_id) { other_org_customer.external_id }

      it "returns a not found error" do
        subject
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
