ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
  parallelize(workers: 1)
end

ActiveRecord::Migration.check_pending_migrations

require_relative "support/schema_integrity"
TestSchemaIntegrity.guard!

class ActiveSupport::TestCase
  setup { TestSchemaIntegrity.guard! }
  teardown { TestSchemaIntegrity.guard! }
end

require_relative "support/identity_test_support"
ActiveModel::SecurePassword.min_cost = true
