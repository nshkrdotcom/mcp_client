# Connection State Machine - Complete Transition Table

**Document Version:** 1.0.0
**Date:** 2025-11-06
**Status:** Locked for MVP Implementation

---

## Overview

This document provides the complete, authoritative state transition table for the MCP client `Connection` gen_statem. Every `(state, event)` combination is defined with its guard conditions, actions, and next state.

**Related ADRs:**
- ADR-0001: gen_statem for connection lifecycle
- ADR-0002: rest_for_one supervision strategy
- ADR-0009: Fail-fast graceful shutdown

---

## States

| State | Description |
|-------|-------------|
| `:starting` | Initial state; spawning/attaching transport |
| `:initializing` | MCP initialize handshake in progress |
| `:ready` | Normal operation; can process requests |
| `:backoff` | Exponential backoff; reconnection scheduled |
| `:closing` | Graceful shutdown in progress |

---

## Event Types

| Type | Description | Examples |
|------|-------------|----------|
| **ctl** | Control events (user calls, stop) | `{:call, from, ...}` |
| **io** | External messages (`:info`) | `{:info, {:transport, :frame, ...}}`, `{:info, {:req_timeout, id}}` |
| **int** | Internal events (`:state_timeout`, `:internal`) | `{:state_timeout, :init_timeout}`, `{:internal, ...}` |

**Timer invariant:** only one `:state_timeout` is armed at any time (`:init_timeout`, `:backoff_expire`, or `:sweep_tombstones`). All per-request timers use `:erlang.send_after/3` and arrive via `:info`.

**Active-once invariant:** Never call `Transport.set_active(:once)` while in `:backoff` or `:closing`; use the `set_active_once_safe/1` helper so late activations become no-ops in those states.

---

## Transport Message Contract

All transport implementations must send messages in these **exact shapes**:

```elixir
# Transport is ready to send/receive
{:transport, :up}

# Complete frame received (one JSON-RPC message)
{:transport, :frame, binary()}

# Transport closed or failed
{:transport, :down, reason :: term()}
```

**Requirements:**
- `:up` sent exactly once after successful initialization
- `:frame` sent only after Connection calls `Transport.set_active(transport, :once)`
- `:down` sent on any failure (connection closed, network error, etc.)
- Frames are **complete**: one binary = one JSON-RPC message (no partial frames)

See ADR-0002 and ADR-0004 for transport behavior specification.

---

## Complete Transition Table

### `:starting` State

| Event | Guard/Notes | Action | Next State |
|-------|-------------|--------|------------|
| `{:internal, {:spawn_transport, opts}}` | - | Spawn transport; wait for transport_up | `:initializing` |
| `{:internal, {:spawn_error, reason}}` | - | Log error; schedule backoff (1st attempt) | `:backoff` |
| `{:call, from, :stop}` | - | Reply `{:ok, :ok}`; exit(normal) | `:closing` |
| `{:call, from, _any_user_call}` | - | Reply `{:error, %Error{type: :state, data: %{state: :starting}}}` | `:starting` |

---

### `:initializing` State

| Event | Guard/Notes | Action | Next State |
|-------|-------------|--------|------------|
| `{:info, {:transport, :up}}` | - | Send `initialize` request **then** set_active(:once); arm init_timeout | `:initializing` |
| `{:info, {:transport, :frame, binary}}` | `byte_size > max_frame_bytes` | Log error; close transport (no set_active); schedule backoff | `:backoff` |
| `{:info, {:transport, :frame, binary}}` | Valid init response, caps valid | Store caps; bump session_id; **reset backoff_delay to backoff_min**; reply "initialized"; arm tombstone sweep; set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Valid init response, caps **invalid** | Log warn; close transport; schedule backoff | `:backoff` |
| `{:info, {:transport, :frame, binary}}` | Init error response | Log error; close transport; schedule backoff | `:backoff` |
| `{:info, {:transport, :frame, binary}}` | Invalid JSON | Log warn; set_active(:once) | `:initializing` |
| `{:info, {:transport, :frame, binary}}` | Other (not init response) | Drop frame; set_active(:once) | `:initializing` |
| `{:state_timeout, :init_timeout}` | - | Log timeout; close transport; schedule backoff | `:backoff` |
| `{:info, {:transport, :down, reason}}` | - | Log reason; schedule backoff | `:backoff` |
| `{:call, from, :stop}` | - | Reply `{:ok, :ok}`; close transport | `:closing` |
| `{:call, from, _any_user_call}` | - | Reply `{:error, %Error{type: :state, data: %{state: :initializing}}}` | `:initializing` |

