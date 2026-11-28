# frozen_string_literal: true

# Shared by reviewed, opted-in engines. Render within the same site lock used
# by Member closure and engine activation, so a revocation has one ordering.
class ExtensionFormsController < ApplicationController
  layout "core"
  around_action :with_extension_site

  private

  attr_reader :extension_site

  def with_extension_site
    Membership.locked do |site|
      id = request.env["railpress.extension.id"]
      unless id && Extensions::Activation.enabled?(id)
        head :not_found
        next
      end
      @extension_site = site
      yield
    end
  end

  def verified_extension_member
    MemberSession.resolve(session[:member_authentication_token])&.member
  end
end
