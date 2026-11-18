require "test_helper"

class AdminCreationRecoveryTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport

  setup do
    install_site!
    @editor = create_account("editor")
    sign_in(self, @editor)
  end

  %w[Page Post].each do |kind|
    test "#{kind} creation retains its type after validation failure and accepts a corrected submission" do
      token = csrf_token_for(self, new_admin_content_path(kind: kind))
      post admin_contents_path, params: { authenticity_token: token, kind: kind, content: { title: "Recovery Café 日本語", slug: "admin" } }
      assert_response :unprocessable_entity
      assert_select '[role="alert"]', text: /No changes were saved/
      assert_select 'input[name="kind"]' do |fields|
        assert_equal kind, fields.first["value"]
      end
      assert_select "h1", text: "New #{kind.downcase}"
      assert_equal 0, Content.count
      token = Nokogiri::HTML5(response.body).at_css('meta[name="csrf-token"]')["content"]
      assert_difference -> { Content.count }, 1 do
        post admin_contents_path, params: { authenticity_token: token, kind: kind, content: { title: "Recovery Café 日本語", slug: "recovered-#{kind.downcase}", body: "<p>Corrected draft.</p>" } }
      end
      assert_response :see_other
      item = Content.last
      assert_equal kind, item.type
      assert_equal @editor.id, item.author_id
      assert_equal "draft", item.status
      assert_nil item.published_at
      follow_redirect!
      assert_response :ok
      assert_select "h1", text: "Edit #{kind.downcase}"
      assert_select '[role="status"]', text: /Draft created/
    end
  end
end
