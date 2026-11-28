# frozen_string_literal: true

module Themes
  module Publishers
    FORMAT = "railpress.theme-upload-publishers.v1"
    PURPOSE = "theme-package.v1"
    INVALID = Railpress::ThemePackage::Invalid
    module_function

    def verify!(bundle)
      key = bundle.signature.fetch("key_id")
      trust = Railpress::ThemePackage.parse(
        Railpress::Releases::Filesystem.read(File.join(Storage.root, "upload-publishers.json"), maximum: 65_536)
      )
      Railpress::ThemePackage.keys!(trust, %w[format publishers revoked])
      keys = trust["publishers"]
      revoked = trust["revoked"]
      unless trust["format"] == FORMAT && keys.is_a?(Hash) && keys.size.between?(1, 32) &&
          revoked.is_a?(Array) && revoked.size <= 128 && revoked.all? { |id| Railpress::Releases::SHA.match?(id.to_s) }
        raise INVALID, "upload_publisher_policy"
      end
      record = keys[key]
      raise INVALID, "upload_publisher_untrusted" unless record && !revoked.include?(key)
      Railpress::ThemePackage.keys!(record, %w[purpose packages provenance_sha256])
      allowlist = record["packages"]
      provenance = record["provenance_sha256"]
      identity = bundle.manifest.fetch("id")
      unless record["purpose"] == PURPOSE && identity != "dusk" && allowlist.is_a?(Array) && allowlist.size.between?(1, 32) &&
          allowlist.include?(identity) && provenance.is_a?(Array) && provenance.size.between?(1, 32) &&
          provenance.include?(Digest::SHA256.hexdigest(bundle.manifest.fetch("provenance")))
        raise INVALID, "upload_publisher_scope"
      end
      key
    rescue Railpress::Releases::Invalid
      raise INVALID, "upload_publisher_policy", cause: nil
    end
  end
end
