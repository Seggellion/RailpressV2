# frozen_string_literal: true

require "digest"
require "stringio"
require_relative "media_configuration"

module Railpress
  module Gcs
    MAX_BYTES = 12 * 1024 * 1024
    class Failure < StandardError
      attr_reader :status
      def initialize(status)
        @status = status
        super("gcs_#{status.downcase}")
      end
    end
    class Buffer < StringIO
      def write(bytes)
        raise Failure, "MISMATCH" if size + bytes.bytesize > MAX_BYTES
        super
      end
    end
    # No bucket creation, policy changes, deletion or URL signing. Lazy client.
    class Store
      attr_reader :bucket_name, :project, :prefix, :auth_method, :identity_source
      def initialize(bucket:, project:, credentials: nil, client: nil, prefix: "", auth_method: nil, identity_source: "automatic")
        raise Failure, "UNSUPPORTED" unless bucket.to_s.match?(/\A[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]\z/) && project.to_s.match?(/\A[a-z][a-z0-9-]{4,61}[a-z0-9]\z/)
        @prefix = Railpress::MediaConfiguration.prefix!(prefix)
        @auth_method = auth_method || (credentials ? "service_account_file" : "adc")
        raise Failure, "UNSUPPORTED" unless %w[adc service_account_file].include?(@auth_method)
        @identity_source = @auth_method == "adc" ? identity_source : "native"
        raise Failure, "UNSUPPORTED" unless Railpress::MediaConfiguration::SOURCES.include?(@identity_source)
        @bucket_name, @project, @credentials, @client = bucket, project, credentials, client
      end
      def client
        @client ||= begin
          require "google/cloud/storage"
          raise Failure, "UNSUPPORTED" if %w[STORAGE_EMULATOR_HOST GCS_EMULATOR_HOST].any? { |key| ENV[key] }
          identity = Railpress::MediaConfiguration.credentials(method: auth_method, file: @credentials, identity_source: identity_source)
          Google::Cloud::Storage.new(project_id: project, credentials: identity, retries: 0,
            timeout: 10, open_timeout: 3, read_timeout: 5, send_timeout: 5)
        end
      end
      def bucket = client.bucket(bucket_name, skip_lookup: true)
      def private_bucket!
        current = client.bucket(bucket_name, skip_lookup: false)
        raise Failure, "MISSING" unless current
        raise Failure, "UNSUPPORTED" unless current.uniform_bucket_level_access? && current.public_access_prevention_enforced?
        current
      end
      def guard
        yield
      rescue Failure
        raise
      rescue StandardError => error
        status = case error.class.name.split("::").last
        when "NotFoundError" then "MISSING"
        when "PermissionDeniedError", "UnauthenticatedError", "Invalid" then "INACCESSIBLE"
        when "FailedPreconditionError", "PreconditionFailedError", "AlreadyExistsError", "FileVerificationError" then "MISMATCH"
        else "UNKNOWN"
        end
        raise Failure.new(status), cause: nil
      end
      def key!(key)
        raise Failure, "UNSUPPORTED" unless key.is_a?(String) && key.match?(/\A[0-9a-f]{64}\z/)
        key
      end
      def object_name(key) = prefix.empty? ? key!(key) : prefix + "/" + key!(key)
      def info(file)
        raise Failure, "MISSING" unless file
        generation = file.generation.to_s
        size = Integer(file.size)
        raise Failure, "MISMATCH" unless generation.match?(/\A[1-9][0-9]{0,19}\z/) && size.between?(1, MAX_BYTES)
        { "bucket" => bucket_name, "project" => project, "generation" => generation, "byte_size" => size }.tap { |binding| binding["prefix"] = prefix unless prefix.empty? }
      end
      def upload(key, io, checksum: nil, content_type: "image/png")
        key!(key)
        raise Failure, "UNSUPPORTED" unless content_type == "image/png"
        io.rewind
        sha = Digest::SHA256.new
        count = 0
        while (part = io.read(16_384)) && !part.empty?
          count += part.bytesize
          raise Failure, "MISMATCH" if count > MAX_BYTES
          sha.update(part)
        end
        io.rewind
        guard do
          object = private_bucket!.create_file(io, object_name(key), if_generation_match: 0, content_type: "image/png",
            cache_control: "private, no-store", md5: checksum, checksum: :crc32c)
          binding = info(object).merge("key" => key, "sha256" => sha.hexdigest)
          raise Failure, "MISMATCH" unless binding["byte_size"] == count
          binding
        end
      end
      def read(key, expected: nil)
        key!(key)
        guard do
          # A noncurrent or soft-deleted version cannot qualify a missing live key.
          object = private_bucket!.file(object_name(key))
          binding = info(object).merge("key" => key)
          raise Failure, "MISMATCH" if expected && (!expected.is_a?(Hash) || expected.except("sha256") != binding)
          # SDK downloads the fetched generation, preventing lookup/read races.
          sink = Buffer.new("".b)
          object.download(sink, verify: :crc32c, skip_decompress: true)
          bytes = sink.string
          raise Failure, "MISMATCH" unless bytes.bytesize == binding["byte_size"]
          sha = Digest::SHA256.hexdigest(bytes)
          raise Failure, "MISMATCH" if expected && expected["sha256"] != sha
          [ bytes, binding.merge("sha256" => sha) ]
        end
      end
      def verify(expected)
        read(expected.fetch("key"), expected: expected)
        "VERIFIED"
      rescue Failure => error
        error.status
      rescue KeyError, TypeError
        "UNSUPPORTED"
      end
      def policy_status = { "versioning" => "UNKNOWN", "soft_delete" => "UNKNOWN", "lifecycle" => "UNKNOWN", "iam" => "UNKNOWN" }
    end
  end
end
