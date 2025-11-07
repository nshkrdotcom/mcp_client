# Implementation Prompt 05: Backoff and Closing States

**Goal:** Implement :backoff state with exponential backoff and reconnection, and :closing state for graceful shutdown.

**Test Strategy:** TDD with rgr. All tests green, no warnings.

---

## Context: What You're Building

You're implementing the final two states of the Connection state machine:
- **:backoff**: Exponential backoff with scheduled reconnection after failures
- **:closing**: Terminal shutdown state that ignores all operations except final cleanup

These states handle connection resilience and graceful termination.

---

## Required Reading: State Transitions

From STATE_TRANSITIONS.md, these are the exact transitions to implement:

### :backoff State

| From | Event | Guard | Actions | To |
|------|-------|-------|---------|-----|
| :backoff | `{:state_timeout, :reconnect}` | - | Spawn new transport; wait for transport_up | :initializing |
| :backoff | `{:call, from}, {:request, method, params, opts}` | - | Reply with backoff error | :backoff |
| :backoff | `{:call, from}, :stop` | - | Reply `:ok`; exit(normal) | - |
| :backoff | `{:state_timeout, :tombstone_sweep}` | - | Sweep expired tombstones; reschedule sweep | :backoff |

### :closing State

| From | Event | Guard | Actions | To |
|------|-------|-------|---------|-----|
| :closing | `{:state_timeout, {:retry_send, _}}` | - | Ignore (retries cleared) | :closing |
| :closing | `{:state_timeout, {:request_timeout, _}}` | - | Ignore (requests cleared) | :closing |
| :closing | `{:state_timeout, :tombstone_sweep}` | - | Ignore (shutting down) | :closing |
| :closing | `{:call, from}, _` | - | Reply with shutdown error | :closing |
| :closing | `{:info, _}` | - | Ignore | :closing |

**Note**: :closing is reached via `{:stop_and_reply, :normal, ...}` so most clauses are defensive.

---

## Key Requirements from ADRs

### ADR-0002: Backoff Delay Management

**Exponential increase on failure:**
```elixir
new_delay = min(data.backoff_delay * 2, data.backoff_max)
%{data | backoff_delay: new_delay}
```

**Reset on success (when entering :ready):**
```elixir
%{data | backoff_delay: data.backoff_min}
```

**Schedule reconnect:**
```elixir
[{:state_timeout, data.backoff_delay, :reconnect}]
```

### ADR-0005: Tombstone Sweep

**Sweep logic:**
```elixir
defp sweep_tombstones(data) do
  now = System.monotonic_time(:millisecond)

  new_tombstones =
    data.tombstones
    |> Enum.reject(fn {_id, %{inserted_at_mono: inserted, ttl_ms: ttl}} ->
      now - inserted >= ttl
    end)
    |> Enum.into(%{})

  %{data | tombstones: new_tombstones}
end
```

**Reschedule sweep:**
```elixir
[{:state_timeout, data.tombstone_sweep_ms, :tombstone_sweep}]
```

**Sweep in all states** (except :closing):
- :ready
- :initializing
- :backoff

### ADR-0009: Fail-Fast Shutdown

**Backoff error for requests in :backoff:**
```elixir
%{
  kind: :unavailable,
  message: "Connection in backoff, retry in #{data.backoff_delay}ms"
}
```

**Shutdown error in :closing:**
```elixir
%{
  kind: :shutdown,
  message: "Connection is shutting down"
}
```

---

## Implementation Requirements

### 1. Implement :backoff State - Reconnect

```elixir
def handle_event(:state_timeout, :reconnect, :backoff, data) do
  Logger.info("Reconnecting after backoff (#{data.backoff_delay}ms)")

  # Increase backoff delay for next failure
  new_delay = min(data.backoff_delay * 2, data.backoff_max)
  data = %{data | backoff_delay: new_delay}

  # Trigger transport spawn (same as :starting)
  {:next_state, :initializing, data, [{:next_event, :internal, {:spawn_transport, data}}]}
end
```

