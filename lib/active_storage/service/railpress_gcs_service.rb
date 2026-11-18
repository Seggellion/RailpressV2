# frozen_string_literal: true

require "active_storage/service"
require_relative "../../railpress/gcs"

class ActiveStorage::Service::RailpressGcsService < ActiveStorage::Service
  attr_reader :store
  def initialize(bucket:, project:, credentials: nil, prefix: "", auth_method: "adc", identity_source: "automatic", **)
    @store = Railpress::Gcs::Store.new(bucket: bucket, project: project, credentials: credentials, prefix: prefix, auth_method: auth_method, identity_source: identity_source)
  end
  def public? = false
  def retain_objects? = true
  def upload(key, io, checksum: nil, content_type: "image/png", **)
    store.upload(key, io, checksum: checksum, content_type: content_type)
  end
  def download(key)
    blob = ActiveStorage::Blob.find_by!(key: key, service_name: name)
    expected = blob.metadata["railpress_gcs"]
    raise Railpress::Gcs::Failure, "UNSUPPORTED" unless expected
    bytes, = store.read(key, expected: expected)
    block_given? ? yield(bytes) : bytes
  end
  def exist?(key)
    download(key)
    true
  rescue Railpress::Gcs::Failure, ActiveRecord::RecordNotFound
    false
  end
  def delete(_key) = raise(Railpress::Gcs::Failure, "UNSUPPORTED")
  def delete_prefixed(_prefix) = raise(Railpress::Gcs::Failure, "UNSUPPORTED")
  def url(*) = raise(Railpress::Gcs::Failure, "UNSUPPORTED")
  def url_for_direct_upload(*) = raise(Railpress::Gcs::Failure, "UNSUPPORTED")
  def headers_for_direct_upload(*) = raise(Railpress::Gcs::Failure, "UNSUPPORTED")
end
