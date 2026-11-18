# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "openssl"
require "securerandom"
require "tempfile"
require_relative "security_clock"

module Railpress
  # Independent of Rails/Active Record: safe to read before the DB/schema exists.
  class BootstrapState
    class Error < StandardError; end
    class Closed < Error; end
    class InvalidClaim < Error; end
    class Corrupt < Error; end
    class ExistingInstall < Error
      attr_reader :install_id
      def initialize(install_id)
        @install_id = install_id
        super("A site is already installed")
      end
    end

    SECRET_TTL = 30 * 60
    CLAIM_TTL = 10 * 60
    MAX_ATTEMPTS = 8
    attr_reader :root

    def self.for_application
      environment = ENV.fetch("RAILS_ENV", "development")
      namespace = environment == "test" ? "test/#{ENV.fetch('RAILPRESS_TEST_ENGINE', 'unconfigured')}" : environment
      root = ENV.fetch("RAILPRESS_PRIVATE_STATE_ROOT") { File.expand_path("../../.local/state/bootstrap/#{namespace}", __dir__) }
      new(root)
    end

    def initialize(root)
      raise Corrupt, "Private state path must be absolute" unless File.absolute_path(root) == root.to_s
      @root = root.to_s
    end

    def public_status
      document = read
      { installed: document["status"] == "installed", install_id: document["install_id"] }
    end

    def installed?
      read.fetch("status") == "installed"
    end

    def install_id
      read["install_id"]
    end

    def issue!
      synchronize do |document|
        raise Closed, "Setup is closed" if document["status"] == "installed"
        token = SecureRandom.hex(32)
        expires_at = Time.now.to_f + SECRET_TTL
        persist("version" => 1, "status" => "pending", "secret_digest" => digest(token),
          "secret_expires_at" => expires_at, "secret_clock" => clock_deadline(SECRET_TTL, expires_at), "attempts" => 0)
        token
      end
    end

    def claim!(token)
      synchronize do |document|
        raise Closed, "Setup is closed" if document["status"] == "installed"
        valid = document["status"] == "pending" && document["attempts"].to_i < MAX_ATTEMPTS &&
          unexpired?(document, "secret") && matches?(token, document["secret_digest"])
        unless valid
          if document["secret_digest"]
            document["attempts"] = [ document["attempts"].to_i + 1, MAX_ATTEMPTS ].min
            persist(document)
          end
          raise InvalidClaim, "Invalid or expired setup secret"
        end
        nonce = SecureRandom.hex(32)
        expires_at = Time.now.to_f + CLAIM_TTL
        persist("version" => 1, "status" => "claimed", "claim_digest" => digest(nonce),
          "claim_expires_at" => expires_at, "claim_clock" => clock_deadline(CLAIM_TTL, expires_at))
        nonce
      end
    end

    def claimed?(nonce)
      synchronize { |document| valid_claim?(document, nonce) }
    end

    # All wizard transitions share the pre-DB installation lock and claim authority.
    def with_claim!(nonce)
      synchronize do |document|
        raise Closed, "Setup is closed" if document["status"] == "installed"
        raise InvalidClaim, "Setup claim expired" unless valid_claim?(document, nonce)
        yield
      end
    end

    # Native operator schema work shares the exact completion fence.
    def with_uninstalled!
      synchronize do |document|
        raise Closed, "Setup is closed" if document["status"] == "installed"
        yield
      end
    end

    def complete!(nonce)
      synchronize do |document|
        raise Closed, "Setup is closed" if document["status"] == "installed"
        raise InvalidClaim, "Setup claim expired" unless valid_claim?(document, nonce)
        begin
          id = yield
          persist(installed_document(id))
          id
        rescue ExistingInstall => error
          persist(installed_document(error.install_id))
          raise Closed, "Setup is closed"
        end
      end
    end

    def reconcile!(id)
      synchronize do |document|
        raise Corrupt, "Install identity mismatch" if document["status"] == "installed" && document["install_id"] != id
        yield if block_given?
        persist(installed_document(id))
      end
    end

    private

    def installed_document(id)
      raise Corrupt, "Invalid install identity" unless /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.match?(id.to_s)
      { "version" => 1, "status" => "installed", "install_id" => id }
    end

    def valid_claim?(document, nonce)
      document["status"] == "claimed" && unexpired?(document, "claim") &&
        matches?(nonce, document["claim_digest"])
    end

    def monotonic = SecurityClock.elapsed

    def boot_identity
      SecurityClock.boot_domain
    rescue Errno::ENOENT, Errno::EACCES
      raise Corrupt, "A supported monotonic host clock is required for setup"
    end

    def clock_deadline(ttl, expires_at)
      security_clock.issue(ttl: ttl, expires_at: expires_at)
    end

    def unexpired?(document, kind)
      return false if document["#{kind}_expired"]
      valid = security_clock.valid?(document["#{kind}_clock"], expires_at: document["#{kind}_expires_at"],
        ttl: kind == "secret" ? SECRET_TTL : CLAIM_TTL)
      unless valid
        document["#{kind}_expired"] = true
        persist(document)
      end
      valid
    end

    def security_clock
      SecurityClock.new(root, elapsed: -> { monotonic }, domain: -> { boot_identity })
    end

    def digest(token)
      Digest::SHA256.hexdigest(token)
    end

    def matches?(token, expected)
      token.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(token) && expected.is_a?(String) &&
        expected.bytesize == 64 && OpenSSL.fixed_length_secure_compare(digest(token), expected)
    end

    def ensure_directory
      FileUtils.mkdir_p(@root, mode: 0o700)
      stat = File.lstat(@root)
      raise Corrupt, "Private state directory is unsafe" if stat.symlink? || stat.uid != Process.uid || (stat.mode & 0o077) != 0
    end

    def verify_file(path)
      stat = File.lstat(path)
      raise Corrupt, "Private state file is unsafe" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
    end

    def read
      path = File.join(@root, "setup.json")
      return { "version" => 1, "status" => "pending" } unless File.exist?(path) || File.symlink?(path)
      stat = File.lstat(@root)
      raise Corrupt, "Private state directory is unsafe" if stat.symlink? || stat.uid != Process.uid || (stat.mode & 0o077) != 0
      verify_file(File.join(@root, "setup.json"))
      document = JSON.parse(File.read(File.join(@root, "setup.json")))
      raise Corrupt, "Invalid bootstrap state" unless document.is_a?(Hash) && document["version"] == 1 && %w[pending claimed installed].include?(document["status"])
      installed_document(document["install_id"]) if document["status"] == "installed"
      document
    rescue JSON::ParserError, Errno::EACCES
      raise Corrupt, "Private bootstrap state is unavailable"
    end

    def synchronize
      ensure_directory
      path = File.join(@root, "setup.lock")
      verify_file(path) if File.exist?(path) || File.symlink?(path)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield read
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def persist(document)
      Tempfile.create([ "setup-", ".json" ], @root) do |file|
        file.write(JSON.generate(document))
        file.flush
        file.fsync
        File.rename(file.path, File.join(@root, "setup.json"))
      end
      File.open(@root, File::RDONLY) { |directory| directory.fsync }
    end
  end
end
