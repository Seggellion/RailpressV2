# frozen_string_literal: true

module Railpress
  module NativeHost
    class Runtime
      attr_reader :processes, :probe, :proxy
      def initialize(config, store)
        @config, @store = config, store
        @processes = Processes.new(config)
        @probe = Probe.new(config)
        @proxy = Proxy.new(config, processes)
      end
      def prepare_tree!(id, manifest)
        destination = @config.path("releases", id)
        unless File.exist?(destination) || File.symlink?(destination)
          Releases::Bundle.extract!(@config.path("inbox", id, "package.tar.gz"), destination, manifest)
        end
        Plan.new(@config).tree!(id, manifest)
        manifest["files"].each do |name, row|
          next unless name.start_with?("public/assets/") && name != "public/assets/.manifest.json"
          relative = name.delete_prefix("public/assets/")
          source = File.join(destination, name)
          target = @config.path("shared", "assets", relative)
          if File.exist?(target) || File.symlink?(target)
            bytes = F.read(target, maximum: row["bytes"])
            raise Error, "retained_asset_collision" unless Digest::SHA256.hexdigest(bytes) == row["sha256"]
          else
            FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
            F.directory!(File.dirname(target), private: true)
            F.atomic(target, F.read(source, maximum: row["bytes"]), mode: 0o444)
          end
        end
        Dir.glob(File.join(destination, "**", "*"), File::FNM_DOTMATCH).select { |path| File.directory?(path) && !File.symlink?(path) }.each { |path| File.chmod(0o500, path) }
        File.chmod(0o500, destination)
        true
      end
      def dependencies!(id, operation_id)
        directory = @config.release(id)
        expected = @config.data.fetch("dependency_hashes")
        expected.each do |name, hash|
          raise Error, "unreviewed_dependency_definition" unless Digest::SHA256.hexdigest(F.read(File.join(directory, name), maximum: 1_048_576)) == hash
        end
        Commands.run([ @config.data["ruby_binary"], "-S", "bundle", "check" ], env: @config.runtime_environment(id, slot: 0),
          chdir: directory, log: @config.path("logs", "#{operation_id}-dependencies-#{SecureRandom.uuid}.log"))
      end
      def start_service(state, role, id, slot)
        state["launches"] ||= {}
        raise Error, "service_retention_capacity" if state["launches"].length >= 512
        token = SecureRandom.uuid
        state["launches"][token] = { "role" => role, "release_id" => id, "slot" => slot }
        @store.persist(state)
        processes.start(role: role, release_id: id, slot: slot, token: token)
      end
      def recover_services!(state)
        state["services"] ||= {}
        processes.records.each do |record|
          expected = state.fetch("launches", {})[record["token"]]
          next unless expected
          raise Error, "service_intent_mismatch" unless expected == record.slice("role", "release_id", "slot") &&
            record["deployment_id"] == @config.data["deployment_id"]
          record["executable"] = File.realpath(record["role"] == "proxy" ? @config.data["nginx_binary"] : @config.data["ruby_binary"])
          next unless processes.verified(record)
          if record["role"] == "proxy"
            raise Error, "multiple_proxy_processes" if state["proxy"] && processes.verified(state["proxy"]) && state["proxy"]["pid"] != record["pid"]
            state["proxy"] = record
          else
            node = (state["services"][record["release_id"]] ||= { "slot" => record["slot"] })
            old = node[record["role"]]
            raise Error, "multiple_release_processes" if old && processes.verified(old) && old["pid"] != record["pid"]
            node[record["role"]] = record
          end
        end
      end
      def start_puma!(state, id, slot, allow_clock_hold: false)
        node = (state["services"][id] ||= { "slot" => slot })
        raise Error, "service_slot_conflict" unless node["slot"] == slot
        unless processes.verified(node["puma"])
          available_port!(@config.data["puma_ports"][slot])
          node["puma"] = start_service(state, "puma", id, slot)
          @store.persist(state)
        end
        deadline = SecurityClock.elapsed + 20
        loop do
          begin
            report = probe.health(slot: slot)
            raise Error, "candidate_clock_anomaly" if report["clock_anomaly"] && !allow_clock_hold
            return report
          rescue Error => error
            raise error unless error.message == "release_probe_unavailable" && processes.verified(node["puma"])
            raise Error, "candidate_boot_deadline" if SecurityClock.elapsed > deadline
            sleep 0.05
          end
        end
      end
      def routes!(plan, slot:)
        plan.fetch("routes").map do |route|
          response = probe.request(route["path"], slot: slot)
          raise Error, "candidate_route_failed" unless response["status"] == route["status"]
          { "path" => route["path"], "family" => route["family"], "status" => response["status"] }
        end
      end
      def quiescent_report(id, slot)
        log = @config.path("logs", "quiescent-#{SecureRandom.uuid}.log")
        Commands.run([ @config.data["ruby_binary"], File.expand_path("../../../bin/railpress-native-probe", __dir__), "report" ],
          env: @config.runtime_environment(id, slot: slot), chdir: @config.release(id), log: log)
        Releases.parse(F.read(log, maximum: 524_288).strip, limit: 524_288)
      end
      def worker!(state, id, slot)
        node = state["services"].fetch(id)
        return if processes.verified(node["worker"])
        node["worker"] = start_service(state, "worker", id, slot)
        @store.persist(state)
        nonce = SecureRandom.uuid
        log = @config.path("logs", "enqueue-#{nonce}.log")
        Commands.run([ @config.data["ruby_binary"], File.expand_path("../../../bin/railpress-native-probe", __dir__), "enqueue", nonce ],
          env: @config.runtime_environment(id, slot: slot), chdir: @config.release(id), log: log)
        queued = Releases.parse(F.read(log, maximum: 65_536).strip, limit: 65_536)
        state["canaries"] ||= []
        state["canaries"] << { "id" => queued.fetch("canary_id"), "nonce" => nonce, "job_id" => queued.fetch("job_id") }
        @store.persist(state)
        marker = File.join(@config.app_environment["RAILPRESS_PRIVATE_STATE_ROOT"], "release-jobs", "#{nonce}.json")
        deadline = SecurityClock.elapsed + 20
        loop do
          raise Error, "candidate_worker_failed" unless processes.verified(node["worker"])
          if File.exist?(marker)
            result = NativeHost.load_document(marker, maximum: 8192)
            raise Error, "worker_release_identity" unless result.values_at("nonce", "deployment_id", "job_contract") == [ nonce, @config.data["deployment_id"], 1 ]
            product = NativeHost.load_document(File.join(@config.release(id), "lib/railpress/product.json"), maximum: 4096)
            raise Error, "worker_release_identity" unless result["version"] == product["version"]
            node["worker_proof"] = result
            capture_worker_children!(node)
            @store.persist(state)
            return result
          end
          raise Error, "worker_readiness_deadline" if SecurityClock.elapsed > deadline
          sleep 0.05
        end
      end
      def capture_worker_children!(node)
        rows = Database.new(@config).query("SELECT pid FROM solid_queue_processes")
        ids = rows.map { |row| Integer(row["pid"]) }
        raise Error, "worker_supervisor_unverified" unless ids.include?(node["worker"]["pid"])
        node["worker_children"] = ids.filter_map do |pid|
          identity = Processes.identity(pid)
          raise Error, "worker_identity" unless identity && identity["uid"] == Process.uid
          stat = File.read("/proc/#{pid}/stat")
          group = stat[(stat.rindex(")") + 2)..].split.fetch(2).to_i
          raise Error, "unowned_database_worker" unless group == node["worker"]["pid"]
          identity
        end
      end
      def stop_worker!(state, id)
        node = state["services"][id]
        return unless node && (node["worker"] || Array(node["worker_children"]).any?)
        capture_worker_children!(node) if processes.verified(node["worker"])
        processes.stop(node["worker"]) if node["worker"]
        Array(node["worker_children"]).each { |record| processes.stop(record) }
        @store.persist(state)
        owned = [ node.dig("worker", "pid"), *Array(node["worker_children"]).map { |record| record["pid"] } ].compact.map { |pid| Integer(pid) }.uniq
        remaining = Database.new(@config).query("SELECT pid FROM solid_queue_processes").map { |row| Integer(row["pid"]) }
        raise Error, "worker_registration_remains" if (remaining & owned).any?
      end
      def stop_puma!(state, id)
        node = state["services"][id]
        processes.stop(node["puma"]) if node && node["puma"]
        @store.persist(state)
      end
      def start_proxy!(state, id, slot)
        proxy.write_initial!(id: id, slot: slot, generation: state["generation"], maintenance: state["maintenance"])
        available_port!(@config.data["edge_port"])
        state["proxy"] = start_service(state, "proxy", id, slot)
        @store.persist(state)
        deadline = SecurityClock.elapsed + 10
        loop do
          begin
            result = probe.request("/__railpress_deployment")
            return if result["status"] == 200
          rescue Error
            raise Error, "proxy_start_failed" unless processes.verified(state["proxy"])
          end
          raise Error, "proxy_start_deadline" if SecurityClock.elapsed > deadline
          sleep 0.05
        end
      end
      def maintenance!(state, value)
        id = state.fetch("active")
        slot = state["services"].fetch(id).fetch("slot")
        proxy.switch!(state.fetch("proxy"), id: id, slot: slot, generation: state["generation"], maintenance: value)
        state["maintenance"] = value
        @store.persist(state)
      end
      def stop_all_apps!(state)
        state["services"].keys.each do |id|
          stop_worker!(state, id) if state["services"][id]["worker"] && processes.verified(state["services"][id]["worker"])
          stop_puma!(state, id)
        end
      end
      private
      def available_port!(port)
        server = TCPServer.new("127.0.0.1", port)
        server.close
      rescue SystemCallError
        raise Error, "native_port_occupied"
      end
    end
  end
end
