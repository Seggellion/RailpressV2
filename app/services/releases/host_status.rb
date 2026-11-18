# frozen_string_literal: true

module Releases
  module HostStatus
    OPERATIONS = %w[preflight promote revert].freeze
    module_function
    def read
      path = ENV["RAILPRESS_NATIVE_PUBLIC_STATUS"]
      return nil unless path
      stat = File.lstat(path)
      raise ArgumentError unless stat.file? && !stat.symlink? && (stat.mode & 0o022).zero? && stat.size <= 65_536
      bytes = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        raise ArgumentError unless file.stat.ino == stat.ino && file.stat.dev == stat.dev
        file.read(65_537).to_s
      end
      envelope = Railpress::Releases.parse(bytes, limit: 65_536)
      Railpress::Releases.keys!(envelope, %w[statement signature])
      statement = envelope.fetch("statement")
      trust = Requests.roots
      key = Railpress::Releases.signature!(Railpress::Releases.canonical(statement), envelope["signature"], trust.roots, purpose: "status")
      raise ArgumentError if trust.revoked.include?(key)
      raise ArgumentError unless statement["format"] == "railpress.host-status.v1" &&
        statement["scope"] == "isolated-synthetic-nginx-v1" && statement["production_qualified"] == false &&
        statement["independent_utc_qualified"] == false && statement["deployment_id"] == ENV["RAILPRESS_DEPLOYMENT_ID"] &&
        Railpress::Releases::UUID.match?(statement["deployment_id"].to_s) &&
        statement["capabilities"].is_a?(Array) && (statement["capabilities"] - OPERATIONS).empty? &&
        statement["generation"].is_a?(Integer) && statement["generation"] >= 0 &&
        statement["observed_elapsed"].is_a?(Numeric)
      %w[active_release previous_release].each do |field|
        raise ArgumentError unless statement[field].nil? || Railpress::Releases::SHA.match?(statement[field].to_s)
      end
      age = Railpress::SecurityClock.elapsed - statement["observed_elapsed"]
      fresh = statement["domain"] == Railpress::SecurityClock.boot_domain && age.between?(0, 30)
      { "verified" => true, "fresh" => fresh, "age_seconds" => age, "statement" => statement }
    rescue StandardError
      { "verified" => false, "fresh" => false, "statement" => {} }
    end
    def operations
      observation = read
      observation && observation["verified"] && observation["fresh"] ? observation["statement"]["capabilities"] : []
    end
    def receipt!(statement, request)
      raise ArgumentError, "native receipt identity" unless statement["format"] == "railpress.host-result.v1" &&
        statement["deployment_id"] == ENV["RAILPRESS_DEPLOYMENT_ID"] && Railpress::Releases::UUID.match?(statement["deployment_id"].to_s) &&
        statement["scope"] == "isolated-synthetic-nginx-v1" && OPERATIONS.include?(request.operation) &&
        statement["request_id"] == request.request_key && statement["operation"] == request.operation &&
        statement["release_id"] == request.release_digest && statement["revision"] == request.receipt_revision &&
        Railpress::NativeHost::PHASES.include?(statement["state"]) && statement["generation"].is_a?(Integer)
      statement
    end
  end
end
