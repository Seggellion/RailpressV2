require "test_helper"
require_relative "../support/theme_test_support"
require_relative "../support/administration_test_support"

class ProtectedPresentationTest < ActionDispatch::IntegrationTest
  include ThemeTestSupport
  include AdministrationTestSupport

  def assert_protected_failure(status, message)
    assert_response status
    assert_equal "text/html", response.media_type
    assert_select "body.core", count: 1
    assert_select "h1", text: "Request stopped safely"
    assert_select '[role="alert"]', text: message
    assert_select 'link[rel="stylesheet"][href*="protected_dark"]', count: 1
    assert_select 'link[href*="theme-assets"], [data-theme]', count: 0
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_select "#admin-protected", count: 0
  end

  test "HTML CSRF role and last owner refusals retain their guards in the core shell" do
    sign_in
    post "/admin/themes/revert", params: { version: 0 }
    assert_protected_failure(:unprocessable_entity, "The form expired or could not be verified. Reload the page and try again.")
    assert_nil ThemeState.first&.active_installation_id

    csrf = csrf_token_for(self, "/admin/users")
    patch "/admin/users/#{@owner.id}", params: { authenticity_token: csrf, user: { role: "editor" } }
    assert_protected_failure(:conflict, "The last owner cannot be removed or demoted.")
    assert @owner.reload.owner?

    sign_in(self, @editor)
    get "/admin/themes"
    assert_protected_failure(:forbidden, "This action is not permitted.")
    assert_equal "editor", @editor.reload.role
  end

  test "non HTML denial remains the exact plain protocol response" do
    sign_in(self, @editor)
    get "/admin/themes", headers: { "Accept" => "application/json" }
    assert_response :forbidden
    assert_equal "text/plain", response.media_type
    assert_equal "This action is not permitted.", response.body
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "unavailable bootstrap still renders a safe dark HTML error without resolving a theme or account" do
    with_method(Railpress::BootstrapState, :for_application, -> { raise IOError, "PRIVATE INTERNAL CANARY" }) do
      get "/login"
    end
    assert_protected_failure(:service_unavailable, "Private setup state is unavailable. Contact the host operator.")
    refute_includes response.body, "PRIVATE INTERNAL CANARY"
    assert_select "input[name=password]", count: 0
  end

  test "public body remains outside protected styling and broken theme cannot replace admin" do
    dusk = stage("dusk")
    activate(dusk)
    get "/"
    assert_response :ok
    assert_select "body.public-content", count: 1
    assert_select "body.core", count: 0
    package = stage(mutate: ->(manifest, directory) do
      Railpress::ThemeFixture.replace(manifest, directory, "templates/home.html.erb", '<% raise "broken public component" if theme.site.title == "Synthetic Railpress" %><p>Safe smoke</p>')
    end)
    activate(package)
    get "/"
    assert_response :service_unavailable
    assert_includes response.body, "Site temporarily unavailable"
    sign_in
    get "/admin/themes"
    assert_response :ok
    assert_select "body.core.admin-shell", count: 1
    assert_select 'link[rel="stylesheet"][href*="protected_dark"]', count: 1
    assert_select 'link[href*="theme-assets"], [data-theme]', count: 0
    assert_select "header img.brand-mark[src=?][alt=''][aria-hidden=true]", CoreBrandHelper::MARK, count: 1
    assert_select "aside .admin-sidebar-brand img[src=?][alt=''][aria-hidden=true]", CoreBrandHelper::MARK, count: 1
    assert_select "summary.admin-toggle img[src=?][alt=''][aria-hidden=true]", CoreBrandHelper::MARK, count: 1
    assert_select 'link[rel="icon"][href=?][type="image/png"][sizes="32x32"]', CoreBrandHelper::PNG_ICON, count: 1
    assert_select 'link[rel="icon"][type="image/svg+xml"]', count: 0
    assert_equal package.id, ThemeState.first.active_installation_id
    get "/login"
    assert_response :ok
    assert_select "body.core", count: 1
    assert_select "img.brand-mark[src=?][alt='']", CoreBrandHelper::MARK, count: 1
  end
end
