require "test_helper"
require_relative "../support/editorial_test_support"

class EditorialWorkflowTest < ActiveSupport::TestCase
  include EditorialTestSupport
  test "Page and Post rich UTF-8 content is sanitized and attribution remains original" do
    %w[Page Post].each do |kind|
      content = draft(kind, body: '<h2>日本語</h2><p onclick="x()">Café <strong>bold</strong></p><script>alert(1)</script><a href="javascript:alert(1)">bad</a><iframe src="https://bad.invalid"></iframe>')
      assert_equal @author.id, content.author_id
      assert_includes content.body, "日本語"
      refute_match(/<script|onclick|javascript:|iframe/, content.body)
      change(content, attributes: { title: "Edited", author_id: @editor.id })
      assert_equal @author.id, content.reload.author_id
      assert_equal "Edited", content.title
    end
  end
  test "authors submit own work but cannot publish schedule restore or edit others" do
    content = draft
    change(content, "submit", actor: @author)
    assert_equal "pending", content.status
    %w[publish schedule restore_revision].each do |event|
      assert_raises(Identity::Capabilities::Denied) { change(content, event, actor: @author) }
    end
    other = draft(actor: @editor, slug: "other")
    assert_raises(Identity::Capabilities::Denied) { change(other, actor: @author, attributes: { title: "stolen" }) }
    assert_equal "Café publishing 日本語", other.reload.title
  end
  test "case accent namespace and reserved slug collisions use native constraints" do
    draft("Page", slug: "Café")
    assert_raises(ActiveRecord::RecordNotUnique) { draft("Page", slug: "CAFE") }
    assert draft("Post", slug: "café").persisted?
    Railpress::ContentRoutes::RESERVED.each do |slug|
      assert_raises(ActiveRecord::RecordInvalid) { draft("Page", slug: slug) }
    end
    assert_raises(ActiveRecord::RecordInvalid) { draft("Page", template_key: "../../secrets") }
  end
  test "saving published changes keeps live body metadata and taxonomy isolated" do
    first = term
    second = term("tag", "Rails")
    content = draft(term_ids: [ first.id ], meta_title: "Live title")
    change(content, "publish")
    live = content.published_snapshot.deep_dup
    change(content, actor: @author, attributes: { body: "<p>Working copy</p>", meta_title: "Unreviewed", visibility: "private", term_ids: [ second.id ] })
    assert_equal live, content.reload.published_snapshot
    assert_equal "public", content.published_visibility
    assert_equal [ first.id ], content.content_terms.where(stage: "live").pluck(:term_id)
    assert_equal [ second.id ], content.draft_terms.pluck(:id)
    change(content, "submit", actor: @author)
    assert content.pending_review?
    assert_equal "published", content.status
    change(content, "publish")
    assert_equal "private", content.published_visibility
    assert_equal "<p>Working copy</p>", content.published_snapshot["body"]
    assert_equal [ second.id ], content.content_terms.where(stage: "live").pluck(:term_id)
  end
  test "live slug cannot change until unpublished" do
    content = draft
    change(content, "publish")
    assert_raises(ActiveRecord::RecordInvalid) { change(content, attributes: { slug: "different" }) }
    content.reload
    change(content, "unpublish")
    change(content, attributes: { slug: "different" })
    assert_equal "different", content.slug
    assert_nil content.published_snapshot
  end
  test "revision restore appends immutable history and never publishes or changes author" do
    content = draft
    original = content.content_revisions.first
    change(content, attributes: { body: "<p>New body</p>", title: "Changed" })
    change(content, "publish")
    count = content.content_revisions.count
    change(content, "restore_revision", revision: original.id)
    assert_equal count + 1, content.content_revisions.count
    assert_equal "draft", content.status
    assert_nil content.published_snapshot
    assert_equal original.snapshot["body"], content.body
    assert_equal @author.id, content.author_id
    assert_raises(ActiveRecord::RecordNotSaved) { original.update!(event: "tampered") }
    assert_raises(ActiveRecord::RecordNotDestroyed) { original.destroy! }
    assert_equal "create", original.reload.event
  end
  test "trash restore preserves history and future timestamp alone never publishes" do
    content = draft
    content.update_columns(published_at: 1.day.from_now)
    refute Content.publicly_visible.exists?(content.id), "A timestamp alone cannot publish a draft"
    change(content.reload, "publish")
    content.update_columns(published_at: 1.day.from_now)
    assert Content.publicly_visible.exists?(content.id), "Committed publication survives wall time behind its historical metadata"
    content.reload
    change(content, "trash")
    assert_equal "trashed", content.status
    refute Content.publicly_visible.exists?(content.id)
    change(content, "restore")
    assert_equal "draft", content.status
    assert_equal 4, content.content_revisions.count
  end
  test "taxonomy normalization and native foreign keys reject collisions and unknown terms" do
    category = term("category", "Café")
    assert_equal "cafe", category.slug
    assert_raises(ActiveRecord::RecordNotUnique) { term("category", "CAFE") }
    assert term("tag", "café").persisted?
    assert_raises(Identity::Capabilities::Denied) { Editorial::Terms.create!(actor: @author, kind: "tag", name: "X", slug: "x") }
    assert_raises(Editorial::Workflow::Invalid) { draft(term_ids: [ 999999 ]) }
    assert_equal 0, Content.count
  end
  test "featured media and system fields cannot be mass assigned" do
    content = draft(author_id: @editor.id, status: "published", published_at: Time.current, featured_blob_id: 123, type: "Page")
    assert_equal "Post", content.type
    assert_equal @author.id, content.author_id
    assert_equal "draft", content.status
    assert_nil content.featured_blob_id
  end
  test "content attribution prevents deleting its author" do
    draft
    assert_raises(ActiveRecord::RecordNotDestroyed) { Identity::ManageUsers.remove!(actor: @owner, user: @author) }
    assert User.exists?(@author.id)
  end
  test "DST missing ambiguous and invalid dates are rejected while UTC conversion is exact" do
    %w[2026-03-08T02:30 2026-11-01T01:30 2026-02-30T12:00].each do |value|
      assert_raises(Editorial::LocalTime::Invalid) { Editorial::LocalTime.parse(value, "America/New_York") }
    end
    assert_equal Time.utc(2026, 7, 1, 16, 0), Editorial::LocalTime.parse("2026-07-01T12:00", "America/New_York")
    assert_equal Time.utc(2026, 12, 1, 17, 0), Editorial::LocalTime.parse("2026-12-01T12:00", "America/New_York")
  end
  test "optimistic version is required even when only taxonomy changes" do
    content = draft
    version = content.lock_version
    change(content, attributes: { term_ids: [ term.id ] })
    assert_operator content.lock_version, :>, version
    assert_raises(Editorial::Workflow::Conflict) { change(content, version: version, attributes: { title: "stale" }) }
  end

  test "invalid updates roll back taxonomy revision and public state together" do
    old = term
    item = draft(term_ids: [ old.id ])
    change(item, "publish")
    version = item.lock_version
    count = item.content_revisions.count
    live = item.published_snapshot.deep_dup
    assert_raises(ActiveRecord::RecordInvalid) do
      change(item, "publish", attributes: { title: "", term_ids: [] })
    end
    item.reload
    assert_equal version, item.lock_version
    assert_equal count, item.content_revisions.count
    assert_equal [ old.id ], item.draft_terms.pluck(:id)
    assert_equal live, item.published_snapshot
  end

  test "removing a preview-only account revokes ephemeral snapshots without deleting content" do
    item = draft
    preview, _token = Editorial::Previews.issue!(actor: @editor, content: item)
    Identity::ManageUsers.remove!(actor: @owner, user: @editor)
    refute User.exists?(@editor.id)
    refute ContentPreview.exists?(preview.id)
    assert_equal 1, Content.count
    assert_equal @author.id, item.reload.author_id
  end
end
