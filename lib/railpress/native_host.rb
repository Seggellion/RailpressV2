# frozen_string_literal: true

require_relative "releases"
require_relative "test_database"
require_relative "bootstrap_state"
require "open3"
require "rbconfig"
require "socket"
require "net/http"
require "timeout"

module Railpress
  # Only the explicitly configured, disposable native profile is executable.
  # Real host adapters require separate provisioning and qualification.
  module NativeHost
    F = Releases::Filesystem
    Error = Releases::Invalid
    OPERATIONS = %w[initialize preflight promote revert backup restore].freeze
    PHASES = %w[PREFLIGHT STAGED SCHEMA_EXPANDED WARMED READY SWITCHING VERIFYING ACTIVE FAILED_STAGED REVERT_ELIGIBILITY_CHECK PREVIOUS_ACTIVE RESTORE_REQUIRED BACKING_UP BACKED_UP RESTORING RESTORED].freeze
    module_function
    def uuid!(value)
      raise Error, "operation_identity" unless Releases::UUID.match?(value.to_s)
      value
    end
    def load_document(path, maximum: 1_048_576)
      Releases.parse(F.read(path, maximum: maximum), limit: maximum)
    end
    def sign(statement, key)
      { "statement" => statement, "signature" => { "algorithm" => "ed25519", "key_id" => Releases.key_id(key),
        "signature" => Base64.strict_encode64(key.sign(nil, Releases.canonical(statement))) } }
    end
  end
end
require_relative "native_host/config"
require_relative "native_host/state"
require_relative "native_host/commands"
require_relative "native_host/processes"
require_relative "native_host/probe"
require_relative "native_host/proxy"
require_relative "native_host/database"
require_relative "native_host/restore_journal"
require_relative "native_host/mysql_restore"
require_relative "native_host/database_integrity"
require_relative "native_host/schema"
require_relative "native_host/snapshot"
require_relative "native_host/plan"
require_relative "native_host/authorization"
require_relative "native_host/runtime"
require_relative "native_host/host"
require_relative "native_host/lifecycle"
require_relative "native_host/recovery"
Railpress::NativeHost::Host.include(Railpress::NativeHost::Lifecycle)
Railpress::NativeHost::Host.include(Railpress::NativeHost::Recovery)
require_relative "native_host/supervisor"
require_relative "native_host/cli"
require_relative "native_host/module_repair"
require_relative "native_host/module_operation"
