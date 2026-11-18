require "test_helper"
require_relative "../support/administration_test_support"
class AdminExperienceTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  include AdministrationTestSupport
  setup do
    install_site!
    @admin = create_account("administrator")
    @editor = create_account("editor")
    @author = create_account("author")
  end
  test "every visible navigation leaf resolves and GET rendering runs no intrusive probes" do
    with_method(Readiness::Probes, :call, ->(*) { flunk "synchronous probe" }) do
      [ @owner, @admin, @editor, @author ].each do |user|
        sign_in(self, user)
        Administration::Navigation.for(user).flat_map(&:last).each do |entry|
          get Rails.application.routes.url_helpers.public_send(entry.route, **entry.params)
          assert_response :ok, "#{user.role}: #{entry.key}"
          assert_equal "no-store", response.headers["Cache-Control"]
          assert_includes response.headers["X-Robots-Tag"], "noindex"
          assert_select 'nav[aria-label="Administration"]', count: 1
          assert_select 'a[aria-current="page"]', count: 1
          assert_select 'script[src*="admin_shell"]', count: 1
          assert_select "script:not([src])", count: 0
          assert_select "h1", count: 1
        end
      end
    end
    sign_in(self, @owner)
    get new_admin_export_path
    assert_response :ok
    assert_select 'a[aria-current="page"]', text: "Import / Export"
    assert_select 'details.admin-nav-group[open] a[href="/admin/imports"]', count: 1
  end
  test "new protected endpoints check authorization and CSRF through direct HTTP" do
    get admin_readiness_path
    assert_redirected_to login_path
    [ @editor, @author ].each do |user|
      sign_in(self, user)
      %w[/admin/customize /admin/imports /admin/readiness].each { |path| get path; assert_response :forbidden }
      token = csrf_token_for(self, admin_path)
      post admin_readiness_path, params: { authenticity_token: token, findings: [ { state: "HEALTHY" } ] }
      assert_response :forbidden
      delete admin_readiness_run_path(1), params: { authenticity_token: token, version: 0 }
      assert_response :forbidden
    end
    sign_in(self, @admin)
    get admin_readiness_path
    assert_response :ok
    get admin_customize_path
    assert_response :forbidden
    post admin_readiness_path
    assert_response :unprocessable_entity
    token = csrf_token_for(self, admin_readiness_path)
    post admin_readiness_path, params: { authenticity_token: token, findings: [ { state: "HEALTHY" } ], state: "complete" }
    assert_response :see_other
    assert_empty ReadinessRun.last.findings
    assert_equal "pending", ReadinessRun.last.state
    run = ReadinessRun.last
    delete admin_readiness_run_path(run), params: { authenticity_token: token, version: 999 }
    assert_response :conflict
    delete admin_readiness_run_path(run), params: { authenticity_token: token, version: run.lock_version }
    assert_response :see_other
    assert_equal "cancelled", run.reload.state
  end
  test "page post status search filters are scoped and active ancestry is stable" do
    mine = Editorial::Workflow.create!(actor: @author, kind: "Page", attributes: { "title" => "My Unicode café", "slug" => "mine" })
    other = Editorial::Workflow.create!(actor: @owner, kind: "Post", attributes: { "title" => "Private elsewhere", "slug" => "elsewhere" })
    sign_in(self, @author)
    get admin_contents_path(kind: "Page", q: "café", status: "draft")
    assert_response :ok
    assert_select "h1", text: "Pages"
    assert_select 'a[aria-current="page"]', text: "Pages"
    assert_includes response.body, mine.title
    refute_includes response.body, other.title
    get admin_contents_path(kind: "Post")
    refute_includes response.body, mine.title
    refute_includes response.body, other.title
    get edit_admin_content_path(other)
    assert_response :forbidden
    token = csrf_token_for(self, edit_admin_content_path(mine))
    patch admin_content_path(mine), params: { authenticity_token: token, version: mine.lock_version, editorial_action: "reassign", new_author_id: @owner.id }
    assert_response :forbidden
    assert_equal @author.id, mine.reload.author_id
  end
  test "activity route cannot expose owner security and other authors content" do
    item = Editorial::Workflow.create!(actor: @owner, kind: "Page", attributes: { "title" => "Not yours", "slug" => "not-yours" })
    sign_in(self, @author)
    get admin_activity_path
    assert_response :ok
    refute_includes response.body, "identity.user_created"
    refute_includes response.body, "Content ##{item.id}"
    assert_includes response.body, "Security.login"
  end
  test "core administration stays available under theme storage failure" do
    sign_in
    with_method(Themes::Storage, :load, ->(*) { raise Railpress::ThemePackage::Invalid, "broken theme" }) do
      [ admin_path, admin_themes_path, admin_customize_path, admin_readiness_path, admin_contents_path ].each do |path|
        get path
        assert_response :ok
        assert_select "#admin-protected", count: 1
      end
    end
  end
  test "server logout revokes replay and private response binding changes between accounts" do
    sign_in(self, @author)
    get "/admin/session-state"
    assert_response :no_content
    first = response.headers.fetch("X-Railpress-Session-Binding")
    old_token = UserSession.where(user: @author).first.token_digest
    token = csrf_token_for(self, admin_path)
    with_method(ActivityEvent, :create!, ->(**) { raise ActiveRecord::StatementInvalid, "journal offline" }) do
      delete logout_path, params: { authenticity_token: token }
      assert_response :see_other
    end
    refute UserSession.exists?(token_digest: old_token)
    get admin_path
    assert_redirected_to login_path
    sign_in(self, @editor)
    get "/admin/session-state"
    assert_response :no_content
    refute_equal first, response.headers.fetch("X-Railpress-Session-Binding")
    get admin_path
    assert_select "#admin-protected[data-auth-binding]"
    assert_select "form#admin-signout", count: 1
  end
  test "editor controls have unique document IDs with multiple terms and owner transfer" do
    %w[category tag].each { |kind| Editorial::Terms.create!(actor: @owner, kind: kind, name: kind.humanize, slug: kind) }
    sign_in
    %w[Page Post].each do |kind|
      item = Editorial::Workflow.create!(actor: @owner, kind: kind, attributes: { "title" => "#{kind} controls", "slug" => "#{kind.downcase}-controls" })
      get edit_admin_content_path(item)
      assert_response :ok
      doc = Nokogiri::HTML5(response.body)
      ids = doc.css("[id]").map { |node| node["id"] }
      assert_equal ids.uniq, ids
      doc.css("label[for]").each { |label| assert_equal 1, doc.css("[id='#{label['for']}']").size }
      assert_equal 2, doc.css('input[name="content[term_ids][]"][type=checkbox]').size
      assert_select 'a[aria-current="page"]', text: kind.pluralize
    end
  end
end
