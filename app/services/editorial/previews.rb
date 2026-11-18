# frozen_string_literal: true

module Editorial
  module Previews
    module_function
    def issue!(actor:, content:)
      Content.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor.lock!
        content.lock!
        raise Identity::Capabilities::Denied unless Identity::Capabilities.can_edit_content?(actor, author_id: content.author_id)
        token = SecureRandom.hex(32)
        record = content.content_previews.create!(actor: actor, auth_version: actor.auth_version,
          token_digest: Digest::SHA256.hexdigest(token), snapshot: content.snapshot, expires_at: 10.minutes.from_now)
        MediaLibrary::References.sync!(record, "preview", MediaLibrary::References.ids(record.snapshot))
        [ record, token ]
      end
    end
    def resolve!(actor:, id:, token:)
      raise ActiveRecord::RecordNotFound unless token.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(token)
      record = ContentPreview.transaction do
        actor.lock!
        candidate = ContentPreview.lock.find_by(id: id)
        next unless candidate && candidate.actor_id == actor.id && candidate.auth_version == actor.auth_version &&
          OpenSSL.fixed_length_secure_compare(candidate.token_digest, Digest::SHA256.hexdigest(token)) &&
          Identity::Capabilities.can_edit_content?(actor, author_id: candidate.content.reload.author_id) && candidate.deadline_valid_locked?
        candidate
      end
      raise ActiveRecord::RecordNotFound unless record
      record
    end
  end
end
