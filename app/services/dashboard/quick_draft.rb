module Dashboard
  module QuickDraft
    module_function
    def call(actor:, request_key:, expected_version:, kind:, title:, body:)
      raise Editorial::Workflow::Invalid, "Use text fields and choose Page or Post." unless kind.is_a?(String) && title.is_a?(String) && (body.nil? || body.is_a?(String))
      raise Editorial::Workflow::Invalid, "Use a fresh Quick Draft form." unless request_key.to_s.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/) && expected_version.to_s == "0"
      attributes = { "title" => title.to_s, "body" => body.to_s, "visibility" => "private" }
      digest = Digest::SHA256.hexdigest(JSON.generate([ kind, attributes ]))
      Site.transaction do
        site = Site.lock.find_by!(singleton_key: 1)
        fresh = User.lock.find(actor.id)
        Identity::Capabilities.require!(fresh, :edit_own)
        raise Identity::Capabilities::Denied unless fresh.auth_version == actor.auth_version
        receipt = DashboardDraftSubmission.find_by(site: site, request_key: request_key)
        if receipt
          raise Editorial::Workflow::Conflict, "This submission was already used. Reload the dashboard to start another draft." unless receipt.actor_id == fresh.id && receipt.request_digest == digest
          return receipt.content
        end
        raise Editorial::Workflow::Invalid, "Review existing drafts before creating more." if DashboardDraftSubmission.where(actor: fresh).count >= 1000
        content = Editorial::Workflow.create!(actor: fresh, kind: kind, attributes: attributes.merge("slug" => "draft-#{request_key}"))
        DashboardDraftSubmission.create!(site: site, actor: fresh, content: content, request_key: request_key, request_digest: digest)
        content
      end
    end
  end
end
