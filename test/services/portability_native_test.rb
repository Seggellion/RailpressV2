require "test_helper"
require_relative "../support/portability_test_support"
class PortabilityNativeTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include PortabilityTestSupport
  setup { install_site! }
  test "private staging separate activation and guarded reversal" do
    manifest = portable_manifest
    batch, session_id = stage_portable(manifest)
    assert_equal "staged", batch.state
    content = Content.find(batch.import_items.find_by!(kind: "content").target_id)
    assert_equal "private", content.visibility
    assert_equal "draft", content.status
    assert_nil content.scheduled_at
    assert_equal 0, Content.publicly_visible.count
    assert_equal manifest["content"][0]["working"]["body"], content.body
    Portability::Activation.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, content_refs: [ manifest["content"][0]["ref"] ], menus: false, settings: false, appearance: false)
    Portability::Worker.perform!(batch)
    assert_equal "complete", batch.reload.state
    assert_equal 1, Content.publicly_visible.count
    assert_equal "private", content.reload.visibility
    assert_equal "public", content.published_snapshot["visibility"]
    Portability::Reversal.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version)
    Portability::Worker.perform!(batch)
    assert_equal "reversed", batch.reload.state
    assert_empty Content.all
    assert_equal "complete", batch.report["object_cleanup"]
  end
  test "source homepage flags cannot bypass destination settings approval" do
    existing = Editorial::Workflow.create!(actor: @owner, kind: "Page", attributes: { "title"=>"Destination home", "slug"=>"destination-home", "home_page"=>true })
    Editorial::Workflow.update!(actor: @owner, content: existing, expected_version: existing.lock_version, event: "publish")
    assert_equal existing.id, Site.first.homepage_content_id
    manifest = portable_manifest
    record = manifest["content"][0]
    record["working"]["home_page"] = record["live"]["home_page"] = true
    manifest["site"]["homepage_ref"] = record["ref"]
    batch, session_id = stage_portable(manifest)
    assert_equal existing.id, Site.first.homepage_content_id
    Portability::Activation.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, content_refs: [ record["ref"] ], menus: false, settings: false, appearance: false)
    Portability::Worker.perform!(batch)
    assert_equal "complete", batch.reload.state
    imported = Content.find(batch.import_items.find_by!(kind: "content").target_id)
    assert_equal existing.id, Site.first.homepage_content_id
    refute imported.home_page
    refute imported.published_snapshot["home_page"]
    assert batch.manifest["content"][0]["live"]["home_page"], "source homepage history remains intact"
  end
  test "reversed batch cleanup requires explicit fresh Owner approval after session revocation" do
    batch, session_id = stage_portable(portable_manifest)
    Portability::Reversal.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version)
    Portability::Worker.perform!(batch)
    assert_equal "reversed", batch.reload.state
    UserSession.where(id: session_id).delete_all
    assert_raises(Portability::Authority::Expired) { Portability::Reversal.cleanup!(batch) }
    fresh_session = portability_session
    Portability::Reversal.request_cleanup!(batch: batch, actor: @owner, session_id: fresh_session, expected_version: batch.reload.lock_version)
    assert_equal fresh_session, batch.reload.approval_session_id
    assert_equal "complete", batch.report["object_cleanup"]
    assert batch.import_events.where(event: "cleanup_approved").exists?
    assert_raises(Editorial::Workflow::Conflict) { Portability::Reversal.request_cleanup!(batch: batch, actor: @owner, session_id: fresh_session, expected_version: batch.lock_version - 1) }
  end
  test "private source cannot activate and later edits block reversal" do
    manifest = portable_manifest
    manifest["content"][0]["history"]["state"] = "scheduled"
    manifest["content"][0]["history"]["scheduled_at"] = "2030-01-01T00:00:00Z"
    batch, session_id = stage_portable(manifest)
    assert_raises(Portability::Format::Invalid) { Portability::Activation.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, content_refs: [ manifest["content"][0]["ref"] ], menus: false, settings: false, appearance: false) }
    content = Content.find(batch.import_items.find_by!(kind: "content").target_id)
    Editorial::Workflow.update!(actor: @owner, content: content, expected_version: content.lock_version, attributes: { "body"=>"<p>A legitimate later edit</p>" })
    assert_raises(Portability::Imports::Conflict) { Portability::Reversal.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.reload.lock_version) }
    assert_match "legitimate", content.reload.body
  end
  test "public export excludes private drafts working edits history and login identities" do
    content = Editorial::Workflow.create!(actor: @owner, kind: "Post", attributes: { "title"=>"Live news", "body"=>"<p>Approved live body</p>" })
    Editorial::Workflow.update!(actor: @owner, content: content, expected_version: content.lock_version, event: "publish")
    Editorial::Workflow.update!(actor: @owner, content: content, expected_version: content.lock_version, attributes: { "body"=>"<p>PRIVATE WORKING CANARY</p>" })
    Editorial::Workflow.create!(actor: @owner, kind: "Post", attributes: { "title"=>"PRIVATE DRAFT CANARY" })
    record = Portability::Exports.request!(actor: @owner, session_id: portability_session, scope: { "mode"=>"public", "content_ids"=>[], "history"=>false, "author_labels"=>{}, "media_rights"=>{}, "menus"=>true, "appearance"=>false })
    Portability::Exports.perform!(record)
    bytes = Portability::Store.read(record)
    manifest, payloads = Railpress::SiteArchive.read(bytes)
    assert_equal manifest, Portability::Format.check!(manifest, payloads)
    assert_equal 1, manifest["content"].length
    assert_empty manifest["authors"]
    assert_empty manifest["revisions"]
    [ "PRIVATE WORKING CANARY", "PRIVATE DRAFT CANARY", @owner.email, @owner.password_digest, Site.first.install_id ].each { |value| refute_includes bytes, value }
  end
  test "malicious or incompatible records fail before writing" do
    original = portable_manifest
    [ ->(m) { m["version"] = 999 }, ->(m) { m["site"]["signing_key"] = "secret" }, ->(m) { m["content"][0]["working"]["body"] = "<script>alert(1)</script>" }, ->(m) { m["content"][0]["working"]["term_refs"] = [ SecureRandom.uuid ] }, ->(m) { m["content"][0]["working"]["blocks"] = [ { "type"=>"executable" } ] } ].each do |mutation|
      manifest = original.deep_dup; mutation.call(manifest)
      assert_raises(Portability::Format::Invalid) { Portability::Format.check!(manifest, {}) }
    end
    assert_empty Content.all
  end
  test "revoked approval stops staging and approvals reject stale versions" do
    manifest = portable_manifest; session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id)
    Portability::Imports.inspect!(batch)
    assert_raises(Editorial::Workflow::Conflict) { Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version + 1, decisions: portable_decisions(manifest)) }
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
    UserSession.where(id: session_id).delete_all
    assert_raises(Portability::Authority::Expired) { Portability::Worker.perform!(batch) }
    assert_equal "needs_approval", batch.reload.state
    assert_empty Content.all
  end
end
