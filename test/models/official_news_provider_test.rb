require "test_helper"
require_relative "../support/official_news_test_support"
class OfficialNewsProviderTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include OfficialNewsTestSupport
  setup { install_site! }
  test "only reviewed current public indexed Post snapshots appear with stable identity and no private body or account data" do
    provider_site
    post=news_post
    assert_empty OfficialNews::Provider.call(site: Site.first)["items"]
    record=review(post)
    first=OfficialNews::Provider.call(site: Site.first)
    assert_equal [ record.public_id ], first["items"].map { |r|r["id"] }
    refute_includes first.to_json, "PRIVATE BODY"
    refute_includes first.to_json, @owner.email
    assert_equal "https://railpress.org/blog/reviewed-public-post", first["items"][0]["url"]
    Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, attributes: { "title"=>"Private working replacement", "body"=>"<p>Secret draft edit.</p>" })
    assert_equal first, OfficialNews::Provider.call(site: Site.first)
    Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, event: "publish")
    assert_empty OfficialNews::Provider.call(site: Site.first)["items"]
    assert_equal record.public_id, review(post).public_id
    Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, event: "unpublish")
    assert_empty OfficialNews::Provider.call(site: Site.first)["items"]
  end
  test "private drafts scheduled Pages and disabled indexing cannot enter provider results" do
    provider_site
    post=news_post
    review(post)
    page=Editorial::Workflow.create!(actor: @owner, kind: "Page", attributes: { "title"=>"No page feed" })
    assert_raises(ActiveRecord::RecordNotFound) { OfficialNews::Provider.review!(actor: @owner, content_id: page.id, expected_version: page.lock_version) }
    Site.first.update!(indexing_enabled: false)
    assert_empty OfficialNews::Provider.call(site: Site.first)["items"]
    assert_raises(OfficialNews::Schema::Invalid) { review(post) }
    Site.first.update!(indexing_enabled: true)
    Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, event: "unpublish")
    assert_raises(OfficialNews::Schema::Invalid) { review(post) }
  end
  test "committed publication does not disappear from metadata under backward host-time observation" do
    provider_site
    post=news_post;review(post)
    expected=OfficialNews::Provider.call(site: Site.first)
    travel_to(Time.current-5.seconds) { assert_equal expected, OfficialNews::Provider.call(site: Site.first) }
  end
  test "provider controls and reviews are Owner-only and stale publication reviews fail" do
    provider_site
    post=news_post
    %w[administrator editor author].each do |role|
      actor=create_account(role)
      assert_raises(Identity::Capabilities::Denied) { OfficialNews::Provider.review!(actor: actor, content_id: post.id, expected_version: post.lock_version) }
      assert_raises(Identity::Capabilities::Denied) { OfficialNews::Controls.call(actor: actor, operation: "enable", version: OfficialNewsState.first.lock_version) }
    end
    assert_raises(Editorial::Workflow::Conflict) { OfficialNews::Provider.review!(actor: @owner, content_id: post.id, expected_version: post.lock_version+1) }
    assert_empty OfficialNewsReview.all
  end
end
