require "test_helper"
require_relative "../support/portability_test_support"
require_relative "../support/security_clock_test_support"
class PortabilitySecurityTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include PortabilityTestSupport
  include SecurityClockTestSupport
  setup { install_site! }
  def reviewed_batch
    manifest = portable_manifest; session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id); Portability::Imports.inspect!(batch)
    [ batch, session_id, manifest ]
  end
  test "duplicate upload keys require identical bytes and never duplicate batches" do
    session_id = portability_session; manifest = portable_manifest
    bytes = Railpress::SiteArchive.build(manifest, {}); key = SecureRandom.hex(32)
    first = Portability::Imports.submit!(actor: @owner, session_id: session_id, io: StringIO.new(bytes), idempotency_key: key)
    second = Portability::Imports.submit!(actor: @owner, session_id: session_id, io: StringIO.new(bytes), idempotency_key: key)
    assert_equal first.id, second.id
    assert_equal 1, ImportBatch.count
    assert_raises(Portability::Imports::Conflict) { Portability::Imports.submit!(actor: @owner, session_id: session_id, io: StringIO.new(bytes + "changed"), idempotency_key: key) }
    assert_equal 1, ImportBatch.count
  end
  test "a destination edit invalidates dry run and preserved content is never overwritten by retry" do
    batch, session_id, manifest = reviewed_batch
    other = Editorial::Workflow.create!(actor: @owner, kind: "Page", attributes: { "title"=>"Existing unrelated", "slug"=>"unrelated", "body"=>"<p>Keep this body</p>" })
    assert_raises(Portability::Imports::Conflict) { Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest)) }
    assert_equal "<p>Keep this body</p>", other.reload.body
    assert_equal "review", batch.reload.state
    Portability::Imports.inspect!(batch)
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
    Portability::Worker.perform!(batch)
    assert_equal 2, Content.count
    assert_equal "<p>Keep this body</p>", other.reload.body
  end
  test "stored archive tampering and journal mutation block staging before new content" do
    batch, session_id, manifest = reviewed_batch
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
    File.open(Portability::Store.path(batch.public_id), "ab") { |file| file.write("tamper") }
    assert_raises(Portability::Format::Invalid) { Portability::Worker.perform!(batch) }
    assert_equal "blocked", batch.reload.state
    assert_empty Content.all
  end
  test "elapsed expiry survives a backward wall step without issuing fresh authority" do
    with_controlled_security_clock do |_clock, ticks|
      batch, session_id, manifest = reviewed_batch
      Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
      ticks[:value] += UserSession::LIFETIME.to_f + 1
      travel(-1.day) { assert_raises(Portability::Authority::Expired) { Portability::Worker.perform!(batch) } }
      assert_equal "needs_approval", batch.reload.state
      assert_empty Content.all
      assert_equal session_id, batch.approval_session_id
    end
  end
  test "forward expiry latches and a backward return cannot revive the same approved session" do
    with_controlled_security_clock do
      batch, session_id, manifest = reviewed_batch
      Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
      travel(13.hours) { assert_raises(Portability::Authority::Expired) { Portability::Worker.perform!(batch) } }
      assert_raises(Portability::Authority::Expired) { Portability::Imports.renew_approval!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.reload.lock_version) }
      assert_empty Content.all
    end
  end
  test "stale worker failure cannot clear a replacement claim and claims exclude a second import" do
    with_controlled_security_clock do |_clock, ticks|
      batch, session_id, manifest = reviewed_batch
      Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
      old = Portability::Worker.claim!(batch)
      assert old
      assert_nil Portability::Worker.claim!(ImportBatch.find(batch.id))
      ticks[:value] += 61
      replacement = Portability::Worker.claim!(ImportBatch.find(batch.id))
      refute_equal old, replacement
      Portability::Worker.failure!(batch, "blocked", "old failure", token: old)
      assert_equal replacement, batch.reload.lease_token
      assert_equal "staging", batch.state
      Portability::Context.with(batch, old) { assert_raises(Identity::Capabilities::Denied) { Portability::Context.require!(batch) } }
      assert_empty Content.all
    end
  end
  test "storage exhaustion leaves a recoverable receipt with no exposed partial archive or content" do
    bytes = Railpress::SiteArchive.build(portable_manifest, {})
    session_id = portability_session
    key = SecureRandom.hex(32)
    replacing_method(File, :link, ->(*) { raise Errno::ENOSPC, "synthetic storage exhaustion" }) do
      assert_raises(Errno::ENOSPC) { Portability::Imports.submit!(actor: @owner, session_id: session_id, io: StringIO.new(bytes), idempotency_key: key) }
    end
    receipt = ImportBatch.sole
    assert_equal "failed", receipt.state
    assert_equal "receiving", receipt.report["resume_state"]
    assert receipt.report["upload_verified"]
    assert_empty Dir.glob(File.join(Portability::Store.root, "*.railpress"))
    assert_empty Dir.glob(File.join(Portability::Store.root, "*.railpress." + "?" * 32))
    assert_empty Content.all
    resumed = Portability::Imports.submit!(actor: @owner, session_id: session_id, io: StringIO.new(bytes), idempotency_key: key)
    assert_equal receipt.id, resumed.id
    assert_equal "queued", resumed.state
    assert_equal bytes, Portability::Store.read(resumed)
    assert resumed.import_events.where(event: "upload_recovered").exists?
  end
  test "two approved batches cannot mutate concurrently and impossible calendar dates reject" do
    session_id = portability_session
    first = portable_manifest
    second = portable_manifest
    second["content"][0]["working"]["slug"] = "second-portable-page"
    second["content"][0]["live"]["slug"] = "second-portable-page"
    batches = [ first, second ].map do |manifest|
      batch = submit_portable(manifest, session_id: session_id)
      Portability::Imports.inspect!(batch)
      Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
      batch
    end
    assert Portability::Worker.claim!(batches[0])
    assert_raises(Portability::Imports::Conflict) { Portability::Worker.claim!(batches[1]) }
    assert_equal batches[0].id, PortabilityState.sole.active_import_id
    assert_empty Content.all
    assert_raises(Portability::Format::Invalid) { Portability::Format.timestamp!("2021-02-31T00:00:00Z") }
  end
  test "unsafe URLs cycles depth positions rights and cross-menu identities reject in the format boundary" do
    original = portable_manifest
    make_menu = lambda do |rows|
      original.deep_dup.merge("menus"=>[ { "ref"=>SecureRandom.uuid, "name"=>"Synthetic unsafe menu", "draft"=>rows, "live"=>nil, "locations"=>[] } ])
    end
    key = SecureRandom.uuid
    row = { "ref"=>key, "parent_ref"=>nil, "position"=>0, "label"=>"Link", "kind"=>"Custom", "target_ref"=>nil, "url"=>"/safe" }
    [ row.merge("url"=>"javascript:alert(1)"), row.merge("url"=>"//evil.invalid"), row.merge("url"=>"https://user:password@evil.invalid"), row.merge("parent_ref"=>key), row.merge("position"=>3) ].each do |bad|
      assert_raises(Portability::Format::Invalid) { Portability::Format.check!(make_menu.call([ bad ]), {}) }
    end
    invalid = original.deep_dup
    invalid["redirects"] = [ { "path"=>"/portable-page", "content_ref"=>invalid["content"][0]["ref"] } ]
    assert_raises(Portability::Format::Invalid) { Portability::Format.check!(invalid, {}) }
    assert_empty Content.all
  end
  test "already claimed menu identities are actionable before any new records are staged" do
    manifest = portable_manifest
    menu_ref = SecureRandom.uuid
    manifest["menus"] = [ { "ref"=>menu_ref, "name"=>"Claimed menu", "draft"=>[], "live"=>nil, "locations"=>[] } ]
    site = Site.first
    PortabilityIdentity.create!(site: site, kind: "menu", record_key: "999999", public_id: menu_ref)
    session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id)
    Portability::Imports.inspect!(batch)
    assert batch.report["conflicts"].any? { |c| c["kind"] == "menu_identity" && c["resolution"].include?("original request key") }
    error = assert_raises(Portability::Imports::Conflict) { Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest)) }
    assert_match "Menu identity is already claimed", error.message
    assert_empty batch.import_items
    assert_empty Content.all
    assert_equal "review", batch.reload.state
  end
  test "portable blocks cannot claim any destination SQL media identity" do
    manifest = portable_manifest
    [ { "type"=>"image", "media_id"=>1, "caption"=>"Forged claim" }, { "type"=>"gallery", "media_ids"=>[ 1 ], "caption"=>"Forged gallery" }, { "type"=>"hero", "media_id"=>1, "heading"=>"Forged hero", "text"=>"", "label"=>"", "url"=>"" } ].each do |block|
      data = manifest.deep_dup
      data["content"][0]["working"]["blocks"] = [ block ]
      error = assert_raises(Portability::Format::Invalid) { Portability::Format.check!(data, {}) }
      assert_equal "native_media_identity_forbidden", error.message
    end
    assert_empty Content.all
    assert_empty MediaReference.all
  end
end
