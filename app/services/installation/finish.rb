# frozen_string_literal: true

module Installation
  module Finish
    module_function
    def call(state:, claim:, revision:)
      progress = Progress.new(state)
      state.complete!(claim) do
        value = progress.read
        progress.verify!(value, claim: claim, revision: revision)
        raise Progress::Invalid, "Review every step before activation." unless value["step"] == "review" && value["completed"] == Progress::STEPS[0...-1]
        raise Progress::Invalid, "Database configuration changed. Return to the database step." unless value["configuration"] == Configuration.fingerprint
        data = value.fetch("data")
        MediaLibrary::Configuration.assert_applied!(data.fetch("storage"))
        existing = Site.find_by(singleton_key: 1)
        if existing
          # Only a previously committed, fully completed attempt may repair its private seal.
          raise Setup::Complete::Conflict, "Existing site requires operator reconciliation." unless value["status"] == "committing" && existing.install_id == value["attempt_id"] && existing.owner.username == data.dig("owner", "username") && ThemeState.find_by(site: existing)&.active_installation&.theme_key == "dusk" && Menu.where(site: existing).where.not(published_revision_id: nil).exists?
          existing.install_id
        else
          raise Progress::Invalid, "Required environment changed. Recheck the environment." unless Environment.required_ready?(Environment.call)
          DatabaseProbe.call
          raise Schema::Refused, "Recheck the explicit schema handoff." unless Schema.ready?(state)
          value["status"] = "committing"
          progress.save(value)
          Site.transaction do
            raise Setup::Complete::Conflict, "Accounts or site already exist." if Site.exists? || User.exists?
            Schema.ensure_empty!(ActiveRecord::Base.connection)
            owner = User.create!(data.fetch("owner").slice("username", "email", "password_digest").merge("role" => "owner"))
            membership = Membership::Policy.validate!(data.fetch("membership"), origin: data.fetch("identity").fetch("canonical_origin"))
            site = Site.create!(data.fetch("identity").merge(membership).merge("owner" => owner, "singleton_key" => 1, "install_id" => value.fetch("attempt_id")))
            MediaLibrary::Configuration.install!(data.fetch("storage"))
            Starter.call(owner: owner, site: site, choices: data.fetch("appearance"))
            site.install_id
          end
        end
      end
      # SQL commit and durable seal have succeeded. Remove the temporary owner verifier.
      value = progress.read
      value["data"].delete("owner")
      value.delete("claim_binding")
      value["status"] = "installed"
      progress.save(value)
      Site.find_by!(install_id: state.install_id).owner
    rescue Membership::Invalid, Membership::Unavailable
      raise Progress::Invalid, "Provider readiness changed. Return to Membership and Verification or leave registration disabled.", cause: nil
    rescue Navigation::Mutation::Invalid, Navigation::Mutation::Conflict
      raise Progress::Invalid, "Starter navigation visibility could not be verified. No website was installed. Reload to review and retry; ask the operator to inspect timing and database observations if it recurs.", cause: nil
    end
  end
end