**Capability validation (guard):**
```elixir
def valid_caps?(caps) do
  is_map(caps) and has_valid_version?(caps)
end

defp has_valid_version?(caps) do
  version = caps["protocolVersion"] || caps[:protocolVersion]
  is_binary(version) and compatible_version?(version)
end

# MVP policy: exact match only
defp compatible_version?("2024-11-05"), do: true
defp compatible_version?(_), do: false
```

**Notes:**
- Accepts both string and atom keys for caps to accommodate test transports
- Any version other than `"2024-11-05"` transitions to `:backoff` with a protocol error

---

### `:ready` State

| Event | Guard/Notes | Action | Next State |
|-------|-------------|--------|------------|
| `{:info, {:transport, :frame, binary}}` | `byte_size > max_frame_bytes` | Log error; close transport (no set_active); tombstone all requests; fail/clear retries; schedule backoff | `:backoff` |
| `{:info, {:transport, :frame, binary}}` | Response; ID in `requests` | Deliver to caller; cancel timeout; delete request; set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Response; ID in `tombstones` | Drop (stale response); set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Response; ID unknown | Log at debug; drop; set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Invalid JSON | Log warn; set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Server notification (other) | Dispatch to handlers (sync); set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Server request | Reply JSON-RPC error (-32601 method not found); log at debug; set_active(:once) | `:ready` |
| `{:info, {:transport, :down, reason}}` | - | Tombstone all requests; fail/clear retries; **do not re-arm set_active**; schedule backoff | `:backoff` |
| `{:info, {:req_timeout, id}}` | ID in `requests` | Send `$/cancelRequest` (single attempt, no retry); tombstone ID; reply timeout | `:ready` |
| `{:info, {:req_timeout, id}}` | ID not in `requests` | Ignore (already handled) | `:ready` |
| `{:state_timeout, :sweep_tombstones}` | - | Remove expired tombstones; reschedule sweep | `:ready` |
| `{:call, from, {:call_tool, name, args, opts}}` | - | Generate ID; send frame (with retry on :busy); store request or retry state; arm timeout | `:ready` |
| `{:call, from, {:list_resources, opts}}` | - | Same as above | `:ready` |
| `{:call, from, ...}` | Any other user call | Same pattern | `:ready` |
| `{:call, from, :stop}` | - | Reply `{:ok, :ok}`; fail all in-flight + retries; tombstone all; clear retries; close | `:closing` |
| `{:info, {:retry_send, id, frame}}` | ID in `retries`; attempts < max | Retry send_frame; on success: promote to request; on `{:error, :busy}`: increment attempts, reschedule | `:ready` |
| `{:info, {:retry_send, id, _frame}}` | ID in `retries`; attempts >= max | Reply `{:error, :backpressure}`; delete from retries | `:ready` |
| `{:info, {:retry_send, id, _frame}}` | ID not in `retries` | Ignore (cleared during stop) | `:ready` |

**Cancellation policy:**
- `$/cancelRequest` is sent as **single attempt, no retry**
- If send fails (`:busy` or transport down), skip—tombstone already prevents late response delivery
- Avoids re-ordering risks from retry logic on cancel messages

**Tombstone all requests:**
```elixir
defp tombstone_all_requests(data) do
  now = System.monotonic_time(:millisecond)
  tombstones = for {id, _req} <- data.requests, into: data.tombstones do
    {id, %{inserted_at_mono: now, ttl_ms: @tombstone_ttl_ms}}
  end

  %{data | tombstones: tombstones, requests: %{}}
end
```

**Fail and clear retries:**
```elixir
defp fail_and_clear_retries(data, error) do
  # Reply to all in-retry callers
  for {_id, %{from: from}} <- data.retries do
    GenServer.reply(from, {:error, error})
  end

  %{data | retries: %{}}
end
```

---

### `:backoff` State

| Event | Guard/Notes | Action | Next State |
|-------|-------------|--------|------------|
| `{:state_timeout, :backoff_expire}` | - | Attempt reconnect (spawn transport); start init | `:initializing` |
| `{:info, {:transport, :up}}` | - | Start init handshake | `:initializing` |
| `{:info, {:transport, :frame, _}}` | - | Drop (no set_active; transport inactive in backoff) | `:backoff` |
| `{:info, {:transport, :down, _}}` | - | Ignore (already in backoff) | `:backoff` |
| `{:call, from, _any_user_call}` | - | Reply `{:error, %Error{type: :state, data: %{state: :backoff}}}` | `:backoff` |
| `{:call, from, :stop}` | - | Reply `{:ok, :ok}`; close (if transport exists) | `:closing` |

**Note:** In `:backoff`, transport is inactive (no `set_active(:once)` calls). Frames should not arrive, but if they do (race), they are dropped.

