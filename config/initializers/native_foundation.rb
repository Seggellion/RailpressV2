# frozen_string_literal: true

Rails.application.config.active_job.queue_adapter = Rails.env.test? ? :test : :solid_queue
Rails.application.config.solid_queue.connects_to = { database: { writing: :primary } }
Rails.application.config.active_storage.variant_processor = :vips
Rails.application.config.cache_store = :memory_store, { namespace: "railpress/#{Rails.env}/#{ENV.fetch('RAILPRESS_TEST_ENGINE', 'local')}" }
# Mail is deliberately a local sink until recovery/delivery qualifies in M02/M10.
Rails.application.config.action_mailer.delivery_method = Rails.env.test? ? :test : :file
Rails.application.config.action_mailer.file_settings = { location: Rails.root.join(".local", "state", "mail", Rails.env) }
