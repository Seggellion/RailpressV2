require "active_storage/service/railpress_gcs_service"
require_relative "media_test_support"
require_relative "gcs_api_fixture"

module GcsTestSupport
  extend ActiveSupport::Concern
  include MediaTestSupport
  included do
    setup do
      @api = GcsApiFixture.new
      @service = ActiveStorage::Service::RailpressGcsService.new(bucket: "synthetic-bucket", project: "synthetic-project")
      @service.name = :gcs
      @service.instance_variable_set(:@store, Railpress::Gcs::Store.new(bucket: "synthetic-bucket", project: "synthetic-project", client: @api))
      @previous_service = ActiveStorage::Blob.service
      @previous_registered = ActiveStorage::Blob.services.instance_variable_get(:@services)[:gcs]
      ActiveStorage::Blob.services.instance_variable_get(:@services)[:gcs] = @service
      ActiveStorage::Blob.service = @service
      @old_quarantine = ENV["RAILPRESS_QUARANTINE_ROOT"]
      ENV["RAILPRESS_QUARANTINE_ROOT"] = File.join(@private_root, "quarantine")
    end
    teardown do
      # SQL-only cleanup before restoring the shared fixture service registry.
      reset_identity_data
      ActiveStorage::Blob.service = @previous_service
      registry = ActiveStorage::Blob.services.instance_variable_get(:@services)
      @previous_registered ? registry[:gcs] = @previous_registered : registry.delete(:gcs)
      ENV["RAILPRESS_QUARANTINE_ROOT"] = @old_quarantine
    end
  end
end
