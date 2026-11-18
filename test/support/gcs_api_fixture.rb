# frozen_string_literal: true

require "google/cloud/storage"

# Actual pinned SDK Bucket/File classes over an in-memory JSON-API service double.
# This is NOT a live GCS provider qualification. No HTTP or credentials are used.
class GcsApiFixture
  attr_reader :objects, :calls
  attr_accessor :failure, :download_override, :private_access
  def initialize
    @objects, @calls = {}, []
    @private_access = true
  end
  def bucket(name, skip_lookup:)
    raise failure if failure
    calls << [ "bucket", name, skip_lookup ]
    response = { "name" => name, "iamConfiguration" => { "uniformBucketLevelAccess" => { "enabled" => private_access }, "publicAccessPrevention" => private_access ? "enforced" : "inherited" } }
    Google::Cloud::Storage::Bucket.from_gapi(Google::Apis::StorageV1::Bucket.from_json(JSON.generate(response)), self)
  end
  def insert_file(bucket, io, key, **options)
    raise failure if failure
    calls << [ "insert", bucket, key, options ]
    raise Google::Cloud::FailedPreconditionError, "synthetic 412" if objects.key?(key) || options[:if_generation_match] != 0
    bytes = io.read
    object = Google::Apis::StorageV1::Object.new(bucket: bucket, name: key, generation: (objects.length + 1000).to_s,
      size: bytes.bytesize, content_type: options[:content_type], crc32c: Base64.strict_encode64(Digest::CRC32c.digest(bytes)), md5_hash: Base64.strict_encode64(Digest::MD5.digest(bytes)))
    objects[key] = [ object, bytes ]
    object
  end
  def get_file(bucket, key, **options)
    raise failure if failure
    calls << [ "get", bucket, key, options ]
    raise Google::Cloud::NotFoundError, "synthetic 404" unless objects[key]
    objects[key].first.dup
  end
  def download_file(bucket, key, sink, **options)
    raise failure if failure
    calls << [ "download", bucket, key, options ]
    object, bytes = objects.fetch(key)
    raise Google::Cloud::FailedPreconditionError, "synthetic generation mismatch" unless options[:generation].to_s == object.generation.to_s
    sink.write(download_override || bytes)
    sink.rewind
    [ sink, Struct.new(:header).new({}) ]
  end
  def fingerprint
    Digest::SHA256.hexdigest(JSON.generate(objects.sort.to_h.transform_values { |object, bytes| [ object.generation.to_s, Digest::SHA256.hexdigest(bytes), bytes.bytesize ] }))
  end
end
