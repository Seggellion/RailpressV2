# frozen_string_literal: true

module Identity
  module OperatorRecovery
    class Refused < StandardError; end
    module_function
    def recover!(state:, install_id:, identifier:, password:, confirmation:)
      raise Refused, "Installed private-state identity required" unless state.installed? && state.install_id == install_id
      Site.transaction do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        raise Refused, "Install identity mismatch" unless site.install_id == install_id
        user = Authentication.find_user(identifier)
        user&.lock!
        raise Refused, "Existing owner account required" unless user&.owner?
        Authentication.replace_password!(user, password: password, confirmation: confirmation)
      end
    end

    def reconcile!(state:, install_id:)
      state.reconcile!(install_id) do
        Site.transaction do
          site = Site.find_by!(singleton_key: 1)
          site.lock!
          raise Refused, "Install identity mismatch" unless site.install_id == install_id && User.lock.find(site.owner_id).owner?
        end
      end
    end
  end
end
