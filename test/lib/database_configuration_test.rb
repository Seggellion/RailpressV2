require "test_helper"
require_relative "../../config/database_configuration"
require "tempfile"

class DatabaseConfigurationTest < ActiveSupport::TestCase
  def with_configuration(values)
    keys = %w[DATABASE_URL RAILPRESS_DB_ADAPTER RAILPRESS_DB_HOST RAILPRESS_DB_PORT RAILPRESS_DB_NAME RAILPRESS_DB_USER RAILPRESS_DB_PASSWORD RAILPRESS_DB_SSL_CA]
    saved = keys.to_h { |key| [ key, ENV[key] ] }
    keys.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  test "unconfigured boot targets an inert nondefault port" do
    with_configuration({}) do
      config = Railpress::DatabaseConfiguration.build("production")
      assert_equal "railpress_unconfigured", config.fetch("database")
      assert_equal 65432, config.fetch("port")
    end
  end

  test "unsupported adapters and inherited URLs refuse" do
    with_configuration("RAILPRESS_DB_ADAPTER" => "sqlite3") do
      assert_raises(ArgumentError) { Railpress::DatabaseConfiguration.build("production") }
    end
    with_configuration("DATABASE_URL" => "postgresql://synthetic:private-value@invalid/db") do
      error = assert_raises(ArgumentError) { Railpress::DatabaseConfiguration.build("production") }
      refute_includes error.message, "private-value"
    end
  end

  test "remote connection configuration requires explicit CA before network use" do
    with_configuration("RAILPRESS_DB_HOST" => "db.example.invalid", "RAILPRESS_DB_NAME" => "synthetic") do
      assert_raises(ArgumentError) { Railpress::DatabaseConfiguration.build("production") }
    end
  end

  test "both remote adapters enforce hostname verification" do
    Tempfile.create("public-ca-fixture") do |file|
      %w[postgresql mysql2].each do |adapter|
        with_configuration("RAILPRESS_DB_ADAPTER" => adapter, "RAILPRESS_DB_HOST" => "db.example.invalid", "RAILPRESS_DB_NAME" => "synthetic", "RAILPRESS_DB_SSL_CA" => file.path) do
          config = Railpress::DatabaseConfiguration.build("production")
          if adapter == "postgresql"
            assert_equal "verify-full", config.fetch("sslmode")
            assert_equal file.path, config.fetch("sslrootcert")
          else
            assert_equal "verify_identity", config.fetch("ssl_mode")
            assert_equal file.path, config.fetch("sslca")
          end
        end
      end
    end
  end
end
