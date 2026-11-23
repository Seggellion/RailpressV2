# frozen_string_literal: true

require_relative "../releases"
require "stringio"
module Railpress
  module Releases
    module Builder
      module_function
      # Caller supplies reviewed source bytes and a synthetic signer in qualification.
      # Production signing/custody and distribution are separate owner gates.
      def build(files:, metadata:, compatibility:, signer:, dusk: nil)
        files = DuskOffer.bind(files, compatibility, metadata, **dusk) if dusk
        raise Invalid, "builder_files" unless files.is_a?(Hash) && files.length.between?(1, 4096)
        inventory = {}
        tar = StringIO.new("".b)
        files.sort.each do |name, source|
          Releases.path!(name)
          Releases.keys!(source, %w[bytes mode])
          data = source.fetch("bytes")
          raise Invalid, "builder_size" unless data.is_a?(String) && data.bytesize <= 8 * 1024 * 1024
          mode = source.fetch("mode")
          inventory[name] = { "bytes" => data.bytesize, "sha256" => Digest::SHA256.hexdigest(data), "mode" => mode }
          prefix = ""
          leaf = name
          if leaf.bytesize > 100
            split = name.rindex("/")
            raise Invalid, "builder_path" unless split
            prefix, leaf = name[0...split], name[(split + 1)..]
            raise Invalid, "builder_path" if prefix.bytesize > 155 || leaf.bytesize > 100
          end
          header = Gem::Package::TarHeader.new(name: leaf, prefix: prefix, mode: mode, size: data.bytesize,
            mtime: 0, uid: 0, gid: 0, typeflag: "0", linkname: "", uname: "", gname: "", devmajor: 0, devminor: 0)
          raise Invalid, "builder_expanded_limit" if tar.pos + 512 + data.bytesize + ((512 - data.bytesize % 512) % 512) + 1024 > Manifest::MAX_EXPANDED
          tar.write(header.to_s)
          tar.write(data)
          tar.write("\0" * ((512 - data.bytesize % 512) % 512))
        end
        tar.write("\0" * 1024)
        raise Invalid, "builder_expanded_limit" if tar.string.bytesize > Manifest::MAX_EXPANDED
        compressed = StringIO.new("".b)
        gzip = Zlib::GzipWriter.new(compressed, Zlib::BEST_COMPRESSION)
        gzip.mtime = 0
        gzip.write(tar.string)
        gzip.close
        package = compressed.string
        manifest = metadata.merge("format" => "railpress.release.v1", "files" => inventory, "compatibility" => compatibility,
          "package" => { "bytes" => package.bytesize, "sha256" => Digest::SHA256.hexdigest(package) })
        Manifest.validate!(manifest)
        signature = { "algorithm" => "ed25519", "key_id" => Releases.key_id(signer),
          "signature" => Base64.strict_encode64(signer.sign(nil, Releases.canonical(manifest))) }
        artifact = { "release_id" => Digest::SHA256.hexdigest(Releases.canonical(manifest)), "manifest" => manifest,
          "signature" => signature, "package" => package }
        artifact[DuskOffer::ASSET_NAME] = files.fetch(DuskOffer::INVENTORY_PATH).fetch("bytes") if dusk
        artifact
      end
    end
  end
end
