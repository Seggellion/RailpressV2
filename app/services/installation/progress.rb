# frozen_string_literal: true

require "json"
require "tempfile"

module Installation
  class Progress
    class Invalid < StandardError; end
    class Conflict < StandardError; end
    STEPS = %w[environment database storage identity owner appearance membership review].freeze

    def initialize(state)
      @state = state
      @path = File.join(state.root, "installation.json")
    end

    def read
      return { "version" => 1, "revision" => 0, "step" => "environment", "completed" => [], "data" => {} } unless File.exist?(@path) || File.symlink?(@path)
      stat = File.lstat(@path)
      raise Invalid, "Private installation progress is unsafe" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= 65_536
      value = JSON.parse(File.binread(@path))
      raise Invalid, "Private installation progress is invalid" unless value.is_a?(Hash) && value["version"] == 1 && value["revision"].is_a?(Integer) && STEPS.include?(value["step"]) && value["completed"].is_a?(Array) && (value["completed"] - STEPS).empty? && value["data"].is_a?(Hash)
      if (value["completed"].include?("identity") || value["step"] == "identity") && !value["completed"].include?("storage")
        value["completed"] = value["completed"].take_while { |step| %w[environment database].include?(step) }
        value["step"] = "storage" if value["completed"].include?("database")
      end
      value
    rescue JSON::ParserError
      raise Invalid, "Private installation progress is invalid"
    end

    def start!(claim)
      @state.with_claim!(claim) do
        value = read
        value["data"].delete("owner")
        value["completed"] = []
        value["step"] = "environment"
        value["attempt_id"] ||= SecureRandom.uuid
        value["claim_binding"] = Digest::SHA256.hexdigest(claim)
        save(value)
      end
    end

    def update!(claim:, revision:)
      @state.with_claim!(claim) do
        value = read
        verify!(value, claim: claim, revision: revision)
        yield value
        save(value)
      end
    end

    def verify!(value, claim:, revision:)
      raise Conflict, "Setup changed in another tab. Reload and review your choices." unless revision.to_s == value["revision"].to_s
      raise Invalid, "A current installation claim is required" unless value["claim_binding"] == Digest::SHA256.hexdigest(claim.to_s)
    end

    # Only called while BootstrapState owns the installation lock.
    def save(value)
      value["revision"] += 1
      value["updated_at"] = Time.now.utc.iso8601(6)
      Tempfile.create([ "installation-", ".json" ], @state.root) do |file|
        file.write(JSON.generate(value))
        file.flush
        file.fsync
        File.rename(file.path, @path)
      end
      File.open(@state.root, File::RDONLY, &:fsync)
      value
    end
  end
end
