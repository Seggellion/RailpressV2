# Frozen native adapter configuration; does not edit a release's own config.
threads 5, 5
bind "tcp://127.0.0.1:#{Integer(ENV.fetch('PORT'))}"
pidfile ENV.fetch("PIDFILE")
release_directory = File.dirname(ENV.fetch("BUNDLE_GEMFILE"))
Railpress::NativeScope.boot!
Kernel.load File.expand_path("../lib/railpress/native_web_probe.rb", __dir__)
app Railpress::NativeWebProbe.new(Rails.application)
