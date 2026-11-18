# frozen_string_literal: true

module Railpress
  module NativeHost
    class Processes
      def initialize(config)
        @config = config
      end
      def self.identity(pid)
        pid = Integer(pid)
        raise Error, "service_pid" unless pid > 1
        stat = File.read("/proc/#{pid}/stat")
        fields = stat[(stat.rindex(")") + 2)..].split
        { "pid" => pid, "start_ticks" => fields.fetch(19), "domain" => SecurityClock.boot_domain,
          "uid" => File.stat("/proc/#{pid}").uid, "executable" => File.realpath("/proc/#{pid}/exe"), "state" => fields.fetch(0) }
      rescue SystemCallError, ArgumentError, IndexError
        nil
      end
      def verified(record)
        return false unless record.is_a?(Hash)
        current = self.class.identity(record["pid"])
        current && current["state"] != "Z" && %w[pid start_ticks domain uid executable].all? { |key| current[key] == record[key] } && current["uid"] == Process.uid
      end
      def start(role:, release_id:, slot:, token: SecureRandom.uuid)
        raise Error, "service_role" unless %w[puma worker proxy].include?(role)
        Releases.identity!(release_id)
        raise Error, "service_slot" unless [ 0, 1 ].include?(slot)
        @config.database!
        NativeHost.uuid!(token)
        record_path = @config.path("run", "#{token}.json")
        launcher = File.expand_path("../../../bin/railpress-native-service", __dir__)
        log = File.open(@config.path("logs", "#{token}.log"), File::WRONLY | File::CREAT | File::EXCL, 0o600)
        argv = [ @config.data["ruby_binary"], launcher, @config.root, role, release_id, slot.to_s, token ]
        pid = Process.spawn({ "PATH" => File.dirname(@config.data["ruby_binary"]) + ":/usr/bin:/bin", "HOME" => ENV.fetch("HOME") },
          *argv, in: File::NULL, out: log, err: log, pgroup: true, unsetenv_others: true)
        Process.detach(pid)
        deadline = SecurityClock.elapsed + 10
        loop do
          if File.exist?(record_path)
            record = NativeHost.load_document(record_path, maximum: 8192)
            raise Error, "service_record_identity" unless record["token"] == token && record["role"] == role &&
              record["release_id"] == release_id && record["pid"] == pid && record["slot"] == slot
            # The child writes its own identity before exec; executable is Ruby
            # until exec finishes, then the pinned expected native executable.
            expected = role == "proxy" ? @config.data["nginx_binary"] : @config.data["ruby_binary"]
            record["executable"] = File.realpath(expected)
            return record if verified(record)
          end
          raise Error, "service_start_failed" unless self.class.identity(pid)
          raise Error, "service_start_deadline" if SecurityClock.elapsed > deadline
          sleep 0.02
        end
      ensure
        log&.close
      end
      def stop(record, seconds: 15)
        return false unless verified(record)
        Process.kill("TERM", record.fetch("pid"))
        deadline = SecurityClock.elapsed + seconds
        while verified(record)
          raise Error, "service_drain_deadline" if SecurityClock.elapsed > deadline
          sleep 0.02
        end
        true
      rescue Errno::ESRCH
        false
      end
      def signal(record, signal)
        raise Error, "service_identity_changed" unless verified(record)
        raise Error, "service_signal" unless %w[HUP TERM QUIT].include?(signal)
        Process.kill(signal, record.fetch("pid"))
      end
      def records
        Dir.glob(@config.path("run", "*.json")).select { |path| Releases::UUID.match?(File.basename(path, ".json")) }.map { |path| NativeHost.load_document(path, maximum: 8192) }
      end
    end
    class Child
      def self.run(argv)
        root, role, id, slot_text, token = argv
        raise Error, "service_arguments" unless argv.length == 5 && %w[puma worker proxy].include?(role) && %w[0 1].include?(slot_text)
        Releases.identity!(id)
        NativeHost.uuid!(token)
        config = Config.new(root)
        config.database!
        slot = Integer(slot_text)
        env = config.runtime_environment(id, slot: slot)
        directory = config.release(id)
        command = case role
        when "puma"
          [ config.data["ruby_binary"], File.expand_path("../../../bin/railpress-native-web", __dir__) ]
        when "worker"
          [ config.data["ruby_binary"], File.expand_path("../../../bin/railpress-native-worker", __dir__) ]
        when "proxy"
          env = { "PATH" => "/usr/bin:/bin", "HOME" => ENV.fetch("HOME") }
          [ config.data["nginx_binary"], "-p", config.path("proxy") + "/", "-c", config.path("proxy", "nginx.conf"), "-g", "daemon off;" ]
        end
        record = Processes.identity(Process.pid).merge("deployment_id" => config.data["deployment_id"], "role" => role, "release_id" => id, "slot" => slot, "token" => token)
        F.atomic(config.path("run", "#{token}.json"), Releases.canonical(record))
        Dir.chdir(directory)
        # No operator configuration, root path, approval or signer is inherited.
        exec(env, *command, unsetenv_others: true)
      end
    end
  end
end
