# Implementation Prompt 02: Starting and Initializing States

**Goal:** Implement :starting and :initializing state logic with transport spawn, initialize handshake, and capability validation.

**Test Strategy:** TDD with rgr. All tests green, no warnings.

---

## Context: What You're Building

You're implementing the first two states of the Connection state machine:
- **:starting**: Spawn the transport process
- **:initializing**: Send initialize request, validate server capabilities, transition to :ready

The scaffold from Prompt 01 is already in place. Now you're adding the actual state logic.

---

## Required Reading: State Transitions

From STATE_TRANSITIONS.md, these are the exact transitions to implement:

### :starting State

| From | Event | Guard | Actions | To |
|------|-------|-------|---------|-----|
| :starting | `{:internal, {:spawn_transport, opts}}` | - | Spawn transport child; wait for `transport_up` | :initializing |
| :starting | `{:call, from}, :stop` | - | Reply `{:ok, :ok}`; exit(normal) | - |

### :initializing State

| From | Event | Guard | Actions | To |
|------|-------|-------|---------|-----|
| :initializing | `{:info, {:transport, :up}}` | - | **Send `initialize` request then set_active(:once)**; arm init_timeout | :initializing |
| :initializing | `{:info, {:transport, :frame, binary}}` | `byte_size > max` | Log error; close transport (no set_active); schedule backoff | :backoff |
| :initializing | `{:info, {:transport, :frame, binary}}` | decode error | Log warning; set_active(:once) (stay in init) | :initializing |
| :initializing | `{:info, {:transport, :frame, binary}}` | valid init response, **caps valid** | Store caps; bump session_id; reset backoff_delay; reply "initialized"; arm tombstone sweep; set_active(:once) | :ready |
| :initializing | `{:info, {:transport, :frame, binary}}` | valid init response, **caps invalid** | Log error; close transport (no set_active); schedule backoff | :backoff |
| :initializing | `{:state_timeout, :init_timeout}` | - | Close transport (no set_active); schedule backoff | :backoff |
| :initializing | `{:info, {:transport, :down, reason}}` | - | Log error; schedule backoff | :backoff |
| :initializing | `{:call, from}, :stop` | - | Reply `{:ok, :ok}`; close transport; exit(normal) | - |

---

## Key Requirements from ADRs

### ADR-0002: Transport Message Contract

Transport MUST emit exactly:
```elixir
{:transport, :up}                  # Once after ready
{:transport, :frame, binary()}     # Only after set_active(:once)
{:transport, :down, reason}        # On any failure
```

### ADR-0004: Active-Once Backpressure

**CRITICAL ORDERING** (from STATE_TRANSITIONS.md):

```elixir
# CORRECT: initialize sent BEFORE set_active
Transport.send_frame(transport, init_frame)
:ok = Transport.set_active(transport, :once)

# WRONG: Would block waiting for response before enabling receive
:ok = Transport.set_active(transport, :once)
Transport.send_frame(transport, init_frame)
```

### ADR-0008: 16MB Frame Size Limit

```elixir
@max_frame_bytes 16_777_216  # 16MB

# Check BEFORE decode
def handle_event(:info, {:transport, :frame, binary}, _, data)
    when byte_size(binary) > @max_frame_bytes do
  Logger.error("Frame exceeds #{@max_frame_bytes} bytes: #{byte_size(binary)}")
  Transport.close(data.transport)  # NO set_active after this
  {:next_state, :backoff, data, schedule_backoff_action(data)}
end
```

### Capability Validation (from MVP_SPEC.md)

**Protocol version check:**
```elixir
# Server must support exactly "2024-11-05"
case server_caps["protocolVersion"] do
  "2024-11-05" -> :ok
  other -> {:error, "Unsupported protocol version: #{inspect(other)}"}
end
```

**MVP Policy**: Fail-fast on version mismatch, no negotiation.

### Backoff Scheduling (from STATE_TRANSITIONS.md)

```elixir
defp schedule_backoff_action(data) do
  delay = data.backoff_delay
  [{:state_timeout, delay, :reconnect}]
end

# On success, reset to backoff_min:
%{data | backoff_delay: data.backoff_min}

# On failure, exponential increase:
new_delay = min(data.backoff_delay * 2, data.backoff_max)
%{data | backoff_delay: new_delay}
```

---

## Implementation Requirements

### 1. Add Module Constants

```elixir
@max_frame_bytes 16_777_216
@protocol_version "2024-11-05"
```

### 2. Implement :starting State

```elixir
def handle_event(:internal, {:spawn_transport, opts}, :starting, data) do
  # This is a simplified version - actual transport spawning
  # will be implemented in the Transport module later.
  # For now, simulate by storing opts and transitioning.

  # Real implementation would:
  # {:ok, transport_pid} = Transport.start_link(opts)

  # For scaffold: store a mock PID or just transition
  # The transport will send {:transport, :up} when ready

  {:next_state, :initializing, data, []}
end

def handle_event({:call, from}, :stop, :starting, _data) do
  {:stop_and_reply, :normal, [{:reply, from, :ok}]}
end
```

