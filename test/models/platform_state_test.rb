require "test_helper"

class PlatformStateTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    PlatformState.delete_all
  end

  def teardown
    PlatformState.delete_all
  end

  def create_state(key = "counter", payload = { "count" => 0 })
    PlatformState.create!(scope_name: "foundation", key_name: key, payload: payload)
  end

  test "JSON and four-byte UTF8 roundtrip" do
    data = { "text" => "出版 🚆", "array" => [ 1, true, nil, { "nested" => "é" } ] }
    state = create_state("JSON", data)
    assert_equal data, state.reload.payload
  end

  test "case folding and composed Unicode share database unique identity" do
    create_state("CAFÉ")
    assert_raises(ActiveRecord::RecordNotUnique) { create_state("cafe\u0301") }
    assert_equal 1, PlatformState.count
  end

  test "accents remain distinct intentionally" do
    create_state("cafe")
    create_state("café")
    assert_equal 2, PlatformState.count
  end

  test "long UTF8 keys use bounded composite digest index" do
    key = "界" * 255
    state = create_state(key)
    assert_equal key, state.reload.key_name
    assert_equal 64, state.key_digest.bytesize
    index = PlatformState.connection.indexes(:platform_states).find { |item| item.name == "index_platform_states_identity" }
    assert index.unique
    assert_equal %w[scope_digest key_digest], index.columns
  end

  test "database rejects null payload and negative version" do
    state = create_state
    assert_raises(ActiveRecord::NotNullViolation) { state.update_column(:payload, nil) }
    assert_raises(ActiveRecord::StatementInvalid) { state.update_column(:lock_version, -1) }
  end

  test "rollback preserves prior writes" do
    state = create_state
    PlatformState.transaction do
      state.update!(payload: { "count" => 99 })
      raise ActiveRecord::Rollback
    end
    assert_equal({ "count" => 0 }, state.reload.payload)
  end

  test "optimistic concurrency rejects stale writers" do
    first = create_state
    stale = PlatformState.find(first.id)
    first.update!(payload: { "count" => 1 })
    assert_raises(ActiveRecord::StaleObjectError) { stale.update!(payload: { "count" => 2 }) }
    assert_equal 1, first.reload.payload["count"]
  end

  test "row locks serialize actual concurrent increments" do
    state = create_state
    errors = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          5.times do
            PlatformState.transaction do
              locked = PlatformState.lock.find(state.id)
              locked.update!(payload: { "count" => locked.payload.fetch("count") + 1 })
            end
          end
        end
      rescue => error
        errors << error
      end
    end
    threads.each { |thread| thread.join(15) || flunk("row-lock test timed out") }
    raise errors.pop unless errors.empty?
    assert_equal 10, state.reload.payload["count"]
  end
end
