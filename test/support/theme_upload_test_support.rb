# frozen_string_literal: true

require "zlib"

module ThemeZipFixture
  module_function

  def write(path, files, compress: false, descriptor: false, comment: "")
    central = +"".b
    File.open(path, "wb", 0o600) do |output|
      files.each do |name, content|
        offset = output.pos
        bytes = content.b
        packed = compress ? deflate(bytes) : bytes
        flags = descriptor ? 8 : 0
        method = compress ? 8 : 0
        crc = Zlib.crc32(bytes)
        sizes = [ crc, packed.bytesize, bytes.bytesize ]
        local = [ 0x04034b50, 20, flags, method, 0, 0, *(descriptor ? [ 0, 0, 0 ] : sizes), name.bytesize, 0 ]
        output.write(local.pack("VvvvvvVVVvv"), name, packed)
        output.write([ 0x08074b50, *sizes ].pack("VVVV")) if descriptor
        external = (name.end_with?("/") ? 0o040755 : 0o100644) << 16
        fields = [ 0x02014b50, 0x0314, 20, flags, method, 0, 0, *sizes, name.bytesize, 0, 0, 0, 0, external, offset ]
        central << fields.pack("VvvvvvvVVVvvvvvVV") << name
      end
      central_start = output.pos
      output.write(central, [ 0x06054b50, 0, 0, files.length, files.length, central.bytesize, central_start, comment.bytesize ].pack("VvvvvVVv"), comment)
    end
    path
  end

  def deflate(bytes)
    compressor = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
    compressor.deflate(bytes, Zlib::FINISH)
  ensure
    compressor&.close
  end

  def package_files(directory)
    Dir.glob("**/*", base: directory).filter_map do |path|
      source = File.join(directory, path)
      [ path, File.binread(source) ] if File.file?(source)
    end
  end
end

module ThemeUploadTestSupport
  PROVENANCE = "Original Railpress M06 templates and CSS; no UltimaCraft or third-party assets."

  def configure_zip_publisher(scope: [ "harbor" ], purpose: Themes::Publishers::PURPOSE, revoked: [])
    File.write(File.join(Themes::Storage.root, "upload-publishers.json"), JSON.generate({
      "format" => Themes::Publishers::FORMAT, "revoked" => revoked,
      "publishers" => { @keys.keys.first => { "purpose" => purpose, "packages" => scope,
        "provenance_sha256" => [ Digest::SHA256.hexdigest(PROVENANCE) ] } }
    }), perm: 0o600)
  end

  def theme_zip(version: "1.0.0", schema: 1, required: false, mutate: nil)
    directory = package_directory(version: version, mutate: lambda do |manifest, files|
      if schema == 2
        manifest["schema_version"] = 2
        manifest["compatibility"]["core"] = { "min" => Railpress::Product::VERSION, "max_exclusive" => "3.0.0" }
        manifest["extension_presentation_api"] = 1
        manifest["requires"] = { "neutral-probe.probe" => { "min" => "1.0.0", "max_exclusive" => "2.0.0" } } if required
        path = "templates/slots/public_profile.html.erb"
        manifest["slots"] = { "public_profile" => path }
        FileUtils.mkdir_p(File.dirname(File.join(files, path)))
        Railpress::ThemeFixture.replace(manifest, files, path,
          '<article class="qualified-slot"><h1><%= presenter.title %></h1><p><%= presenter.summary %></p><a href="<%= presenter.url %>">Details</a></article>')
      end
      mutate&.call(manifest, files)
    end)
    path = File.join(@private_root, "transport-#{SecureRandom.hex(4)}.zip")
    ThemeZipFixture.write(path, ThemeZipFixture.package_files(directory), compress: schema == 2, descriptor: schema == 2)
  end
end
