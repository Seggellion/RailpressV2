module SecurityClockTestSupport
  def replacing_method(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name, &replacement)
    yield
  ensure
    object.define_singleton_method(name, original) if original
  end

  def with_controlled_security_clock
    ticks = { value: 100.0, domain: "synthetic-supported-boot-domain" }
    clock = Railpress::SecurityClock.new(@private_root, elapsed: -> { ticks[:value] }, domain: -> { ticks[:domain] })
    replacing_method(Railpress::SecurityClock, :for_application, -> { clock }) { clock.sample; yield clock, ticks }
  end

  # A deliberate normal-time passage fixture is different from an injected
  # untrusted clock step. Exercise the public reconciliation API explicitly.
  def with_qualified_utc(time)
    travel_to(time, with_usec: true) do
      Railpress::SecurityClock.for_application.reconcile!(trusted_utc: Time.now.to_f,
        source: "Deterministic synthetic UTC fixture; not host UTC qualification")
      yield
    end
  end

  def clock_evidence(name, value)
    root = Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE", "M10/clock-approved/proof"))
    FileUtils.mkdir_p(root)
    path = root.join("#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-#{name}.json")
    File.write(path, JSON.pretty_generate(value) + "\n")
  end
end
