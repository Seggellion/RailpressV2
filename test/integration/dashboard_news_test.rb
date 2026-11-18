require "test_helper"
require_relative "../support/official_news_test_support"
require_relative "../support/administration_test_support"
class DashboardNewsTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  include OfficialNewsTestSupport
  include AdministrationTestSupport
  setup { install_site! }
  test "dashboard has real working forms core-only assets and scoped actions for all four roles" do
    [ @owner, *%w[administrator editor author].map { |r|create_account(r) } ].each do |actor|
      sign_in(self, actor)
      with_method(OfficialNews::Client, :new, -> { raise "Dashboard must never construct HTTP client" }) do
        get "/admin"
        assert_response :ok
        assert_includes response.body, "Quick Draft"
        assert_includes response.body, "DISABLED"
        assert_select 'form[action="/admin/quick-draft"]', 1
        assert_select 'script[src^="https://"]', 0
        assert_select 'img[src^="https://"]', 0
        assert_select 'a[href="/admin/official-news"]', actor.owner? ? 2 : 0
      end
      token=csrf_token_for(self, "/admin")
      key=SecureRandom.uuid
      params={ authenticity_token: token, draft: { request_key: key, version: 0, kind: "Post", title: "Draft by #{actor.username}", body: "A real working copy." } }
      2.times { post "/admin/quick-draft", params: params;assert_response :see_other }
      item=Content.find_by!(title: "Draft by #{actor.username}")
      assert_equal actor.id, item.author_id
      assert_equal "private", item.visibility
      assert_equal "draft", item.status
      assert_equal 1, DashboardDraftSubmission.where(request_key: key).count
    end
    assert_equal 4, Content.count
  end
  test "quick draft rejects missing CSRF malformed keys injected fields and stale identity without partial writes" do
    sign_in
    params={ draft: { request_key: SecureRandom.uuid, version: 0, kind: "Post", title: "Valid draft", body: "" } }
    post "/admin/quick-draft", params: params;assert_response :unprocessable_entity
    token=csrf_token_for(self, "/admin")
    [ { request_key: "../unsafe" }, { version: 2 }, { kind: "User" }, { title: "" }, { author_id: @owner.id }, { visibility: "public" } ].each do |mutation|
      post "/admin/quick-draft", params: params.merge(authenticity_token: token, draft: params[:draft].merge(mutation))
      assert_response :unprocessable_entity
    end
    assert_empty Content.all
    assert_empty DashboardDraftSubmission.all
  end
  test "news controls deny direct non Owner requests and reject arbitrary destination parameters" do
    %w[administrator editor author].each do |role|
      actor=create_account(role);sign_in(self, actor)
      token=csrf_token_for(self, "/admin")
      get "/admin/official-news";assert_response :forbidden
      patch "/admin/official-news", params: { authenticity_token: token, operation: "enable", version: 0 };assert_response :forbidden
      post "/admin/official-news/review", params: { authenticity_token: token, content_id: 1, version: 0 };assert_response :forbidden
    end
    sign_in
    token=csrf_token_for(self, "/admin/official-news")
    patch "/admin/official-news", params: { authenticity_token: token, operation: "enable", version: 0, url: "http://127.0.0.1/" };assert_response :unprocessable_entity
    assert_empty OfficialNewsState.all
  end
  test "ordinary public metadata endpoint is disabled by default and uses reviewed canonical snapshots and ETags" do
    get "/api/public/v1/news.json";assert_response :not_found
    provider_site
    post=news_post;record=review(post)
    get "/api/public/v1/news.json", headers: { "Host"=>"malicious.invalid" }
    assert_response :ok
    data=JSON.parse(response.body)
    assert_equal record.public_id, data["items"][0]["id"]
    assert_equal "https://railpress.org/blog/reviewed-public-post", data["items"][0]["url"]
    etag=response.headers["ETag"]
    refute_includes response.body, @owner.email
    refute_includes response.body, "PRIVATE BODY"
    get "/api/public/v1/news.json", headers: { "If-None-Match"=>etag };assert_response :not_modified
    Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, event: "unpublish")
    get "/api/public/v1/news.json", headers: { "If-None-Match"=>etag };assert_response :ok
    assert_empty JSON.parse(response.body)["items"]
  end
end
