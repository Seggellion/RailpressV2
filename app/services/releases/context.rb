module Releases
  module Context
    module_function
    def current
      connection = ActiveRecord::Base.connection
      adapter = connection.adapter_name
      engine = adapter == "PostgreSQL" ? "postgresql" : (adapter == "Mysql2" ? "mysql2" : nil)
      raise Railpress::Releases::Invalid, "database_engine" unless engine
      version = connection.select_value(engine == "postgresql" ? "SHOW server_version" : "SELECT VERSION()").to_s[/\A\d+\.\d+(?:\.\d+)?/]
      themes = ThemeInstallation.where(status: "validated").order(:id).limit(33).to_a
      raise Railpress::Releases::Invalid, "theme_inventory" if themes.length > 32
      themes.each { |theme| Themes::Storage.load(theme) }
      { "ruby" => RUBY_VERSION, "rails" => Rails.version, "database_engine" => engine, "database_version" => version,
        "native_profile" => Railpress::Product::NATIVE_PROFILE,
        "themes" => themes.map { |theme| { "id" => theme.theme_key, "version" => theme.version, "digest" => theme.digest } } }
    end
  end
end
