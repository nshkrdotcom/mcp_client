# Implementation Prompt 01: Connection GenStatem Scaffold

**Goal:** Create the `McpClient.Connection` module skeleton with data structure, callback mode, and init function. No state logic yet.

**Test Strategy:** Basic compilation and initialization tests pass. All tests green, no warnings.

---

## Context: What You're Building

You're implementing the core Connection module for an MCP (Model Context Protocol) client library in Elixir. This module uses OTP's `gen_statem` behavior to manage connection lifecycle through explicit states.

---

## Complete Specification

### States (from STATE_TRANSITIONS.md)

The state machine has 5 states:

| State | Description |
|-------|-------------|
| `:starting` | Initial state; spawning/attaching transport |
| `:initializing` | MCP initialize handshake in progress; initialize request sent |
| `:ready` | Normal operation; can process requests |
| `:backoff` | Exponential backoff; reconnection scheduled; transport inactive |
| `:closing` | Graceful shutdown in progress; no new operations accepted |

### Data Structure (from ADR-0003 and STATE_TRANSITIONS.md)

```elixir
%{
  transport: pid() | nil,
  session_id: non_neg_integer(),
  session_mode: :required | :optional,
  tool_modes: %{String.t() => :stateful | :stateless},
  server_caps: map() | nil,
  requests: %{id => %{from, started_at_mono, timeout, method, corr_id}},
  retries: %{id => %{frame, from, request, attempts}},
  tombstones: %{id => %{inserted_at_mono, ttl_ms}},
  backoff_delay: non_neg_integer(),
  backoff_min: non_neg_integer(),
  backoff_max: non_neg_integer(),
  tombstone_ttl_ms: non_neg_integer(),
  max_frame_bytes: non_neg_integer(),
  notification_handlers: [function()]
}
```

`session_mode` defaults to `:optional` and flips to `:required` once a stateful tool appears. `tool_modes` caches the server’s `mode` declarations so later prompts can make dispatch decisions without re-querying.

> **Note:** ADR-0013 documents the future pluggable state-store/registry adapter layer. For this prompt (and the entire MVP), continue to use the in-process maps defined above; the adapter boundary will be added post-MVP without changing the struct.

### Configuration Defaults (from MVP_SPEC.md)

```elixir
@defaults [
  request_timeout: 30_000,
  init_timeout: 10_000,
  backoff_min: 1_000,
  backoff_max: 30_000,
  max_frame_bytes: 16_777_216,  # 16MB
  retry_attempts: 3,
  retry_delay_ms: 10,
  retry_jitter: 0.5,
  tombstone_sweep_ms: 60_000
]
```

**Tombstone TTL Formula:**
```elixir
tombstone_ttl_ms = request_timeout + init_timeout + backoff_max + 5_000
# Default: 30,000 + 10,000 + 30,000 + 5,000 = 75 seconds
```

---

## Implementation Requirements

### File: `lib/mcp_client/connection.ex`

Create a module with:

1. **Module declaration and behavior**
   ```elixir
   defmodule McpClient.Connection do
     @behaviour :gen_statem
     require Logger
   ```

2. **Data structure as defstruct**
   - Include all fields listed above
   - Set sensible defaults where applicable

3. **Callback mode**
   ```elixir
   @impl true
   def callback_mode, do: :handle_event_function
   ```

4. **start_link/1**
   ```elixir
   def start_link(opts) do
     name = opts[:name]
     :gen_statem.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
   end
   ```

5. **init/1**
   - Seed `:rand` with `{node(), self(), System.monotonic_time()}`
   - Build data struct from opts with defaults
   - Calculate `tombstone_ttl_ms` from timeout values
   - Return `{:ok, :starting, data, [{:next_event, :internal, {:spawn_transport, opts}}]}`

6. **Stub handle_event/4 for each state**
   - `:starting` → empty clause, returns `:keep_state_and_data`
   - `:initializing` → empty clause
   - `:ready` → empty clause
   - `:backoff` → empty clause
   - `:closing` → empty clause
   - Catch-all that logs unexpected events

---

## Constraints

- **DO NOT** implement any state logic yet
- **DO NOT** add helper functions yet
- **DO NOT** add features not mentioned above
- Use `Logger.warn/1` for unexpected events in catch-all
- All fields in struct must match specification exactly

---

## Test File: `test/mcp_client/connection_test.exs`

Create basic tests:

```elixir
defmodule McpClient.ConnectionTest do
  use ExUnit.Case, async: true
  alias McpClient.Connection

  describe "init/1" do
    test "initializes with default configuration" do
      opts = [transport: :stdio, command: "test"]
      assert {:ok, :starting, data, _actions} = Connection.init(opts)

      # Verify data structure
      assert data.backoff_min == 1_000
      assert data.backoff_max == 30_000
      assert data.backoff_delay == 1_000
      assert data.max_frame_bytes == 16_777_216
      assert data.tombstone_ttl_ms == 75_000
      assert data.requests == %{}
      assert data.retries == %{}
      assert data.tombstones == %{}
      assert data.session_id == 0
    end

    test "accepts custom timeouts" do
      opts = [
        transport: :stdio,
        request_timeout: 60_000,
        init_timeout: 20_000,
        backoff_max: 60_000
      ]

      {:ok, :starting, data, _} = Connection.init(opts)

      # Custom TTL: 60k + 20k + 60k + 5k = 145k
      assert data.tombstone_ttl_ms == 145_000
      assert data.backoff_max == 60_000
    end

    test "seeds random generator" do
      Connection.init([transport: :stdio])

      # Verify :rand is seeded by generating values
      val1 = :rand.uniform()
      val2 = :rand.uniform()
      assert val1 != val2  # Should be random
    end
  end

  describe "start_link/1" do
    test "starts process without name" do
      {:ok, pid} = Connection.start_link(transport: :mock)
      assert Process.alive?(pid)
      :gen_statem.stop(pid)
    end

    test "starts process with name" do
      {:ok, pid} = Connection.start_link(transport: :mock, name: TestConnection)
      assert Process.whereis(TestConnection) == pid
      :gen_statem.stop(pid)
    end
  end

  describe "callback_mode/0" do
    test "returns handle_event_function" do
      assert Connection.callback_mode() == :handle_event_function
    end
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
- ✅ No compilation errors
- ✅ Process can start and stop cleanly

---

## Implementation Notes

- The `:next_event` action in init will trigger the `:starting` state immediately
- We're not handling that event yet (that's next prompt)
- Focus is on correct data structure and initialization
- Time units: `backoff_delay` in milliseconds, `started_at_mono` will be native time units

---

## Deliverable

Provide the complete `lib/mcp_client/connection.ex` file that:
1. Compiles without warnings
2. Passes all tests
3. Matches the specification exactly
4. Contains NO additional features

If any requirement is unclear, insert `# TODO: <reason>` and stop.
