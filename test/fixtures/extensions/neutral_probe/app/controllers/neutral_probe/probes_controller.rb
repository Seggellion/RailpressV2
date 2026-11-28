module NeutralProbe
  class ProbesController < ::ApplicationController
    def show
      render plain: "Neutral probe"
    end

    def presentation
      model = Railpress::ThemeRenderer::PublicProfileV1.new(title: "Neutral entry", summary: "Public display fields",
        url: "/extensions/neutral-probe/presentation")
      html = Themes::Presentation.render(site: Site.find_by!(singleton_key: 1), module_id: "neutral-probe",
        name: "public_profile", payload: model, actor: current_user, authentication_token: session[:authentication_token],
        credential: session[:theme_preview])
      render html: (html || "<p>Neutral module presentation</p>").html_safe, layout: "core"
    end
  end
end
