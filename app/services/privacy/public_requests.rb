module Privacy
  module PublicRequests
    PUBLIC = {
      "public_contents" => %w[home page post category tag archive search sitemap robots feed not_found],
      "theme_assets" => %w[show media], "media_files" => %w[show], "official_news" => %w[show]
    }.freeze
    module_function
    def prepare!(controller)
      request = controller.request
      return unless (request.get? || request.head?) && PUBLIC.fetch(controller.controller_path, []).include?(controller.action_name)
      site = controller.instance_variable_get(:@site) || Site.find_by(singleton_key: 1)
      return unless site&.privacy_first_anonymous?
      request.set_header("railpress.privacy_public", true)
      # Do not remove essential authenticated state or scoped Owner previews.
      return if controller.send(:current_user) || MemberSession.resolve(controller.session[:member_authentication_token])
      request.session_options[:skip] = true
      request.set_header("railpress.privacy_anonymous", true)
    end
  end
end