**Note**: This reuses the transport spawn logic. You may need to store original opts in data or refactor spawn logic.

### 2. Implement :backoff State - Request Rejection

```elixir
def handle_event({:call, from}, {:request, _method, _params, _opts}, :backoff, data) do
  error = %{
    kind: :unavailable,
    message: "Connection in backoff, retry in #{data.backoff_delay}ms",
    details: %{backoff_delay_ms: data.backoff_delay}
  }

  {:keep_state_and_data, [{:reply, from, {:error, error}}]}
end
```

### 3. Implement :backoff State - Stop

```elixir
def handle_event({:call, from}, :stop, :backoff, _data) do
  Logger.info("Stopping in backoff state")
  {:stop_and_reply, :normal, [{:reply, from, :ok}]}
end
```

### 4. Implement Tombstone Sweep (All States)

```elixir
# In :ready state
def handle_event(:state_timeout, :tombstone_sweep, :ready, data) do
  data = sweep_tombstones(data)
  actions = [{:state_timeout, data.tombstone_sweep_ms, :tombstone_sweep}]
  {:keep_state, data, actions}
end

# In :initializing state
def handle_event(:state_timeout, :tombstone_sweep, :initializing, data) do
  data = sweep_tombstones(data)
  actions = [{:state_timeout, data.tombstone_sweep_ms, :tombstone_sweep}]
  {:keep_state, data, actions}
end

# In :backoff state
def handle_event(:state_timeout, :tombstone_sweep, :backoff, data) do
  data = sweep_tombstones(data)
  actions = [{:state_timeout, data.tombstone_sweep_ms, :tombstone_sweep}]
  {:keep_state, data, actions}
end

# Helper function
defp sweep_tombstones(data) do
  now = System.monotonic_time(:millisecond)

  new_tombstones =
    data.tombstones
    |> Enum.reject(fn {_id, %{inserted_at_mono: inserted, ttl_ms: ttl}} ->
      now - inserted >= ttl
    end)
    |> Enum.into(%{})

  swept_count = map_size(data.tombstones) - map_size(new_tombstones)

  if swept_count > 0 do
    Logger.debug("Swept #{swept_count} expired tombstones")
  end

  %{data | tombstones: new_tombstones}
end
```

### 5. Implement :closing State

```elixir
# Ignore retry timers (already handled in Prompt 04)
def handle_event(:state_timeout, {:retry_send, _id}, :closing, _data) do
  {:keep_state_and_data, []}
end

# Ignore request timeouts
def handle_event(:state_timeout, {:request_timeout, _id}, :closing, _data) do
  {:keep_state_and_data, []}
end

# Ignore tombstone sweep
def handle_event(:state_timeout, :tombstone_sweep, :closing, _data) do
  {:keep_state_and_data, []}
end

# Reject new calls
def handle_event({:call, from}, _event, :closing, _data) do
  error = %{
    kind: :shutdown,
    message: "Connection is shutting down"
  }
  {:keep_state_and_data, [{:reply, from, {:error, error}}]}
end

# Ignore all info messages
def handle_event(:info, _msg, :closing, _data) do
  {:keep_state_and_data, []}
end
```

**Note**: Most :closing logic is already handled by `{:stop_and_reply, :normal, ...}` in stop handler. These clauses are defensive.

### 6. Update schedule_backoff_action Helper

Previously used in Prompts 02-04, now implement fully:

```elixir
defp schedule_backoff_action(data) do
  delay = data.backoff_delay
  new_delay = min(data.backoff_delay * 2, data.backoff_max)
  data = %{data | backoff_delay: new_delay}
  {data, [{:state_timeout, delay, :reconnect}]}
end
```

**Usage**: All transitions to :backoff should use this helper.

### 7. Store Original Options for Reconnect

To spawn transport during reconnect, we need original options. Add to data struct:

