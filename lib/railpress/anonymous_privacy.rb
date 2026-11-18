module Railpress
  # Outside exception rendering and Cookies: inspect the final response after
  # session commit. No database work or uninstalled-boot query in middleware.
  class AnonymousPrivacy
    def initialize(app) = @app = app
    def call(env)
      status, headers, body = @app.call(env)
      if env["railpress.privacy_public"]
        headers = headers.dup
        csp_key = headers.keys.find { |key| key.downcase == "content-security-policy" }
        directives = headers.delete(csp_key).to_s.split(";").filter_map do |entry|
          key, value = entry.strip.split(/\s+/, 2)
          [ key, value ] if key && !key.empty?
        end.to_h
        directives.merge!("connect-src" => "'none'", "frame-src" => "'none'", "object-src" => "'none'", "img-src" => "'self'", "font-src" => "'self'", "media-src" => "'self'", "form-action" => "'self'")
        headers["content-security-policy"] = directives.map { |key, value| [ key, value ].compact.join(" ") }.join("; ")
        headers.delete_if { |key, _| key.downcase == "referrer-policy" || (env["railpress.privacy_anonymous"] && key.downcase == "set-cookie") }
        headers["referrer-policy"] = "no-referrer"
      end
      [ status, headers, body ]
    end
  end
end
