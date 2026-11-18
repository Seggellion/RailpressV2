require "test_helper"
require "railpress/native_host"
require "tmpdir"

class NativeCommandsTest < ActiveSupport::TestCase
  test "receipt failure after spawn reaps the exact child before returning" do
    directory = Dir.mktmpdir("command-exception-", Rails.root.join(".local/state"))
    log = File.join(directory, "child.log")
    filesystem = Railpress::NativeHost::F
    original = filesystem.method(:atomic)
    fired = false
    filesystem.define_singleton_method(:atomic) do |path, *args, **options|
      if path == log + ".result.json" && !fired
        fired = true
        raise Railpress::NativeHost::Error, "controlled_receipt_failure"
      end
      original.call(path, *args, **options)
    end
    error = assert_raises(Railpress::NativeHost::Error) do
      Railpress::NativeHost::Commands.run([ RbConfig.ruby, "-e", "sleep 60" ], log: log)
    end
    assert_equal "controlled_receipt_failure", error.message
    receipt = JSON.parse(File.read(log + ".result.json"))
    assert_equal "FAILED", receipt["state"]
    assert_equal [ "TERM" ], receipt["sent_signals"]
    assert_equal Signal.list.fetch("TERM"), receipt["termsig"]
    assert_raises(Errno::ECHILD) { Process.waitpid(receipt.fetch("pid"), Process::WNOHANG) }
  ensure
    filesystem.define_singleton_method(:atomic, original) if original
    FileUtils.remove_entry_secure(directory) if directory && passed?
  end
end
