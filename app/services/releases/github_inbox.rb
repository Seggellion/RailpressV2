# frozen_string_literal: true

module Releases
  # Called by an explicitly provisioned operator, never a controller or render.
  module GithubInbox
    module_function
    def import!(release_id:, root:, source: GithubSource.new)
      Railpress::Releases.identity!(release_id)
      Railpress::Releases::Filesystem.directory!(root, private: true)
      item = Catalog.verified_items.find { |candidate| candidate["release_id"] == release_id }
      raise Railpress::Releases::Invalid, "verified_release_required" unless item
      manifest = item.fetch("manifest")
      Railpress::Releases::Filesystem.capacity!(root, manifest["package"]["bytes"] * 2)
      package_url = "https://github.com/#{GithubSource::REPOSITORY}/releases/download/v#{manifest['version']}/package.tar.gz"
      raise Railpress::Releases::Invalid, "release_package_url" unless item["package_url"] == package_url
      package = source.get(package_url, limit: Railpress::Releases::Manifest::MAX_PACKAGE)
      raise Railpress::Releases::Invalid, "package_digest" unless package.bytesize == manifest["package"]["bytes"] && Digest::SHA256.hexdigest(package) == manifest["package"]["sha256"]
      plan_url = "https://github.com/#{GithubSource::REPOSITORY}/releases/download/v#{manifest['version']}/native-plan.json"
      raise Railpress::Releases::Invalid, "native_plan_url" unless item["plan_url"] == plan_url
      plan = Railpress::Releases.parse(source.get(plan_url, limit: 65_536), limit: 65_536)
      Railpress::Releases.keys!(plan, %w[statement signature])
      raise Railpress::Releases::Invalid, "native_plan_identity" unless plan.dig("statement", "release_id") == release_id
      trust = Requests.roots; security = Catalog.payload("trust")
      trust.apply!(security)
      trust.verify!(Railpress::Releases.canonical(plan["statement"]), plan["signature"], security, purpose: "release")
      directory = File.join(root, "inbox", release_id)
      Dir.mkdir(directory, 0o700) unless File.exist?(directory)
      Railpress::Releases::Filesystem.directory!(directory, private: true)
      { "manifest.json" => Railpress::Releases.canonical(manifest), "signature.json" => Railpress::Releases.canonical(item["signature"]),
        "native-plan.json" => Railpress::Releases.canonical(plan), "package.tar.gz" => package }.each do |name, bytes|
        path = File.join(directory, name)
        if File.exist?(path) || File.symlink?(path)
          raise Railpress::Releases::Invalid, "inbox_collision" unless Railpress::Releases::Filesystem.read(path, maximum: bytes.bytesize) == bytes
        else
          Railpress::Releases::Filesystem.atomic(path, bytes)
        end
      end
      { "state" => "INBOX VERIFIED", "release_id" => release_id, "staged" => false, "activated" => false }
    end
  end
end