**Backoff calculation:**
```elixir
next_delay =
  current_delay * 2
  |> jitter(0.2)
  |> min(@backoff_max)

# First backoff: 1000ms ± 20% → 800-1200ms
# Second: 2000ms ± 20% → 1600-2400ms
# Third: 4000ms ± 20% → 3200-4800ms
# ...
# Max: 30000ms ± 20% → 24000-36000ms (capped)
```

---

### `:closing` State

| Event | Guard/Notes | Action | Next State |
|-------|-------------|--------|------------|
| `{:state_timeout, :exit}` | - | `{:stop, :normal}` (exit process) | N/A |
| `{:call, from, :stop}` | - | Reply `{:ok, :already_closing}` (idempotent) | `:closing` |
| `{:info, {:retry_send, _id, _frame}}` | - | Drop silently (retries cleared on entering :closing) | `:closing` |
| `{:info, {:req_timeout, _id}}` | - | Drop silently (requests failed on entering :closing) | `:closing` |
| `{:info, {:transport, :down, _}}` | - | Accelerate exit (stop immediately) | N/A |
| `{:info, {:transport, :frame, _}}` | - | Drop (no set_active after close) | `:closing` |
| _any other event_ | - | Drop (already closing) | `:closing` |

**Note:** On entering `:closing`, all `requests` and `retries` are cleared and callers are notified. Subsequent timeout events for those IDs are safely ignored.

---

## Guard Functions

### Frame Size Check

```elixir
def oversized?(binary) do
  byte_size(binary) > @max_frame_bytes  # 16MB
end
```

### Capability Validation

```elixir
def valid_caps?(caps) do
  is_map(caps) and
  is_binary(caps["protocolVersion"]) and
  compatible_version?(caps["protocolVersion"])
end

defp compatible_version?("2024-11-05"), do: true
defp compatible_version?(<<"2024-11", _rest::binary>>), do: true
defp compatible_version?(_), do: false
```

### Request Lookup

```elixir
def request_exists?(data, id), do: Map.has_key?(data.requests, id)
def tombstoned?(data, id) do
  case Map.get(data.tombstones, id) do
    %{inserted_at_mono: inserted, ttl_ms: ttl} ->
      System.monotonic_time(:millisecond) - inserted < ttl
    nil -> false
  end
end
```

---

## Actions (Common Patterns)

### Schedule Backoff

```elixir
defp schedule_backoff(data) do
  next_delay = min(data.backoff_delay * 2, @backoff_max) |> jitter(0.2)
  data = %{data | backoff_delay: next_delay}
  actions = [{:state_timeout, next_delay, :backoff_expire}]
  {data, actions}
end
```

### Send Frame with Retry

```elixir
defp send_with_retry(transport, frame, data, from, request) do
  case Transport.send_frame(transport, frame) do
    :ok ->
      # Success - store request and arm timeout via send_after
      id = request.id
      timeout = request.timeout || @default_timeout
      timer_ref = :erlang.send_after(timeout, self(), {:req_timeout, id})
      req_entry = %{request | timer_ref: timer_ref}
      data = put_in(data.requests[id], req_entry)
      {:keep_state, data, []}

    {:error, :busy} ->
      # Start retry sequence
      retry_state = %{
        id: request.id,
        frame: frame,
        from: from,
        request: request,
        attempts: 1
      }
      delay = jitter(@retry_delay_ms, @retry_jitter)
      retry_ref = :erlang.send_after(delay, self(), {:retry_send, request.id, frame})
      retry_state = Map.put(retry_state, :timer_ref, retry_ref)
      data = put_in(data.retries[request.id], retry_state)
      {:keep_state, data, []}

    {:error, reason} ->
      # Fatal error - fail immediately
      error = %Error{type: :transport, message: "send failed: #{inspect(reason)}"}
      {:keep_state, data, [{:reply, from, {:error, error}}]}
  end
end
```

### Tombstone All Requests

```elixir
defp tombstone_all_requests(data) do
  now = System.monotonic_time(:millisecond)

  tombstones = for {id, _req} <- data.requests, into: data.tombstones do
    {id, %{inserted_at_mono: now, ttl_ms: @tombstone_ttl_ms}}
  end

  # Fail all in-flight callers
  for {_id, %{from: from}} <- data.requests do
    error = %Error{type: :transport, message: "connection lost"}
    GenServer.reply(from, {:error, error})
  end

  %{data | tombstones: tombstones, requests: %{}}
end
```

### Clean Tombstones

```elixir
defp clean_tombstones(data) do
  now = System.monotonic_time(:millisecond)

  tombstones = Map.reject(data.tombstones, fn {_id, tomb} ->
    now - tomb.inserted_at_mono > tomb.ttl_ms
  end)

  %{data | tombstones: tombstones}
end
```

