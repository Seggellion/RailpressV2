require "test_helper"
require_relative "../support/media_test_support"
class MediaConcurrencyTest < ActiveSupport::TestCase
  include MediaTestSupport
  test "concurrent selection and purge cannot leave a dangling media reference" do
    asset=upload_media
    result=parallel_results(2) do |index|
      if index.zero?
        draft(actor: User.find(@author.id), blocks: [ { "type"=>"image", "media_id"=>asset.id } ])
        :selected
      else
        MediaLibrary::Manage.purge!(actor: User.find(@editor.id), asset: MediaAsset.find(asset.id))
        :purged
      end
    rescue MediaLibrary::Manage::InUse
      :retained
    rescue ActiveRecord::RecordNotFound
      :unavailable
    end
    if result.include?(:selected)
      assert_equal [ :retained, :selected ], result.sort
      assert_equal "ready", asset.reload.state
      assert MediaLibrary::Delivery.read(asset, "display")
    else
      assert_equal [ :purged, :unavailable ], result.sort
      assert_equal 0, MediaReference.count
      assert_equal "purged", asset.reload.state
    end
  end
  test "concurrent media metadata edits detect optimistic conflicts" do
    asset=upload_media
    version=asset.lock_version
    result=parallel_results(2) do |index|
      MediaLibrary::Manage.update!(actor: User.find(@author.id), asset: MediaAsset.find(asset.id), attributes: { "alt_text"=>"Choice #{index}" }, version: version)
      :saved
    rescue MediaLibrary::Manage::Conflict
      :conflict
    end
    assert_equal [ :conflict, :saved ], result.sort
    assert_equal 1, asset.reload.lock_version
  end
  test "stale native snapshot cannot export after owner demotion" do
    second=create_account("owner", "second-owner")
    ready=Queue.new;proceed=Queue.new
    thread=Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Site.transaction do
          User.find(@owner.id);ready<<true;proceed.pop
          Portability::Export.call(actor: @owner, include_private: true)
          :exported
        end
      end
    rescue Identity::Capabilities::Denied
      :denied
    end
    ready.pop
    Identity::ManageUsers.change_role!(actor: second, user: @owner, role: "author")
    proceed<<true
    assert thread.join(20)
    assert_equal :denied, thread.value
  ensure
    thread&.kill if thread&.alive?
  end
  test "media constraints and direct model mutation cannot change canonical type or authority" do
    asset=upload_media
    assert_raises(ActiveRecord::RecordNotSaved) { asset.update!(author: @owner) }
    assert_raises(ActiveRecord::StatementInvalid) { asset.update_column(:content_type, "text/html") }
    assert_equal "image/png", asset.reload.content_type
    assert_equal @author.id, asset.author_id
  end
end
