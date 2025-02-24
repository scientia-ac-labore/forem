require "rails_helper"

RSpec.describe "Api::V0::Users", type: :request do
  let(:api_secret) { create(:api_secret) }
  let(:v1_headers) { { "api-key" => api_secret.secret, "Accept" => "application/vnd.forem.api-v1+json" } }
  let(:listener) { :admin_api }

  describe "GET /api/users/:id" do
    before { allow(FeatureFlag).to receive(:enabled?).with(:api_v1).and_return(true) }

    let!(:user) do
      create(:user,
             profile_image: "",
             _skip_creating_profile: true,
             profile: create(:profile, summary: "Something something"))
    end

    context "when unauthenticated" do
      it "returns unauthorized" do
        get api_user_path("by_username"),
            params: { url: user.username },
            headers: { "Accept" => "application/vnd.forem.api-v1+json" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when unauthorized" do
      it "returns unauthorized" do
        get api_user_path("by_username"),
            params: { url: user.username },
            headers: v1_headers.merge({ "api-key" => "invalid api key" })
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "returns 404 if the user id is not found" do
      get api_user_path("invalid-id")

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 if the user username is not found" do
      get api_user_path("by_username"), params: { url: "invalid-username" }
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 if the user is not registered" do
      user.update_column(:registered, false)
      get api_user_path(user.id)
      expect(response).to have_http_status(:not_found)
    end

    it "returns 200 if the user username is found" do
      get api_user_path("by_username"), params: { url: user.username }
      expect(response).to have_http_status(:ok)
    end

    it "returns unauthenticated if no authentication and the Forem instance is set to private" do
      allow(Settings::UserExperience).to receive(:public).and_return(false)
      get api_user_path("by_username"), params: { url: user.username }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the correct json representation of the user", :aggregate_failures do
      get api_user_path(user.id)

      response_user = response.parsed_body

      expect(response_user["type_of"]).to eq("user")

      %w[id username name twitter_username github_username].each do |attr|
        expect(response_user[attr]).to eq(user.public_send(attr))
      end

      %w[summary website_url location].each do |attr|
        expect(response_user[attr]).to eq(user.profile.public_send(attr))
      end

      expect(response_user["joined_at"]).to eq(user.created_at.strftime("%b %e, %Y"))
      expect(response_user["profile_image"]).to eq(user.profile_image_url_for(length: 320))
    end
  end

  describe "GET /api/users/me" do
    before { allow(FeatureFlag).to receive(:enabled?).with(:api_v1).and_return(true) }

    context "when unauthenticated" do
      it "returns unauthorized" do
        get me_api_users_path, headers: { "Accept" => "application/vnd.forem.api-v1+json" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when unauthorized" do
      it "returns unauthorized" do
        get me_api_users_path, headers: v1_headers.merge({ "api-key" => "invalid api key" })
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when request is authenticated" do
      let(:user) { api_secret.user }

      it "returns the correct json representation of the user", :aggregate_failures do
        get me_api_users_path, headers: v1_headers

        expect(response).to have_http_status(:ok)

        response_user = response.parsed_body

        expect(response_user["type_of"]).to eq("user")

        %w[id username name twitter_username github_username].each do |attr|
          expect(response_user[attr]).to eq(user.public_send(attr))
        end

        %w[summary website_url location].each do |attr|
          expect(response_user[attr]).to eq(user.profile.public_send(attr))
        end

        expect(response_user["joined_at"]).to eq(user.created_at.strftime("%b %e, %Y"))
        expect(response_user["profile_image"]).to eq(user.profile_image_url_for(length: 320))
      end

      it "returns 200 if no authentication and the Forem instance is set to private but user is authenticated" do
        allow(Settings::UserExperience).to receive(:public).and_return(false)
        get me_api_users_path, headers: v1_headers

        response_user = response.parsed_body

        expect(response_user["type_of"]).to eq("user")

        %w[id username name twitter_username github_username].each do |attr|
          expect(response_user[attr]).to eq(user.public_send(attr))
        end

        %w[summary website_url location].each do |attr|
          expect(response_user[attr]).to eq(user.profile.public_send(attr))
        end

        expect(response_user["joined_at"]).to eq(user.created_at.strftime("%b %e, %Y"))
        expect(response_user["profile_image"]).to eq(user.profile_image_url_for(length: 320))
      end
    end
  end

  describe "PUT /api/users/:id/suspend", :aggregate_failures do
    let(:target_user) { create(:user) }
    let(:payload) { { note: "Violated CoC despite multiple warnings" } }

    before do
      allow(FeatureFlag).to receive(:enabled?).with(:api_v1).and_return(true)
      Audit::Subscribe.listen listener
    end

    context "when unauthenticated" do
      it "returns unauthorized" do
        put api_user_suspend_path(id: target_user.id),
            params: payload,
            headers: { "Accept" => "application/vnd.forem.api-v1+json" }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when unauthorized" do
      it "returns unauthorized if api key is invalid" do
        put api_user_suspend_path(id: target_user.id),
            params: payload,
            headers: v1_headers.merge({ "api-key" => "invalid api key" })

        expect(response).to have_http_status(:unauthorized)
      end

      it "returns unauthorized if api key belongs to non-admin user" do
        put api_user_suspend_path(id: target_user.id),
            params: payload,
            headers: v1_headers

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when request is authenticated" do
      before { api_secret.user.add_role(:super_admin) }

      it "is successful in suspending a user", :aggregate_failures do
        expect do
          put api_user_suspend_path(id: target_user.id),
              params: payload,
              headers: v1_headers

          expect(response).to have_http_status(:no_content)
          expect(target_user.reload.suspended?).to be true
          expect(Note.last.content).to eq(payload[:note])
        end.to change(Note, :count).by(1)
      end

      it "creates an audit log of the action taken" do
        put api_user_suspend_path(id: target_user.id),
            params: payload,
            headers: v1_headers

        log = AuditLog.last
        expect(log.category).to eq(AuditLog::ADMIN_API_AUDIT_LOG_CATEGORY)
        expect(log.data["action"]).to eq("api_user_suspend")
        expect(log.data["target_user_id"]).to eq(target_user.id)
        expect(log.user_id).to eq(api_secret.user.id)
      end
    end
  end

  describe "PUT /api/users/:id/unpublish", :aggregate_failures do
    let(:target_user) { create(:user) }
    let!(:target_articles) { create_list(:article, 3, user: target_user, published: true) }
    let!(:target_comments) { create_list(:comment, 3, user: target_user) }

    before do
      allow(FeatureFlag).to receive(:enabled?).with(:api_v1).and_return(true)
      Audit::Subscribe.listen listener
    end

    context "when unauthenticated" do
      it "returns unauthorized" do
        put api_user_unpublish_path(id: target_user.id),
            headers: { "Accept" => "application/vnd.forem.api-v1+json" }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when unauthorized" do
      it "returns unauthorized if api key is invalid" do
        put api_user_unpublish_path(id: target_user.id),
            headers: v1_headers.merge({ "api-key" => "invalid api key" })

        expect(response).to have_http_status(:unauthorized)
      end

      it "returns unauthorized if api key belongs to non-admin user" do
        put api_user_unpublish_path(id: target_user.id),
            headers: v1_headers

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when request is authenticated" do
      before { api_secret.user.add_role(:super_admin) }

      it "is successful in unpublishing a user's comments and articles", :aggregate_failures do
        # User's articles are published and comments exist
        expect(target_articles.map(&:published?)).to match_array([true, true, true])
        expect(target_comments.map(&:deleted)).to match_array([false, false, false])

        put api_user_unpublish_path(id: target_user.id),
            headers: v1_headers
        expect(response).to have_http_status(:no_content)

        sidekiq_perform_enqueued_jobs

        # Ensure article's aren't published and comments deleted
        # (with boolean attribute so they can be reverted if needed)
        expect(target_articles.map(&:reload).map(&:published?)).to match_array([false, false, false])
        expect(target_comments.map(&:reload).map(&:deleted)).to match_array([true, true, true])
      end

      it "creates an audit log of the action taken" do
        # These deleted comments/articles are important so that the AuditLog trail won't
        # include previously deleted resources like these in the log. Otherwise the revert
        # action on these would have unintended consequences, i.e. revert a delete/unpublish
        # that wasn't affected by the action taken in the API endpoint request.
        create(:article, user: target_user, published: false)
        create(:comment, user: target_user, deleted: true)

        put api_user_unpublish_path(id: target_user.id),
            headers: v1_headers

        log = AuditLog.last
        expect(log.category).to eq(AuditLog::ADMIN_API_AUDIT_LOG_CATEGORY)
        expect(log.data["action"]).to eq("api_user_unpublish")
        expect(log.user_id).to eq(api_secret.user.id)

        # These ids match the affected articles/comments and not the ones created above
        expect(log.data["target_article_ids"]).to match_array(target_articles.map(&:id))
        expect(log.data["target_comment_ids"]).to match_array(target_comments.map(&:id))
      end
    end
  end
end