---

## Telemetry Emission

### State Transitions

```elixir
defp emit_transition(from, to, reason) do
  :telemetry.execute(
    [:mcp_client, :connection, :transition],
    %{},
    %{from: from, to: to, reason: reason}
  )
end
```

### Request Start/Stop

```elixir
# On request send (store start time in request)
request = %{
  from: from,
  started_at_mono: System.monotonic_time(),  # ← For duration calculation
  ...
}

:telemetry.execute(
  [:mcp_client, :request, :start],
  %{system_time: System.system_time()},  # Wall-clock for logs
  %{client: self(), method: method, id: id, corr_id: corr_id}
)

# On response (retrieve from request map)
%{started_at_mono: start_time} = request
duration = System.monotonic_time() - start_time  # Monotonic for accuracy

:telemetry.execute(
  [:mcp_client, :request, :stop],
  %{duration: duration},  # Native time units
  %{client: self(), method: method, id: id, corr_id: corr_id}
)
```

**Note:** Use `System.monotonic_time()` for duration calculation (immune to clock adjustments). Use `System.system_time()` only for wall-clock timestamps in logs/telemetry.

---

## Invariants (Always True)

1. **Exactly one state at a time**: Process is always in one of 5 states
2. **No orphaned requests**: Every request in map has corresponding timeout; every retry in map will eventually complete or be cleared
3. **Tombstones have TTL**: Every tombstone entry has `inserted_at_mono` and `ttl_ms`
4. **Transport active-once**: Transport never delivers frame unless `set_active(:once)` called; in `:backoff` and `:closing`, `set_active` is not called
5. **One terminal outcome per request**: Each caller receives exactly one reply (success, error, or timeout)
6. **Time source consistency**:
   - **Monotonic time (native)** (`System.monotonic_time()`) for request durations and timeout actions
   - **Monotonic time (millisecond)** (`System.monotonic_time(:millisecond)`) for tombstone TTL and backoff calculations
   - **System time** (`System.system_time()`) only for telemetry event wall-clock timestamps
   - Never mix units: comparisons only within same unit; convert at boundaries if needed
7. **No set_active after close**: When oversized frame triggers close, or stop is called, `set_active(:once)` is never called after `Transport.close/1`

---

## Testing the State Machine

### Property: All transitions defined

```elixir
test "all state/event combinations are handled" do
  for state <- [:starting, :initializing, :ready, :backoff, :closing],
      event <- all_possible_events() do
    # Verify handle_event/4 has clause for (event, state)
    # Should not raise FunctionClauseError
  end
end
```

### Property: No state leaks

```elixir
property "state machine always reaches terminal state" do
  check all events <- list_of(event_generator()) do
    # Apply sequence of events
    # Verify eventually reaches :closing or :ready
    # Verify no infinite loops
  end
end
```

---

## Example Sequence Diagrams

### Successful Request

```
State: :ready
  ↓ User calls call_tool
  ↓ Generate ID, store request
  ↓ Send frame (success)
  ↓ Arm timeout
State: :ready (waiting)
  ↓ Response arrives
  ↓ Match ID in requests
  ↓ Deliver to caller
  ↓ Cancel timeout
  ↓ Delete request
State: :ready
```

### Request Timeout

```
State: :ready
  ↓ User calls call_tool
  ↓ Generate ID, store request
  ↓ Send frame
  ↓ Arm timeout (30s)
State: :ready (waiting)
  ↓ ... 30 seconds ...
  ↓ Timeout fires
  ↓ Send $/cancelRequest
  ↓ Tombstone ID
  ↓ Reply {:error, :timeout}
State: :ready
```

### Transport Failure

```
State: :ready
  ↓ 5 in-flight requests
  ↓ Transport dies
  ↓ {:transport, :down, reason}
  ↓ Tombstone all 5 IDs
  ↓ Reply error to all 5 callers
  ↓ Clear requests map
  ↓ Schedule backoff
State: :backoff
  ↓ ... exponential delay ...
  ↓ Backoff expires
  ↓ Spawn new transport
State: :initializing
  ↓ Init handshake
State: :ready
```

---

## References

- ADR-0001: gen_statem for connection lifecycle
- ADR-0002: rest_for_one supervision strategy
- ADR-0003: Inline request tracking
- ADR-0004: Active-once backpressure
- ADR-0005: Global tombstone TTL
- ADR-0007: Bounded send retry
- ADR-0008: 16MB frame size limit
- ADR-0009: Fail-fast graceful shutdown
- MVP_SPEC.md: Complete specification

---

**Version History:**
- 1.0.0 (2025-11-06): Initial locked table for MVP
