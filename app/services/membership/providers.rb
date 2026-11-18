require "json"
require "pathname"
require "mail"
require "timeout"
module Membership
  class Providers
    # Explicit dependency injection for isolated qualification; never selected by
    # a web parameter, Site value, portable import or untrusted environment flag.
    def self.current
      adapter = Rails.application.config.x.membership_provider_adapter
      adapter.is_a?(self) ? adapter : new
    end
    def document
      path = ENV["RAILPRESS_MEMBERSHIP_CONFIG"]
      return {} unless path
      stat = File.lstat(path)
      raise Unavailable unless Pathname.new(path).absolute? && File.realpath(path) == path && stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= 32_768
      value = JSON.parse(File.read(path))
      raise Unavailable unless value.is_a?(Hash) && (value.keys - %w[email discord]).empty?
      value
    rescue SystemCallError, JSON::ParserError, TypeError
      raise Unavailable, "Provider configuration requires operator review", cause: nil
    end
    def status(method, origin:)
      ready?(method, origin: origin) ? "operator_verified" : "unavailable"
    end
    def ready?(method, origin:)
      data = document[method]
      return false unless data.is_a?(Hash) && data["verified"] == true
      if method == "email"
        data["sender"].is_a?(String) && Membership.email(data["sender"]) == data["sender"] &&
          data["host"].is_a?(String) && /\A[a-z0-9.-]{1,253}\z/i.match?(data["host"]) &&
          [ 465, 587 ].include?(data["port"]) && data["username"].is_a?(String) && data["password"].is_a?(String) &&
          data["password"].bytesize.between?(1, 4096)
      elsif method == "discord"
        /\A[1-9][0-9]{5,24}\z/.match?(data["client_id"].to_s) && data["client_secret"].is_a?(String) && data["client_secret"].bytesize.between?(16, 4096) &&
          data["callback"] == Seo::SiteOrigin.new(origin).to_s + "/login/members/discord/callback" && data["pkce_s256_verified"] == true
      else
        false
      end
    rescue Invalid, Unavailable, Seo::SiteOrigin::Invalid
      false
    end
    def discord_settings(origin:)
      raise Unavailable unless ready?("discord", origin: origin)
      document.fetch("discord").slice("client_id", "client_secret", "callback")
    end
    def deliver_email(address:, token:, origin:)
      raise Unavailable unless ready?("email", origin: origin)
      settings = document.fetch("email")
      message = Mail.new
      message.from = settings.fetch("sender")
      message.to = address
      message.subject = "Your website membership verification"
      message.body = "Open this link and confirm to verify your mailbox and continue. Open it in the browser where you requested it. It expires after 15 minutes and works once.\n#{origin}/login/members/verify#verification_token=#{URI.encode_www_form_component(token)}\nManual token (when JavaScript is unavailable): #{token}\nIf you did not request this, ignore it. A verified Member receives no staff privileges.\n"
      message.delivery_method(:smtp, address: settings.fetch("host"), port: settings.fetch("port"), user_name: settings.fetch("username"), password: settings.fetch("password"),
        authentication: :plain, ssl: settings["port"] == 465, enable_starttls: settings["port"] == 587, enable_starttls_auto: false,
        openssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, open_timeout: 2, read_timeout: 2)
      Timeout.timeout(5) { message.deliver! }
      true
    rescue StandardError
      raise Unavailable, "Email delivery is unavailable", cause: nil
    end
    def authorization_url(fields)
      "https://discord.com/oauth2/authorize?" + URI.encode_www_form(fields)
    end
    def elapsed_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def exchange(code:, verifier:, origin:, scopes:)
      deadline = elapsed_now + 5
      Timeout.timeout(5) do
        settings = discord_settings(origin: origin)
        transport = DiscordTransport.new
        token = transport.request("https://discord.com/api/oauth2/token", form: { "grant_type" => "authorization_code", "code" => code, "code_verifier" => verifier,
          "redirect_uri" => settings.fetch("callback"), "client_id" => settings.fetch("client_id"), "client_secret" => settings.fetch("client_secret") })
        raise Invalid unless token["token_type"] == "Bearer" && token["access_token"].is_a?(String) && token["access_token"].bytesize.between?(1, 4096) && !token["access_token"].match?(/[\x00-\x20\x7f]/)
        begin
          raise Invalid unless token["scope"].is_a?(String) && token["scope"].split.sort == scopes.sort
          transport.request("https://discord.com/api/v10/users/@me", bearer: token.fetch("access_token"))
        ensure
          # No access/refresh token persistence or background refresh. Revoke this
          # transient grant; failure is explicit, never a reason to log its payload.
          remaining = deadline - elapsed_now
          raise Unavailable unless remaining.positive?
          # The existing outer timer also governs cleanup. A second timer at
          # the same deadline can deliver a late exception after unwinding.
          transport.request("https://discord.com/api/oauth2/token/revoke", form: { "token" => token.fetch("access_token"), "token_type_hint" => "access_token", "client_id" => settings.fetch("client_id"), "client_secret" => settings.fetch("client_secret") }, empty: true)
          raise Unavailable unless elapsed_now < deadline
        end
      end
    rescue StandardError
      raise Unavailable, "Discord verification is unavailable", cause: nil
    end
  end
end