```elixir
# In init/1:
data = %__MODULE__{
  # ... existing fields ...
  opts: opts  # Store original options
}
```

Then in reconnect:

```elixir
def handle_event(:state_timeout, :reconnect, :backoff, data) do
  # Use stored opts
  {:next_state, :initializing, data, [{:next_event, :internal, {:spawn_transport, data.opts}}]}
end
```

---

## Test File: test/mcp_client/connection_test.exs

Add these tests:

```elixir
describe ":backoff state" do
  setup do
    {:ok, pid} = Connection.start_link(transport: :mock)

    # Force into backoff (e.g., kill transport)
    send(pid, {:transport, :up})
    Process.sleep(10)
    send(pid, {:transport, :down, :test_failure})
    Process.sleep(10)

    {:ok, connection: pid}
  end

  test "rejects requests with backoff error", %{connection: conn} do
    result = :gen_statem.call(conn, {:request, "test", %{}, []})

    assert {:error, %{kind: :unavailable, message: msg}} = result
    assert msg =~ "backoff"
  end

  test "schedules reconnection", %{connection: conn} do
    # Manually trigger reconnect timeout
    send(conn, {:state_timeout, :reconnect})

    # Should transition to initializing
    Process.sleep(10)
    # Verify via state query (needs API)
  end

  test "exponential backoff increases delay", %{connection: conn} do
    # First backoff delay should be backoff_min (1000ms)
    # After reconnect fails, should be 2000ms
    # Then 4000ms, etc., up to backoff_max (30000ms)

    # This test needs introspection or telemetry
  end

  test "handles stop in backoff", %{connection: conn} do
    assert :ok = :gen_statem.call(conn, :stop)
    refute Process.alive?(conn)
  end

  test "sweeps tombstones in backoff", %{connection: conn} do
    # Add some tombstones
    # Wait for sweep timer
    # Verify they're cleaned up
    # (Needs state introspection)
  end
end

describe ":closing state" do
  test "ignores retry timers" do
    {:ok, pid} = Connection.start_link(transport: :mock)

    # Transition to ready, make request, stop
    # ... (setup to get into :closing with pending retry timer)

    # Retry timer should be ignored, no crash
  end

  test "rejects new requests" do
    {:ok, pid} = Connection.start_link(transport: :mock)

    # Stop (enters :closing via stop_and_reply)
    spawn(fn -> :gen_statem.call(pid, :stop) end)
    Process.sleep(10)

    # Try to make request (if connection still alive briefly)
    if Process.alive?(pid) do
      result = :gen_statem.call(pid, {:request, "test", %{}, []})
      assert {:error, %{kind: :shutdown}} = result
    end
  end

  test "ignores info messages" do
    {:ok, pid} = Connection.start_link(transport: :mock)

    # Stop
    spawn(fn -> :gen_statem.call(pid, :stop) end)
    Process.sleep(10)

    # Send random info messages
    if Process.alive?(pid) do
      send(pid, {:transport, :frame, "random"})
      send(pid, {:random, :message})

      # Should not crash
      Process.sleep(10)
    end
  end
end

describe "tombstone sweep" do
  setup do
    {:ok, pid} = Connection.start_link(
      transport: :mock,
      tombstone_ttl_ms: 100,  # Short TTL for testing
      tombstone_sweep_ms: 50   # Fast sweep
    )

    # Transition to ready
    send(pid, {:transport, :up})
    Process.sleep(10)

    init_response = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "test", "version" => "1.0"}
      }
    }
    send(pid, {:transport, :frame, Jason.encode!(init_response)})
    Process.sleep(10)

    {:ok, connection: pid}
  end

  test "removes expired tombstones", %{connection: conn} do
    # Make request and let it timeout
    task = Task.async(fn ->
      :gen_statem.call(conn, {:request, "test", %{}, timeout: 50})
    end)

    {:ok, id} = Task.await(task)

    # Trigger timeout
    send(conn, {:state_timeout, {:request_timeout, id}})
    Process.sleep(10)

    # ID is now tombstoned

    # Wait for TTL to expire + sweep
    Process.sleep(200)

    # Tombstone should be swept
    # (Verify via state introspection or by observing map size via telemetry)
  end

  test "sweep runs in all non-closing states", %{connection: conn} do
    # Sweep should run in :ready, :initializing, :backoff
    # Verify via logs or telemetry
    # This is mostly a smoke test
  end
end

describe "backoff reset on success" do
  test "resets to backoff_min after successful connection" do
    {:ok, pid} = Connection.start_link(
      transport: :mock,
      backoff_min: 1_000,
      backoff_max: 30_000
    )

    # Fail connection (enters backoff, delay increases to 2000)
    send(pid, {:transport, :up})
    Process.sleep(10)
    send(pid, {:transport, :down, :test})
    Process.sleep(10)

    # Reconnect successfully
    send(pid, {:state_timeout, :reconnect})
    send(pid, {:transport, :up})
    Process.sleep(10)

    init_response = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "test", "version" => "1.0"}
      }
    }
    send(pid, {:transport, :frame, Jason.encode!(init_response)})
    Process.sleep(10)

    # Now in :ready, backoff_delay should be reset to 1000
    # (Verify via state introspection)
  end
end
```

