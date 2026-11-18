require "test_helper"

class AdminCapabilityTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  setup { install_site! }

  test "every non-owner role is denied sensitive guessed endpoints" do
    %w[administrator editor author].each do |role|
      user = create_account(role)
      sign_in(self, user)
      assert_response :see_other
      %w[/admin/themes /admin/updates /admin/users /admin/settings].each do |path|
        get path
        assert_response :forbidden
      end
      csrf = csrf_token_for(self, "/admin")
      post "/admin/seo/execute", params: { authenticity_token: csrf }
      assert_response :forbidden
      post "/admin/updates/stage", params: { authenticity_token: csrf, command: "not-a-host-command" }
      assert_response :forbidden
      patch "/admin/settings", params: { authenticity_token: csrf, site: { title: "Unauthorized" } }
      assert_response :forbidden
    end
    assert_equal "Synthetic Railpress", Site.first.title
  end

  test "owner gates keep future theme updates deferred and queue implemented SEO checks" do
    sign_in
    get "/admin/themes"
    assert_response :ok
    assert_includes response.body, "API v1"
    %w[/admin/updates].each do |path|
      get path
      assert_response :ok
      assert_includes response.body, "UNSUPPORTED"
    end
    csrf = csrf_token_for(self, "/admin")
    post "/admin/seo/execute", params: { authenticity_token: csrf }
    assert_response :see_other
    assert_equal "pending", Seo::DiagnosticRun.last.status
    post "/admin/updates/stage", params: { authenticity_token: csrf, command: "not-a-host-command" }
    assert_response :not_implemented
    get "/admin/operator"
    assert_response :not_found
  end

  test "HTTP role mutation revokes prior user sessions immediately" do
    user = create_account("author")
    client = ActionDispatch::Integration::Session.new(Rails.application)
    client.https!
    sign_in(client, user)
    sign_in
    csrf = csrf_token_for(self, "/admin/users")
    patch "/admin/users/#{user.id}", params: { authenticity_token: csrf, user: { role: "editor", auth_version: 0, password: "ignored" } }
    assert_response :see_other
    assert_equal "editor", user.reload.role
    assert_equal 1, user.auth_version
    client.get("/admin")
    assert_equal 303, client.response.status
    assert_equal 1, UserSession.count
  end

  test "owner cannot remove the last owner through HTTP" do
    sign_in
    csrf = csrf_token_for(self, "/admin/users")
    delete "/admin/users/#{@owner.id}", params: { authenticity_token: csrf }
    assert_response :conflict
    assert_equal 1, User.count
    patch "/admin/users/#{@owner.id}", params: { authenticity_token: csrf, user: { role: "author" } }
    assert_response :conflict
    assert @owner.reload.owner?
  end

  test "site identity updates validate and escape output without accepting install or owner fields" do
    sign_in
    csrf = csrf_token_for(self, "/admin/settings")
    id = Site.first.install_id
    patch "/admin/settings", params: { authenticity_token: csrf, site: site_attributes.merge(title: "<img src=x onerror=alert(1)>", install_id: SecureRandom.uuid, owner_id: 9999, indexing_enabled: "0") }
    assert_response :see_other
    assert_equal id, Site.first.install_id
    assert_equal @owner.id, Site.first.owner_id
    get "/admin"
    assert_select "h1 img", count: 0
    assert_includes response.body, "&lt;img"
    csrf = csrf_token_for(self, "/admin/settings")
    patch "/admin/settings", params: { authenticity_token: csrf, site: { canonical_origin: "javascript:alert(1)" } }
    assert_response :unprocessable_entity
    assert_equal "https://publishing.example.invalid", Site.first.canonical_origin
  end
end
