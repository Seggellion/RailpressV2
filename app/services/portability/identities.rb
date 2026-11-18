module Portability
  module Identities
    module_function
    # Call only within the site write lock; no content identity is a login identity.
    def reference(site, kind, key)
      PortabilityIdentity.find_or_create_by!(site: site, kind: kind, record_key: key.to_s).public_id
    end
    def bind!(site, kind, key, ref)
      record = PortabilityIdentity.find_by(public_id: ref)
      if record
        raise Railpress::SiteArchive::Invalid, "identity_already_claimed" unless record.site_id == site.id && record.kind == kind && record.record_key == key.to_s
      else
        PortabilityIdentity.create!(site: site, kind: kind, record_key: key.to_s, public_id: ref)
      end
    end
  end
end
