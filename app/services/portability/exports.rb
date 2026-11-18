module Portability
  module Exports
    module_function
    def request!(actor:, session_id:, scope:)
      Authority.locked(actor: actor, session_id: session_id) do |site, user, session|
        Format.object!(scope, %w[mode content_ids history author_labels media_rights menus appearance])
        raise Format::Invalid, "invalid_export_scope" unless %w[public owner_private].include?(scope["mode"]) && %w[history menus appearance].all? { |k| [ true, false ].include?(scope[k]) }
        raise Format::Invalid, "invalid_private_selection" unless scope["content_ids"].is_a?(Array) && scope["content_ids"].length <= 500 && scope["content_ids"].all? { |id| id.is_a?(Integer) && id.positive? } && scope["content_ids"].uniq == scope["content_ids"]
        raise Format::Invalid, "unapproved_public_scope" if scope["mode"] == "public" && (scope["content_ids"].any? || scope["history"] || scope["author_labels"].present?)
        raise Format::Invalid, "invalid_author_labels" unless scope["author_labels"].is_a?(Hash) && scope["author_labels"].length <= 500
        scope["author_labels"].each { |id, label| raise Format::Invalid, "invalid_author_choice" unless id.match?(/\A[1-9][0-9]*\z/) && User.where(id: id).exists?; Format.string!(label, 120, empty: false) }
        raise Format::Invalid, "invalid_media_rights" unless scope["media_rights"].is_a?(Hash) && scope["media_rights"].length <= 64
        record = PortabilityExport.create!(site: site, actor: user, approval_session_id: session.id, auth_version: user.auth_version, scope: scope)
        Activity::Recorder.record!(actor: user, action: "portability.export_requested", subject: record, details: { selection: scope["mode"], selected: scope["content_ids"].length, history: scope["history"] })
        record
      end
    end
    def perform!(record)
      Authority.record_locked(record) do |site, _user, _session|
        return record if record.state == "ready"
        raise Format::Invalid, "export_state" unless %w[queued failed].include?(record.state)
        capture = Snapshot.new(site, record.scope)
        manifest = capture.capture
        bytes = Railpress::SiteArchive.build(manifest, capture.payloads)
        # A write that survives a SQL failure is recoverable only if the exact approved bytes match.
        if File.exist?(Store.path(record.public_id))
          existing = File.binread(Store.path(record.public_id))
          raise Format::Invalid, "export_orphan_conflict" unless existing == bytes
          sha, size = Digest::SHA256.hexdigest(bytes), bytes.bytesize
        else
          sha, size = Store.write(record.public_id, StringIO.new(bytes))
        end
        record.update!(state: "ready", archive_sha256: sha, archive_bytes: size, report: { "inventory" => manifest.slice("content", "revisions", "terms", "media", "menus").transform_values(&:length), "omissions" => capture.omissions, "plaintext" => true }, failure: nil)
        record
      end
    rescue Authority::Expired
      record.with_lock { record.update!(state: "blocked", failure: "approval_expired") }
      raise
    end
  end
end
