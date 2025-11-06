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
| **io** | I/O events (transport messages) | `{:info, {:transport, :frame, ...}}` |
| **int** | Internal events (timers, state actions) | `{:state_timeout, ...}`, `{:internal, ...}` |

---

## Complete Transition Table

### `:starting` State

| Event | Guard/Notes | Action | Next State |
|-------|-------------|--------|------------|
| `{:internal, {:spawn_transport, opts}}` | - | Spawn transport; set active(:once); arm init timeout | `:initializing` |
| `{:internal, {:spawn_error, reason}}` | - | Log error; schedule backoff (1st attempt) | `:backoff` |
| `{:call, from, :stop}` | - | Reply `{:ok, :ok}`; exit(normal) | `:closing` |
| `{:call, from, _any_user_call}` | - | Reply `{:error, %Error{kind: :state, data: %{state: :starting}}}` | `:starting` |

---

### `:initializing` State

| Event | Guard/Notes | Action | Next State |
|-------|-------------|--------|------------|
| `{:info, {:transport, :frame, binary}}` | `byte_size > max_frame_bytes` | Log error; close transport; schedule backoff | `:backoff` |
| `{:info, {:transport, :frame, binary}}` | Valid init response, caps valid | Store caps; bump session_id; reply "initialized"; arm tombstone sweep | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Valid init response, caps **invalid** | Log warn; schedule backoff | `:backoff` |
| `{:info, {:transport, :frame, binary}}` | Init error response | Log error; schedule backoff | `:backoff` |
| `{:info, {:transport, :frame, binary}}` | Other (not init response) | Drop frame; set_active(:once) | `:initializing` |
| `{:state_timeout, :init_timeout}` | - | Log timeout; schedule backoff | `:backoff` |
| `{:info, {:transport, :down, reason}}` | - | Log reason; schedule backoff | `:backoff` |
| `{:call, from, :stop}` | - | Reply `{:ok, :ok}`; close transport | `:closing` |
| `{:call, from, _any_user_call}` | - | Reply `{:error, %Error{kind: :state, data: %{state: :initializing}}}` | `:initializing` |

**Capability validation (guard):**
```elixir
def valid_caps?(caps) do
  is_map(caps) and
  is_binary(caps["protocolVersion"]) and
  compatible_version?(caps["protocolVersion"])
end

defp compatible_version?(v), do: String.starts_with?(v, "2024-11")
```

---

### `:ready` State

| Event | Guard/Notes | Action | Next State |
|-------|-------------|--------|------------|
| `{:info, {:transport, :frame, binary}}` | `byte_size > max_frame_bytes` | Log error; close transport; tombstone all; schedule backoff | `:backoff` |
| `{:info, {:transport, :frame, binary}}` | Response; ID in `requests` | Deliver to caller; cancel timeout; delete request; set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Response; ID in `tombstones` | Drop (stale response); set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Response; ID unknown | Warn + drop; set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Server notification (reset method) | Tombstone all requests; clear requests; start init | `:initializing` |
| `{:info, {:transport, :frame, binary}}` | Server notification (other) | Dispatch to handlers (sync); set_active(:once) | `:ready` |
| `{:info, {:transport, :frame, binary}}` | Server request | Handle server request (future); set_active(:once) | `:ready` |
| `{:info, {:transport, :down, reason}}` | - | Tombstone all requests; clear requests; schedule backoff | `:backoff` |
| `{:state_timeout, {:request_timeout, id}}` | ID in `requests` | Cancel upstream (send `$/cancelRequest`); tombstone ID; reply timeout | `:ready` |
| `{:state_timeout, {:request_timeout, id}}` | ID not in `requests` | Ignore (already handled) | `:ready` |
| `{:state_timeout, :sweep_tombstones}` | - | Remove expired tombstones; reschedule sweep | `:ready` |
| `{:call, from, {:call_tool, name, args, opts}}` | - | Generate ID; store request; send frame (with retry); arm timeout | `:ready` (or error) |
| `{:call, from, {:list_resources, opts}}` | - | Same as above | `:ready` |
| `{:call, from, ...}` | Any other user call | Same pattern | `:ready` |
| `{:call, from, :stop}` | - | Reply `{:ok, :ok}`; fail all in-flight; tombstone all; close | `:closing` |
| `{:state_timeout, :retry_send}` | Retry state present; attempts < max | Retry send_frame; increment attempts; reschedule if still busy | `:ready` |
| `{:state_timeout, :retry_send}` | Retry state present; attempts >= max | Reply `{:error, :backpressure}`; clear retry state | `:ready` |

**Reset notification method (configurable):**
Default: `"notifications/cancelled"`

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

---

### `:backoff` State

| Event | Guard/Notes | Action | Next State |
|-------|-------------|--------|------------|
| `{:state_timeout, :backoff_expire}` | - | Attempt reconnect (spawn transport); start init | `:initializing` |
| `{:info, {:transport, :up}}` | - | Start init handshake | `:initializing` |
| `{:info, {:transport, :frame, _}}` | - | Drop (no guarantees in backoff) | `:backoff` |
| `{:info, {:transport, :down, _}}` | - | Ignore (already in backoff) | `:backoff` |
| `{:call, from, _any_user_call}` | - | Reply `{:error, %Error{kind: :state, data: %{state: :backoff}}}` | `:backoff` |
| `{:call, from, :stop}` | - | Reply `{:ok, :ok}`; close (if transport exists) | `:closing` |

**Backoff calculation:**
```elixir
next_delay = min(current_delay * 2, @backoff_max) |> jitter(0.2)

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
| `{:info, {:transport, :down, _}}` | - | Accelerate exit (stop immediately) | N/A |
| _any other event_ | - | Drop (already closing) | `:closing` |

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
      # Success - store request and arm timeout
      id = request.id
      data = put_in(data.requests[id], request)
      timeout = request.timeout || @default_timeout
      actions = [{:state_timeout, timeout, {:request_timeout, id}}]
      {:keep_state, data, actions}

    {:error, :busy} ->
      # Start retry sequence
      retry_state = %{
        id: request.id,
        frame: frame,
        from: from,
        request: request,
        attempts: 1
      }
      data = Map.put(data, :retry, retry_state)
      delay = jitter(@retry_delay_ms, @retry_jitter)
      actions = [{:state_timeout, delay, :retry_send}]
      {:keep_state, data, actions}

    {:error, reason} ->
      # Fatal error - fail immediately
      error = %Error{kind: :transport, message: "send failed: #{inspect(reason)}"}
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
    error = %Error{kind: :transport, message: "connection lost"}
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
# On request send
:telemetry.execute(
  [:mcp_client, :request, :start],
  %{system_time: System.system_time()},
  %{client: self(), method: method, id: id, corr_id: corr_id}
)

# On response
:telemetry.execute(
  [:mcp_client, :request, :stop],
  %{duration: System.monotonic_time() - start_time},
  %{client: self(), method: method, id: id, corr_id: corr_id}
)
```

---

## Invariants (Always True)

1. **Exactly one state at a time**: Process is always in one of 5 states
2. **No orphaned requests**: Every request in map has corresponding timeout
3. **Tombstones have TTL**: Every tombstone entry has `inserted_at` and `ttl`
4. **Transport active-once**: Transport never delivers frame unless `set_active(:once)` called
5. **One terminal outcome per request**: Each caller receives exactly one reply (success, error, or timeout)

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
