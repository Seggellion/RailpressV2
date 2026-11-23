# frozen_string_literal: true

require "json"
require "openssl"
require "base64"
require "digest"
require "securerandom"
require "time"
require "fileutils"
require "tempfile"
require "tmpdir"
require "rubygems"
require "zlib"
require "rubygems/package"
require_relative "product"
require_relative "security_clock"
require_relative "theme_package"

module Railpress
  module Releases
    class Invalid < StandardError; end
    SHA = /\A[0-9a-f]{64}\z/
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*)?\z/
    module_function
    def canonical(value)
      case value
      when Hash then JSON.generate(value.keys.sort.to_h { |key| [ key, JSON.parse(canonical(value.fetch(key))) ] })
      when Array then JSON.generate(value.map { |item| JSON.parse(canonical(item)) })
      else JSON.generate(value)
      end
    end
    class UniqueHash < Hash
      def []=(key, value)
        raise Invalid, "duplicate_json_key" if key?(key)
        super
      end
    end
    def parse(bytes, limit: 1_048_576)
      raise Invalid, "metadata_limit" unless bytes.is_a?(String) && bytes.bytesize.between?(2, limit) && bytes.dup.force_encoding("UTF-8").valid_encoding?
      JSON.parse(JSON.generate(JSON.parse(bytes, max_nesting: 16, object_class: UniqueHash)), max_nesting: 16)
    rescue JSON::ParserError
      raise Invalid, "malformed_metadata"
    end
    def keys!(object, expected)
      raise Invalid, "metadata_fields" unless object.is_a?(Hash) && object.keys.sort == expected.sort
    end
    def integer!(value, min, max)
      raise Invalid, "integer_range" unless value.is_a?(Integer) && value.between?(min, max)
    end
    def text!(value, maximum)
      raise Invalid, "text_limit" unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, maximum) && !value.match?(/[\x00-\x08\x0b-\x1f\x7f]/)
    end
    def identity!(value)
      raise Invalid, "release_identity" unless value.is_a?(String) && SHA.match?(value)
      value
    end
    def path!(value)
      raise Invalid, "archive_path" unless value.is_a?(String) && value.bytesize.between?(1, 180) && value.ascii_only? &&
        value.match?(/\A[a-zA-Z0-9_.-]+(?:\/[a-zA-Z0-9_.-]+)*\z/) &&
        value.split("/").none? { |part| part == "." || part == ".." || (part.start_with?(".") && part != ".manifest.json" && value != ".ruby-version") || part.match?(/\A(?:con|prn|aux|nul|com\d|lpt\d)(?:\.|\z)/i) } &&
        !value.match?(/(?:\A|\/)(?:credentials|master\.key|storage|log|tmp|node_modules|vendor\/bundle)(?:\/|\z)/i) &&
        !value.match?(/\.(?:pem|key|sql|dump|sqlite3)\z/i) &&
        (%w[app bin config db lib themes public scripts schemas docs].include?(value.split("/").first) || %w[Gemfile Gemfile.lock LICENSE THIRD_PARTY_NOTICES.md Rakefile config.ru .ruby-version].include?(value))
      value
    end
    def public_key(pem)
      raise Invalid, "key_algorithm" unless pem.is_a?(String) && pem.bytesize <= 512 &&
        pem.match?(/\A-----BEGIN PUBLIC KEY-----\n[A-Za-z0-9+\/=\n]+-----END PUBLIC KEY-----\n?\z/)
      key = OpenSSL::PKey.read(pem)
      raise Invalid, "key_algorithm" unless key.oid == "ED25519"
      key
    rescue OpenSSL::PKey::PKeyError
      raise Invalid, "key_algorithm"
    end
    def compare_versions(left, right)
      a = SEMVER.match(left.to_s)
      b = SEMVER.match(right.to_s)
      raise Invalid, "product_semver" unless a && b
      result = a.captures.first(3).map(&:to_i) <=> b.captures.first(3).map(&:to_i)
      return result unless result.zero?
      x, y = a[4]&.split("."), b[4]&.split(".")
      return 0 if x.nil? && y.nil?
      return x.nil? ? 1 : -1 if x.nil? || y.nil?
      [ x.length, y.length ].max.times do |index|
        return -1 unless x[index]
        return 1 unless y[index]
        l, r = x[index], y[index]
        next if l == r
        numeric_l, numeric_r = l.match?(/\A\d+\z/), r.match?(/\A\d+\z/)
        return numeric_l ? -1 : 1 if numeric_l != numeric_r
        return numeric_l ? l.to_i <=> r.to_i : l <=> r
      end
      0
    end
    def key_id(key) = Digest::SHA256.hexdigest(key.public_to_der)
    def signature!(bytes, envelope, roots, purpose:)
      keys!(envelope, %w[algorithm key_id signature])
      raise Invalid, "signature_algorithm" unless envelope["algorithm"] == "ed25519"
      identity!(envelope["key_id"])
      row = roots.fetch(envelope["key_id"]) { raise Invalid, "unknown_publisher" }
      raise Invalid, "key_purpose" unless row.fetch("purpose") == purpose
      key = public_key(row.fetch("public_key"))
      raise Invalid, "key_identity" unless key_id(key) == envelope["key_id"]
      sig = Base64.strict_decode64(envelope.fetch("signature"))
      raise Invalid, "invalid_signature" unless sig.bytesize == 64 && key.verify(nil, sig, bytes)
      envelope["key_id"]
    rescue OpenSSL::PKey::PKeyError, ArgumentError, KeyError, TypeError
      raise Invalid, "invalid_signature"
    end
  end
end
require_relative "releases/filesystem"
require_relative "releases/manifest"
require_relative "releases/dusk_offer"
require_relative "releases/replay_state"
require_relative "releases/journal"
require_relative "releases/authority"
require_relative "releases/bundle"
require_relative "releases/operator"
