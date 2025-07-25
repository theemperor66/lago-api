# frozen_string_literal: true

require "rails_helper"

RSpec.describe UsersService, type: :service do
  subject(:user_service) { described_class.new }

  describe "register" do
    it "calls SegmentIdentifyJob" do
      allow(SegmentIdentifyJob).to receive(:perform_later)
      result = user_service.register("email", "password", "organization_name")

      expect(SegmentIdentifyJob).to have_received(:perform_later).with(
        membership_id: "membership/#{result.membership.id}"
      )
    end

    it "calls SegmentTrackJob" do
      allow(SegmentTrackJob).to receive(:perform_later)
      result = user_service.register("email", "password", "organization_name")

      expect(SegmentTrackJob).to have_received(:perform_later).with(
        membership_id: "membership/#{result.membership.id}",
        event: "organization_registered",
        properties: {
          organization_name: result.organization.name,
          organization_id: result.organization.id
        }
      )
    end

    it "creates an organization, user and membership" do
      result = user_service.register("email", "password", "organization_name")
      expect(result.user).to be_present
      expect(result.membership).to be_present
      expect(result.token).to be_present

      decoded = Auth::TokenService.decode(token: result.token)
      expect(decoded["login_method"]).to eq(Organizations::AuthenticationMethods::EMAIL_PASSWORD)

      expect(result.organization)
        .to be_present
        .and have_attributes(name: "organization_name", document_numbering: "per_organization")
    end

    context "when user already exists" do
      let(:user) { create(:user) }

      it "fails" do
        result = user_service.register(user.email, "password", "organization_name")

        aggregate_failures do
          expect(result).not_to be_success
          expect(result.error).to be_a(BaseService::ValidationFailure)
          expect(result.error.messages.keys).to include(:email)
          expect(result.error.messages[:email]).to include("user_already_exists")
        end
      end
    end

    context "when signup is disabled" do
      before do
        ENV["LAGO_DISABLE_SIGNUP"] = "true"
      end

      after do
        ENV["LAGO_DISABLE_SIGNUP"] = nil
      end

      it "returns a not allowed error" do
        result = user_service.register("email", "password", "organization_name")

        aggregate_failures do
          expect(result).not_to be_success
          expect(result.error.message).to eq("signup_disabled")
        end
      end
    end
  end

  describe "register_from_invite" do
    let(:email) { Faker::Internet.email }

    context "when user already exists" do
      it "creates user and membership if user doesn't exist" do
        create(:user, email:)
        invite = create(:invite, email:)

        result = user_service.register_from_invite(invite, nil)

        expect(result.user).to be_persisted
        expect(result.user.email).to eq email
        expect(result.membership).to be_persisted
        expect(result.organization).to eq invite.organization
        expect(result.token).to be_present
      end
    end

    context "when user doesn't exist" do
      it "creates user and membership if user doesn't exist" do
        invite = create(:invite, email:)

        result = user_service.register_from_invite(invite, "password")

        expect(result.user).to be_persisted
        expect(result.user.email).to eq email
        expect(result.membership).to be_present
        expect(result.organization).to eq invite.organization
        expect(result.token).to be_present
      end
    end
  end

  describe "login" do
    subject(:result) { described_class.new.login(email, password) }

    let!(:membership) { create(:membership, :revoked) }
    let(:user) { membership.user }

    context "when user with given email exists" do
      let(:email) { user.email }

      context "when password is correct" do
        let(:password) { user.password }

        context "when user has active membership" do
          let!(:active_membership) { create(:membership, user:, organization: membership.organization) }

          it "returns success result" do
            expect(result).to be_success
            expect(result.user).to eq user
            expect(result.token).to be_present
          end

          it "calls SegmentIdentifyJob with user's first active membership" do
            allow(SegmentIdentifyJob).to receive(:perform_later)
            subject

            expect(SegmentIdentifyJob).to have_received(:perform_later).with(
              membership_id: "membership/#{active_membership.id}"
            )
          end

          context "when login succeed" do
            it "saves the login method in token" do
              expect(result).to be_success

              decoded = Auth::TokenService.decode(token: result.token)
              expect(decoded["login_method"]).to eq(Organizations::AuthenticationMethods::EMAIL_PASSWORD)
            end
          end

          context "when login method is not allowed" do
            before { active_membership.organization.disable_email_password_authentication! }

            it "fails with login method not authorized" do
              expect(result).to be_failure
              expect(result.user).to eq user
              expect(result.token).to be nil
              expect(result.error.messages).to match(email_password: ["login_method_not_authorized"])
            end
          end
        end

        context "when user has no active membership" do
          it "fails with incorrect credentials error" do
            expect(result).to be_failure
            expect(result.user).to eq user
            expect(result.token).to be nil
            expect(result.error.messages).to match(base: ["incorrect_login_or_password"])
          end

          it "does not call SegmentIdentifyJob" do
            allow(SegmentIdentifyJob).to receive(:perform_later)
            subject

            expect(SegmentIdentifyJob).not_to have_received(:perform_later)
          end
        end
      end

      context "when password is incorrect" do
        let(:password) { "invalid-password" }

        context "when user has active membership" do
          before { create(:membership, user:, organization: membership.organization) }

          it "fails with incorrect credentials error" do
            expect(result).to be_failure
            expect(result.user).to be false
            expect(result.token).to be nil
            expect(result.error.messages).to match(base: ["incorrect_login_or_password"])
          end

          it "does not call SegmentIdentifyJob" do
            allow(SegmentIdentifyJob).to receive(:perform_later)
            subject

            expect(SegmentIdentifyJob).not_to have_received(:perform_later)
          end
        end

        context "when user has no active membership" do
          it "fails with incorrect credentials error" do
            expect(result).to be_failure
            expect(result.user).to be false
            expect(result.token).to be nil
            expect(result.error.messages).to match(base: ["incorrect_login_or_password"])
          end

          it "does not call SegmentIdentifyJob" do
            allow(SegmentIdentifyJob).to receive(:perform_later)
            subject

            expect(SegmentIdentifyJob).not_to have_received(:perform_later)
          end
        end
      end
    end

    context "when user with given does not email exist" do
      let(:email) { "non-existing-user@email.com" }
      let(:password) { "invalid-password" }

      it "fails with incorrect credentials error" do
        expect(result).to be_failure
        expect(result.user).to be nil
        expect(result.token).to be nil
        expect(result.error.messages).to match(base: ["incorrect_login_or_password"])
      end

      it "does not call SegmentIdentifyJob" do
        allow(SegmentIdentifyJob).to receive(:perform_later)
        subject

        expect(SegmentIdentifyJob).not_to have_received(:perform_later)
      end
    end
  end
end