---

## Success Criteria

Run tests with:
```bash
mix test test/mcp_client/connection_test.exs
```

**Must achieve:**
- ✅ All tests pass (green)
- ✅ No warnings
- ✅ :backoff schedules reconnection correctly
- ✅ Exponential backoff increases properly
- ✅ Backoff resets on success (entering :ready)
- ✅ Tombstone sweep works in all states
- ✅ :closing ignores all events gracefully
- ✅ Stop works in all states

---

## Constraints

- **DO NOT** implement helper functions beyond spec
- **DO NOT** add telemetry yet (later prompt)
- **DO NOT** implement public API yet
- Backoff formula: `min(delay * 2, backoff_max)`
- Tombstone sweep: millisecond monotonic time
- :closing is mostly defensive (stop_and_reply handles main flow)

---

## Implementation Notes

### Reconnection Options

We store original `opts` in data struct to reuse during reconnect. This includes:
- Transport type (:stdio, :sse, etc.)
- Command and args (for stdio)
- URL (for SSE)
- All configuration values

### Backoff Timing

**Default backoff progression:**
- Start: 1000ms (backoff_min)
- After 1st failure: 2000ms
- After 2nd failure: 4000ms
- After 3rd failure: 8000ms
- After 4th failure: 16000ms
- After 5th failure: 30000ms (backoff_max, caps here)

**Reset on success**: When transitioning to :ready, reset to 1000ms.

### Tombstone Sweep Frequency

Default: 60 seconds (60_000ms). Sweeps run in background, don't block requests.

**Complexity**: O(n) where n = tombstone count. With 75s TTL and 60s sweep, typical size is small (< 100 entries for most workloads).

### :closing Defensive Clauses

Most `{:call, from}, :stop` handlers use:
```elixir
{:stop_and_reply, :normal, [{:reply, from, :ok}]}
```

This immediately terminates the process. The :closing state clauses are for race conditions where events arrive after stop but before terminate/3 runs.

### State Introspection API

Tests reference "state introspection" - this will be implemented in a later prompt as:
```elixir
:sys.get_state(pid)
# or
:gen_statem.call(pid, :get_state)  # Custom debug API
```

---

## Deliverable

Provide the updated `lib/mcp_client/connection.ex` that:
1. Implements :backoff state with reconnection
2. Implements exponential backoff correctly
3. Resets backoff on successful connection
4. Implements tombstone sweep in all states
5. Implements :closing state defensive clauses
6. Stores original opts for reconnection
7. Passes all tests
8. Compiles without warnings

If any requirement is unclear, insert `# TODO: <reason>` and stop.
