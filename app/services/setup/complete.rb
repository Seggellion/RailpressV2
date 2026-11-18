# frozen_string_literal: true

module Setup
  class Complete
    class Conflict < StandardError; end
    def self.call(state:, claim:, site_attributes:, owner_attributes:)
      state.complete!(claim) do
        begin
          Site.transaction do
            existing = Site.find_by(singleton_key: 1)
            raise Railpress::BootstrapState::ExistingInstall, existing.install_id if existing
            raise Conflict, "Database contains accounts without a site; operator review required" if User.exists?
            owner = User.create!(owner_attributes.slice(:username, :email, :password, :password_confirmation).merge(role: "owner"))
            site = Site.create!(site_attributes.slice(:title, :tagline, :canonical_origin, :locale, :timezone, :indexing_enabled, :home_mode).
              merge(singleton_key: 1, install_id: SecureRandom.uuid, owner: owner))
            site.install_id
          end
        rescue ActiveRecord::RecordNotUnique
          existing = Site.find_by(singleton_key: 1)
          raise Railpress::BootstrapState::ExistingInstall, existing.install_id if existing
          raise
        end
      end
    end
  end
end
