# 3. Inline Request Tracking in Connection State (No Separate Manager)

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

The MCP client must track pending JSON-RPC requests, correlate responses by ID, and manage per-request timeouts. This tracking requires storing request metadata (caller PID, method, timeout reference) and providing fast lookup by request ID.

A separate RequestManager GenServer would add an extra process and message hops for every request/response, increasing latency and scheduler overhead.

## Decision Drivers

- Minimize message hops in request/response hot path
- Avoid shared mutable state complexity (separate ETS ownership)
- Keep request lifecycle tightly coupled to connection lifecycle
- Simplify supervision tree for MVP
- Bounded request volume expected in MVP (< 100 concurrent)
- Timer management must be deterministic

## Considered Options

**Option 1: Separate RequestManager GenServer**
- Dedicated process managing ETS table
- Connection sends messages to manager for tracking
- Extra hops: Connection → RequestManager → ETS

**Option 2: ETS owned by Connection**
- Connection owns `:protected` or `:public` ETS table
- Direct ETS operations in Connection callbacks
- Timer refs stored in ETS

**Option 3: Plain map in Connection state**
- Requests stored in gen_statem data map
- No ETS dependency
- Timers managed via `:state_timeout` actions

## Decision Outcome

Chosen option: **Plain map in Connection state (Option 3)**, because:

1. **Zero extra hops**: Request tracking is inline in Connection's handle_event
2. **Simpler lifecycle**: Request map lifetime exactly matches Connection lifetime (no ETS cleanup on crash)
3. **Deterministic timers**: Each request stores its own `:erlang.send_after/3` timer reference, so we can cancel/retry without racing over the single gen_statem `:state_timeout`
4. **Less code**: No RequestManager module, no ETS setup/teardown
5. **Sufficient for MVP**: Expected concurrency << 1000; map performance is adequate

### Implementation Details

**Request map structure:**
```elixir
%{
  request_id => %{
    from: {pid(), reference()},       # GenServer reply target
    timer_ref: reference(),            # send_after reference (per request)
    retry_ref: reference() | nil,      # send_after reference for busy retry (if armed)
    started_at_mono: integer(),        # System.monotonic_time()
    method: String.t(),                # For telemetry/logging
    session_id: non_neg_integer()      # For stale response filtering
  }
}
```

**Stored in Connection state:**
```elixir
defmodule McpClient.Connection do
  defstruct [
    :transport,
    :session_id,
    :server_caps,
    requests: %{},         # ← Inline storage
    tombstones: %{},
    backoff_delay: 1000
  ]
end
```

**Request ID generation:**
```elixir
defp next_id(), do: System.unique_integer([:positive, :monotonic])
```

**Timeout via gen_statem actions:**
```elixir
def handle_event({:call, from}, {:call_tool, name, args, opts}, :ready, data) do
  id = next_id()
  timeout = opts[:timeout] || @default_timeout

  request = %{
    from: from,
    started_at_mono: System.monotonic_time(),
    method: "tools/call",
    session_id: data.session_id
  }

  data = put_in(data.requests[id], request)
  timer_ref = :erlang.send_after(timeout, self(), {:req_timeout, id})
  request = Map.put(request, :timer_ref, timer_ref)

  case send_frame(data.transport, encode_request(id, name, args)) do
    :ok ->
      data = put_in(data.requests[id], request)
      {:keep_state, data, []}

    {:error, reason} ->
      {:keep_state, delete_request(data, id), [{:reply, from, {:error, reason}}]}
  end
end
```

Timeout handling now lands in the regular `:info` callback:

```elixir
def handle_event(:info, {:req_timeout, id}, :ready, data) do
  case Map.pop(data.requests, id) do
    {nil, _requests} ->
      {:keep_state_and_data, []}  # Already resolved

    {request, requests} ->
      :erlang.cancel_timer(request.timer_ref)
      send_client_cancel(id)
      error = %Error{type: :timeout, message: "request timed out"}
      GenServer.reply(request.from, {:error, error})
      data = %{data | requests: requests}
      {:keep_state, data, []}
  end
end
```

### Consequences

**Positive:**
- Minimal latency: no extra processes in request path
- Simple lifecycle: map cleared on Connection restart
- Easy debugging: all state in one process (no distributed state)
- Timers tied to gen_statem lifecycle (automatic cleanup)
- Less code to maintain

**Negative/Risks:**
- Map operations scale O(log N); could become bottleneck at high concurrency (> 1000 requests)
- Entire request map serialized with Connection state (not concurrent)
- No cross-process inspection of pending requests (would need ETS)

**Neutral:**
- Refactor path to ETS is straightforward if needed post-MVP
- Tombstone map also inline (acceptable for MVP)

## Deferred Alternatives

**ETS-based tracking with concurrent reads**: Post-MVP, if request volume exceeds ~500 concurrent, migrate to `:protected` ETS table owned by Connection. This would allow:
- Concurrent reads from diagnostic/telemetry processes
- Better performance under high load
- Preserved semantics (still owned by Connection, cleared on restart)

Deferred because MVP does not require this scale.

## References

- Design Document 02 (gpt5.md), Section 3: "Request manager is doing too much"
- Design Document 08 (gpt5.md), Section 6: "Request tracking: map vs ETS matters"
- Design Document 10 (final spec), Section 6: "Request map shape (locked)"
