require_relative "boot"

require "rails"
require_relative "../lib/railpress/upload_body_limit"
require_relative "../lib/railpress/theme_upload_limit"
require_relative "../lib/railpress/image_input"
require_relative "../lib/railpress/anonymous_privacy"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

require_relative "../lib/railpress/extensions"
Railpress::Extensions.boot!(app_root: File.expand_path("..", __dir__), environment: Rails.env)

module Railpress
  class Application < Rails::Application
    config.middleware.insert_before 0, Railpress::ThemeUploadLimit
    config.middleware.insert_before ActionDispatch::Executor, Railpress::UploadBodyLimit
    config.middleware.insert_before ActionDispatch::ShowExceptions, Railpress::AnonymousPrivacy
    # M04 will introduce authenticated validated media routes; framework uploads stay closed.
    config.active_storage.draw_routes = false
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1
    config.logger = ActiveSupport::Logger.new($stdout) if ENV["RAILPRESS_READ_ONLY_DOCTOR"] == "1"

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