### 3. Implement :initializing State - transport_up

```elixir
def handle_event(:info, {:transport, :up}, :initializing, data) do
  # Build initialize request
  init_request = %{
    "jsonrpc" => "2.0",
    "id" => 0,
    "method" => "initialize",
    "params" => %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{
        "name" => "mcp_client",
        "version" => "0.1.0"
      }
    }
  }

  frame = Jason.encode!(init_request)

  # CRITICAL: Send BEFORE set_active
  case Transport.send_frame(data.transport, frame) do
    :ok ->
      :ok = Transport.set_active(data.transport, :once)
      init_timeout = # get from opts or default 10_000
      {:keep_state_and_data, [{:state_timeout, init_timeout, :init_timeout}]}

    {:error, reason} ->
      Logger.error("Failed to send initialize: #{inspect(reason)}")
      {:next_state, :backoff, data, schedule_backoff_action(data)}
  end
end
```

### 4. Implement :initializing State - frame handling

```elixir
# Oversized frame guard (BEFORE other clauses)
def handle_event(:info, {:transport, :frame, binary}, :initializing, data)
    when byte_size(binary) > @max_frame_bytes do
  Logger.error("Frame exceeds limit: #{byte_size(binary)} bytes")
  Transport.close(data.transport)  # NO set_active
  {:next_state, :backoff, data, schedule_backoff_action(data)}
end

# Decode and process frame
def handle_event(:info, {:transport, :frame, binary}, :initializing, data) do
  case Jason.decode(binary) do
    {:ok, json} ->
      handle_init_response(json, data)

    {:error, reason} ->
      Logger.warning("Invalid JSON in initializing: #{inspect(reason)}")
      :ok = Transport.set_active(data.transport, :once)
      {:keep_state_and_data, []}
  end
end

defp handle_init_response(%{"id" => 0, "result" => result}, data) do
  case validate_capabilities(result) do
    :ok ->
      server_caps = result["capabilities"]
      data = %{data |
        server_caps: server_caps,
        session_id: data.session_id + 1,
        backoff_delay: data.backoff_min
      }

      # Send initialized notification
      notif = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      :ok = Transport.send_frame(data.transport, Jason.encode!(notif))
      :ok = Transport.set_active(data.transport, :once)

      # Schedule tombstone sweep
      sweep_action = {:state_timeout, data.tombstone_sweep_ms, :tombstone_sweep}
      {:next_state, :ready, data, [sweep_action]}

    {:error, reason} ->
      Logger.error("Invalid capabilities: #{reason}")
      Transport.close(data.transport)  # NO set_active
      {:next_state, :backoff, data, schedule_backoff_action(data)}
  end
end

defp handle_init_response(_other, data) do
  # Unexpected response shape
  Logger.warning("Unexpected init response")
  :ok = Transport.set_active(data.transport, :once)
  {:keep_state_and_data, []}
end

defp validate_capabilities(%{"protocolVersion" => @protocol_version}) do
  :ok
end

defp validate_capabilities(%{"protocolVersion" => other}) do
  {:error, "Unsupported version: #{other}"}
end

defp validate_capabilities(_) do
  {:error, "Missing protocolVersion"}
end
```

### 5. Implement :initializing State - timeouts and failures

```elixir
def handle_event(:state_timeout, :init_timeout, :initializing, data) do
  Logger.error("Initialize timeout")
  Transport.close(data.transport)
  {:next_state, :backoff, data, schedule_backoff_action(data)}
end

def handle_event(:info, {:transport, :down, reason}, :initializing, data) do
  Logger.error("Transport down during init: #{inspect(reason)}")
  {:next_state, :backoff, data, schedule_backoff_action(data)}
end

def handle_event({:call, from}, :stop, :initializing, data) do
  Transport.close(data.transport)
  {:stop_and_reply, :normal, [{:reply, from, :ok}]}
end
```

### 6. Add Helper Functions

```elixir
defp schedule_backoff_action(data) do
  delay = data.backoff_delay
  new_delay = min(data.backoff_delay * 2, data.backoff_max)
  data = %{data | backoff_delay: new_delay}
  {data, [{:state_timeout, delay, :reconnect}]}
end
```

---

## Test File: test/mcp_client/connection_test.exs

Add these tests to the existing file:

