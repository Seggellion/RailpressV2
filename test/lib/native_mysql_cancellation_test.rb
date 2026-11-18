require "test_helper"
require_relative "../support/media_test_support"
require_relative "../support/native_host_test_support"

class NativeMysqlCancellationTest < ActiveSupport::TestCase
  include MediaTestSupport
  include NativeHostTestSupport
  setup { native_setup }
  teardown { native_teardown }

  def held_restore(force_interrupt: false)
    @native_db.connection do |holder, engine|
      return assert_equal "postgresql", engine unless engine == "mysql2"
      holder.query("CREATE TABLE rp_cancel_probe(id bigint PRIMARY KEY) ENGINE=InnoDB")
      holder.query("INSERT INTO rp_cancel_probe VALUES(1)")
      holder.query("START TRANSACTION")
      holder.query("SELECT * FROM rp_cancel_probe FOR UPDATE").to_a
      holder_id = holder.query("SELECT CONNECTION_ID() AS id").first.fetch("id")
      input = @native_config.path("run", "controlled.sql")
      File.write(input, "ALTER TABLE rp_cancel_probe ADD COLUMN note integer;\n", mode: "wx", perm: 0o600)
      original = Railpress::NativeHost::Commands.method(:run)
      callback = proc { |*argv, **options| original.call(*argv, **(force_interrupt ? options.merge(timeout_signal: "INT") : options)) }
      error = assert_raises(Railpress::NativeHost::Error) do
        with_method(Railpress::NativeHost::Commands, :run, callback) do
          @native_db.client_credentials(SecureRandom.uuid) do |target, env, args|
            Railpress::NativeHost::MysqlRestore.new(@native_db, @native_config).run!(SecureRandom.uuid, target, env, args, input)
          end
        end
      end
      assert_equal "native_command_deadline", error.message
      receipt_path = Dir.glob(@native_config.path("logs", "restore-*.log.result.json")).sole
      receipt = Railpress::NativeHost.load_document(receipt_path)
      assert_equal 30, receipt["deadline_seconds"]
      assert receipt["timed_out"]
      assert_equal [ force_interrupt ? "INT" : "TERM" ], receipt["sent_signals"]
      quiescence = Railpress::NativeHost.load_document(receipt_path.sub(/\.result\.json\z/, ".quiescence.json"))
      assert_equal "VERIFIED", quiescence["state"]
      assert quiescence["server_session_absent"]
      assert quiescence["owned_server_cancel_requested"] unless force_interrupt
      assert_empty holder.query("SELECT ID FROM information_schema.PROCESSLIST WHERE ID=#{Integer(quiescence['connection_id'])}").to_a
      assert_equal holder_id, holder.query("SELECT CONNECTION_ID() AS id").first.fetch("id")
      refute File.exist?(@native_config.path("run", "mysql-restore-unsafe.json"))
    ensure
      if engine == "mysql2"
        holder.query("ROLLBACK")
        holder.query("DROP TABLE rp_cancel_probe") unless File.exist?(@native_config.path("run", "mysql-restore-unsafe.json"))
      end
    end
  end

  test "unchanged thirty second deadline stops input and cancels server query before fixture reuse" do
    held_restore
  end

  test "legacy statement interrupt control is still quiesced by the ownership gate" do
    held_restore(force_interrupt: true)
  end

  test "deadline cannot consume a later batch statement after interrupted sleep" do
    return assert_equal "postgresql", ENV.fetch("RAILPRESS_TEST_ENGINE") unless ENV.fetch("RAILPRESS_TEST_ENGINE") == "mysql2"
    @native_db.execute("CREATE TABLE rp_cancel_canary(id integer PRIMARY KEY) ENGINE=InnoDB")
    input = @native_config.path("run", "batch-canary.sql")
    File.write(input, "SELECT SLEEP(60);\nINSERT INTO rp_cancel_canary VALUES(1);\n", mode: "wx", perm: 0o600)
    @native_db.client_credentials(SecureRandom.uuid) do |target, env, args|
      error = assert_raises(Railpress::NativeHost::Error) do
        Railpress::NativeHost::MysqlRestore.new(@native_db, @native_config).run!(SecureRandom.uuid, target, env, args, input)
      end
      assert_equal "native_command_deadline", error.message
    end
    assert_equal 0, @native_db.query("SELECT COUNT(*) AS n FROM rp_cancel_canary").first.fetch("n").to_i
    receipt = Railpress::NativeHost.load_document(Dir.glob(@native_config.path("logs", "restore-*.log.result.json")).sole)
    assert_equal 30, receipt["deadline_seconds"]
    assert_equal [ "TERM" ], receipt["sent_signals"]
    refute File.exist?(@native_config.path("run", "mysql-restore-unsafe.json"))
  ensure
    if input && !File.exist?(@native_config.path("run", "mysql-restore-unsafe.json"))
      @native_db.execute("DROP TABLE rp_cancel_canary")
    end
  end

  test "unverified client identity quarantines cleanup rather than guessing a session" do
    return assert_equal "postgresql", ENV.fetch("RAILPRESS_TEST_ENGINE") unless ENV.fetch("RAILPRESS_TEST_ENGINE") == "mysql2"
    callback = proc do |*_, **options|
      File.write(options.fetch(:output), "", mode: "wx", perm: 0o600)
      raise Railpress::NativeHost::Error, "native_command_failed"
    end
    marker = @native_config.path("run", "mysql-restore-unsafe.json")
    with_method(Railpress::NativeHost::Commands, :run, callback) do
      @native_db.client_credentials(SecureRandom.uuid) do |target, env, args|
        error = assert_raises(Railpress::NativeHost::Error) do
          Railpress::NativeHost::MysqlRestore.new(@native_db, @native_config).run!(SecureRandom.uuid, target, env, args, "/dev/null")
        end
        assert_equal "mysql_restore_session_unverified", error.message
        assert_equal "native_command_failed", error.primary_error["code"]
        assert_equal "native_command_failed", error.cause.message
        receipt = Railpress::NativeHost.load_document(Dir.glob(@native_config.path("logs", "restore-*.quiescence.json")).sole)
        assert_equal "FAILED", receipt["state"]
        assert_equal "native_command_failed", receipt.dig("primary_error", "code")
      end
    end
    assert File.exist?(marker)
    assert_raises(TestSchemaIntegrity::Unsafe) { TestSchemaIntegrity.verify! }
  ensure
    # This test stub never spawns a child or opens a server session. Only its
    # own intentional quarantine can be removed after the refusal assertions.
    File.unlink(marker) if marker && File.file?(marker)
  end
  def delayed_control(seconds)
    return assert_equal "postgresql", ENV.fetch("RAILPRESS_TEST_ENGINE") unless ENV.fetch("RAILPRESS_TEST_ENGINE") == "mysql2"
    absent_id = nil
    @native_db.connection { |client, _| absent_id = client.query("SELECT CONNECTION_ID() AS id").first["id"] }
    marker = @native_config.path("run", "mysql-restore-unsafe.json")
    identity = @native_config.path("run", "closed-session")
    log = @native_config.path("logs", "delayed-control")
    File.write(marker, JSON.generate({ "state" => "UNVERIFIED" }), mode: "wx", perm: 0o600)
    File.write(identity, "#{absent_id}\n", mode: "wx", perm: 0o600)
    control_id = nil
    @native_db.connection do |client, _|
      control_id = client.query("SELECT CONNECTION_ID() AS id").first["id"]
      original = client.method(:query)
      first = true
      client.define_singleton_method(:query) do |sql|
        if first
          first = false
          original.call("SELECT SLEEP(#{Integer(seconds)})")
        end
        original.call(sql)
      end
      target, = @native_config.database!
      error = assert_raises(Railpress::NativeHost::Error) do
        Railpress::NativeHost::MysqlRestore.new(@native_db, @native_config).verify_quiescence!(client, target, identity, marker, log)
      end
      assert_equal seconds == 4 ? "mysql_restore_cleanup_deadline" : "mysql_restore_session_unverified", error.message
    end
    receipt = Railpress::NativeHost.load_document(log + ".quiescence.json")
    assert_equal "FAILED", receipt["state"]
    assert_equal 3, receipt["decision_budget_seconds"]
    assert receipt["over_budget"]
    assert_equal seconds == 4, receipt["server_session_absent"]
    assert File.exist?(marker)
    assert_raises(TestSchemaIntegrity::Unsafe) { TestSchemaIntegrity.verify! }
    puts "R4_REAL_CONTROL_IO: #{JSON.generate(receipt)}"
  ensure
    if marker
      # Only these fresh intentional control sessions/markers are reconciled.
      # The test never launched a restore client. Never touch historical markers.
      @native_db.connection do |client, _|
        target, = @native_config.database!
        [ control_id, absent_id ].compact.each do |id|
          row = client.query("SELECT ID,USER,DB FROM information_schema.PROCESSLIST WHERE ID=#{Integer(id)}").first
          if row
            raise "unexpected control session owner" unless row["USER"] == target["username"] && row["DB"] == target["database"]
            client.query("KILL CONNECTION #{Integer(id)}")
          end
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
          until client.query("SELECT ID FROM information_schema.PROCESSLIST WHERE ID=#{Integer(id)}").to_a.empty?
            raise "control session not quiescent" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            sleep 0.02
          end
        end
      end
      File.unlink(marker) if passed? && File.file?(marker)
    end
  end

  test "actual delayed control absence cannot be verified after three second decision budget" do
    delayed_control(4)
  end

  test "actual native five second read timeout keeps failed cleanup quarantined" do
    delayed_control(6)
  end
end
