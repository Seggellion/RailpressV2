# Host configuration is captured once per process, never rewritten by setup.
require Rails.root.join("lib/railpress/media_configuration")
Rails.application.config.x.railpress_media_environment = ENV.to_h.slice(
  "RAILPRESS_STORAGE_BACKEND", "RAILPRESS_STORAGE_ROOT", "RAILPRESS_QUARANTINE_ROOT",
  "RAILPRESS_GCS_PROJECT", "RAILPRESS_GCS_BUCKET", "RAILPRESS_GCS_PREFIX", "RAILPRESS_GCS_AUTH_METHOD",
  "RAILPRESS_GCS_ADC_SOURCE", "RAILPRESS_GCS_CREDENTIALS_FILE", "GOOGLE_APPLICATION_CREDENTIALS",
  "HOME", "RAILPRESS_STORAGE_CONFIG_EPOCH"
).merge("RAILPRESS_UNSUPPORTED_GOOGLE_INLINE" => (Railpress::MediaConfiguration.inline_credentials?(ENV) ? "1" : "0")).freeze