```elixir
describe ":starting state" do
  test "spawns transport and transitions to initializing" do
    {:ok, pid} = Connection.start_link(transport: :mock)

    # Should transition to :initializing
    # (Actual test will need to introspect state - for now verify process alive)
    assert Process.alive?(pid)

    :gen_statem.stop(pid)
  end

  test "handles stop in starting state" do
    {:ok, pid} = Connection.start_link(transport: :mock)
    assert :ok = :gen_statem.call(pid, :stop)
    refute Process.alive?(pid)
  end
end

describe ":initializing state" do
  setup do
    {:ok, pid} = Connection.start_link(transport: :mock)
    # Wait for transition to initializing
    Process.sleep(10)
    {:ok, connection: pid}
  end

  test "sends initialize on transport_up", %{connection: conn} do
    # Send transport_up
    send(conn, {:transport, :up})

    # Should send initialize request
    # (Verify via mock transport tracker - to be implemented)
    assert Process.alive?(conn)
  end

  test "validates protocol version", %{connection: conn} do
    send(conn, {:transport, :up})
    Process.sleep(10)

    # Send invalid version
    response = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "result" => %{
        "protocolVersion" => "1999-01-01",
        "capabilities" => %{}
      }
    }

    send(conn, {:transport, :frame, Jason.encode!(response)})

    # Should transition to backoff (verify via state introspection)
    Process.sleep(10)
    # For now, just verify no crash
    assert Process.alive?(conn)
  end

  test "transitions to ready on valid init response", %{connection: conn} do
    send(conn, {:transport, :up})
    Process.sleep(10)

    # Send valid response
    response = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{
          "tools" => %{}
        },
        "serverInfo" => %{
          "name" => "test-server",
          "version" => "1.0.0"
        }
      }
    }

    send(conn, {:transport, :frame, Jason.encode!(response)})

    # Should transition to ready
    Process.sleep(10)
    assert Process.alive?(conn)
  end

  test "handles oversized frame", %{connection: conn} do
    send(conn, {:transport, :up})
    Process.sleep(10)

    # Send 17MB frame
    huge_frame = :binary.copy(<<0>>, 17_000_000)
    send(conn, {:transport, :frame, huge_frame})

    # Should transition to backoff
    Process.sleep(10)
    assert Process.alive?(conn)
  end

  test "handles decode errors", %{connection: conn} do
    send(conn, {:transport, :up})
    Process.sleep(10)

    # Send invalid JSON
    send(conn, {:transport, :frame, "not json {{"})

    # Should stay in initializing and set_active
    Process.sleep(10)
    assert Process.alive?(conn)
  end

  test "handles init timeout", %{connection: conn} do
    send(conn, {:transport, :up})

    # Don't send response - let it timeout
    # Default init_timeout is 10_000ms, too long for test
    # (Will need to make configurable or use shorter timeout)

    # For now, trigger timeout manually
    send(conn, {:state_timeout, :init_timeout})

    # Should transition to backoff
    Process.sleep(10)
    assert Process.alive?(conn)
  end

  test "handles transport down", %{connection: conn} do
    send(conn, {:transport, :up})
    Process.sleep(10)

    send(conn, {:transport, :down, :normal})

    # Should transition to backoff
    Process.sleep(10)
    assert Process.alive?(conn)
  end

  test "handles stop in initializing", %{connection: conn} do
    send(conn, {:transport, :up})
    Process.sleep(10)

    assert :ok = :gen_statem.call(conn, :stop)
    refute Process.alive?(conn)
  end
end
```

---

## Mock Transport Module

For testing, create a minimal mock transport:

```elixir
# test/support/mock_transport.ex
defmodule McpClient.MockTransport do
  @behaviour McpClient.Transport

  def start_link(_opts) do
    pid = spawn(fn -> :timer.sleep(:infinity) end)
    {:ok, pid}
  end

  def send_frame(_pid, _frame) do
    :ok
  end

  def set_active(_pid, _mode) do
    :ok
  end

  def close(_pid) do
    :ok
  end
end
```

**Note**: Full Transport behavior definition comes in later prompts.

---

## Success Criteria

Run tests with:
```bash
mix test test/mcp_client/connection_test.exs
```

**Must achieve:**
- ✅ All tests pass (green)
- ✅ No warnings
- ✅ No compilation errors
- ✅ State transitions work correctly
- ✅ Capability validation works
- ✅ Backoff scheduling works

---

## Constraints

- **DO NOT** implement :backoff or :ready state logic yet
- **DO NOT** add features not in the state table
- **DO NOT** skip the init→set_active ordering
- **DO NOT** call set_active after close
- Use exact protocol version "2024-11-05"
- Use exact max frame size 16,777,216 bytes

---

## Implementation Notes

### Transport Module Dependency

The real Transport behavior and implementations will be created in later prompts. For now:
- Use MockTransport for testing
- Assume Transport.send_frame/2, set_active/2, close/1 exist
- Assume transport sends {:transport, :up}, {:transport, :frame, binary}, {:transport, :down, reason}

### Data Structure Fields Needed

From Prompt 01, these fields are already in the struct:
- `transport` - will hold transport PID
- `session_id` - bump on each successful init
- `server_caps` - store result["capabilities"]
- `backoff_delay` - current backoff time
- `backoff_min` - reset target (1000ms)
- `backoff_max` - ceiling (30000ms)

### Configuration

Add to init/1 if not already present:
```elixir
init_timeout: opts[:init_timeout] || 10_000
tombstone_sweep_ms: opts[:tombstone_sweep_ms] || 60_000
```

---

## Deliverable

Provide the updated `lib/mcp_client/connection.ex` and test support files that:
1. Implement :starting and :initializing states exactly per spec
2. Pass all tests
3. Compile without warnings
4. Follow the state transition table precisely
5. Respect the set_active ordering invariant

If any requirement is unclear, insert `# TODO: <reason>` and stop.
