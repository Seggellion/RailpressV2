require "test_helper"
require_relative "../support/seo_test_support"
class SeoAdminTest < ActionDispatch::IntegrationTest
  include SeoTestSupport
  test "SEO inspection and execution enforce owner capability and CSRF directly" do
    get admin_seo_path
    assert_redirected_to "/login"
    sign_in(self, @editor)
    get admin_seo_path
    assert_response :forbidden
    token=csrf_token_for(self, admin_path)
    post admin_seo_execute_path, params: { authenticity_token: token }
    assert_response :forbidden
    sign_in(self, @owner)
    token=csrf_token_for(self, admin_seo_path)
    assert_includes response.body, "Google indexing, ranking and crawling are unknown"
    post admin_seo_execute_path
    assert_response :unprocessable_entity
    post admin_seo_execute_path, params: { authenticity_token: token, mode: "offline", url: "https://evil.invalid/admin" }
    assert_response :see_other
    assert_equal 1, Seo::DiagnosticRun.count
    assert_equal 0, Seo::DiagnosticTarget.count
    get admin_seo_path
    assert_includes response.body, "Not checked" if Seo::DiagnosticTarget.any?
    refute_includes response.body, "https://evil.invalid"
  end
  test "metadata injection cannot promote private content through genuine editorial forms" do
    item=draft
    sign_in(self, @author)
    token=csrf_token_for(self, edit_admin_content_path(item))
    patch admin_content_path(item), params: { version: item.lock_version, authenticity_token: token, content: { title: "Owned edit", canonical_url: "https://evil.invalid", robots: "index", published_visibility: "public", status: "published" } }
    assert_response :see_other
    assert_equal "draft", item.reload.status
    get "/blog/#{item.slug}"
    assert_response :not_found
    assert_empty observed_head["schema"]
    refute_includes sitemap_urls, site.canonical_origin+"/blog/#{item.slug}"
  end
end
