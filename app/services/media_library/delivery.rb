module MediaLibrary
  module Delivery
    module_function
    def read(asset, variant)
      Configuration.guard!
      return nil unless asset.state == "ready" && %w[display thumb].include?(variant)
      blob = variant == "thumb" ? asset.thumbnail_blob : asset.blob
      return nil unless blob
      bytes = "".b
      blob.download do |chunk|
        return nil if bytes.bytesize + chunk.bytesize > Processor::OUTPUT_BYTES
        bytes << chunk
      end
      expected = variant == "thumb" ? asset.thumbnail_sha256 : asset.sha256
      return nil unless bytes.bytesize <= Processor::OUTPUT_BYTES && Digest::SHA256.hexdigest(bytes) == expected && bytes.start_with?("\x89PNG\r\n\x1a\n".b)
      bytes
    rescue ActiveStorage::FileNotFoundError, Errno::ENOENT, Railpress::Gcs::Failure, Configuration::Handoff
      nil
    end
    def exists?(asset)
      Configuration.guard!
      asset&.state == "ready" && asset.blob && asset.blob.service.exist?(asset.blob.key)
    rescue Configuration::Handoff
      false
    end
  end
end
