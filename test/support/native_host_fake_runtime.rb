# Unit lifecycle double only. Actual Nginx/Puma/worker qualification is separate.
class NativeHostFakeRuntime
  attr_reader :switches, :observed
  def initialize(config, fixtures, theme_contract)
    @config, @fixtures, @themes = config, fixtures, theme_contract
    @live = {}
    @switches = []
    @observed = nil
    @real_probe = Railpress::NativeHost::Probe.new(config)
  end
  def processes = self
  def probe = self
  def proxy = self
  def verified(record) = record.is_a?(Hash) && record["alive"]
  def recover_services!(_state); end
  def prepare_tree!(id, manifest)
    destination = @config.path("releases", id)
    unless File.exist?(destination)
      Railpress::Releases::Bundle.extract!(@config.path("inbox", id, "package.tar.gz"), destination, manifest)
    end
    Railpress::NativeHost::Plan.new(@config).tree!(id, manifest)
  end
  def dependencies!(_id, _request); end
  def start_puma!(state, id, slot, **_options)
    @live[slot] = id
    node = (state["services"][id] ||= { "slot" => slot })
    node["puma"] = { "alive" => true }
    report(id)
  end
  def health(slot: nil)
    id = slot.nil? ? @observed.fetch("release_id") : @live.fetch(slot)
    report(id)
  end
  def identity!(*args, **options) = @real_probe.identity!(*args, **options)
  def report(id)
    { "format" => "railpress.release-health.v1", "deployment_id" => @config.data["deployment_id"],
      "installation_id" => @config.data["install_id"], "release_id" => id,
      "product" => { "version" => @fixtures.fetch(id)["manifest"]["version"], "security_clock" => 2 },
      "business_fingerprints" => { "Content" => "a" * 64, "User" => "b" * 64 }, "themes" => @themes,
      "theme" => @themes.first, "clock_binding" => "c" * 64, "clock_anomaly" => false }
  end
  def worker!(state, id, _slot)
    state["services"].fetch(id)["worker"] = { "alive" => true }
  end
  def stop_worker!(state, id)
    node = state["services"][id]
    node["worker"] = nil if node
  end
  def stop_puma!(state, id)
    node = state["services"][id]
    return unless node
    @live.delete(node["slot"])
    node["puma"] = nil
  end
  def routes!(_plan, slot:) = [ { "status" => 200, "slot" => slot } ]
  def switch!(_record, id:, slot:, generation:, maintenance: false)
    @observed = { "release_id" => id, "generation" => generation, "maintenance" => maintenance }
    @switches << @observed.dup
  end
  def request(_path)
    { "status" => 200, "body" => JSON.generate(@observed) }
  end
  def maintenance!(state, value)
    state["maintenance"] = value
    @observed["maintenance"] = value if @observed
  end
  def seed!(state, id)
    start_puma!(state, id, 0)
    worker!(state, id, 0)
    switch!(nil, id: id, slot: 0, generation: state["generation"])
    @switches.clear
  end
end
