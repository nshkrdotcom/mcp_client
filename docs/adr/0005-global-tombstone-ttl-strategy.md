# 5. Global Tombstone TTL Strategy

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

When a request times out or is cancelled, the MCP client must prevent late responses from being delivered to the wrong caller or causing unexpected behavior. "Tombstones" (records of cancelled request IDs) prevent this, but they consume memory and must eventually expire.

The challenge: responses can arrive very late if the network is partitioned, the server is slow, or the connection is in backoff. A too-short TTL allows stale responses through; a too-long TTL wastes memory.

## Decision Drivers

- Correctness: never deliver stale responses
- Memory bounds: tombstones must not grow unbounded
- Handle worst-case: network partition during backoff
- Per-request timeout overrides complicate TTL calculation
- Simplicity for MVP (avoid per-tombstone logic)

## Considered Options

**Option 1: Fixed 60-second TTL**
- All tombstones expire after 60s
- Simple but arbitrary

**Option 2: Per-request TTL based on actual timeout**
- Each tombstone stores its own expiry: `inserted_at + request_timeout + backoff_window`
- Correct but complex

**Option 3: Global TTL from configuration defaults**
- One formula covering worst-case latency
- Ignore per-call timeout overrides
- Formula: `request_timeout + init_timeout + backoff_max + epsilon`

## Decision Outcome

Chosen option: **Global TTL from configuration defaults (Option 3)**, because:

1. **Covers worst-case**: Request times out, connection immediately enters backoff, waits max backoff, then re-initializes
2. **Simple implementation**: Single TTL value, no per-tombstone calculation
3. **Bounded memory**: All tombstones expire after fixed window
4. **Acceptable trade-off**: Per-request timeout overrides don't extend tombstone lifetime (rare edge case)

### Implementation Details

**Formula:**
```elixir
@tombstone_ttl_ms (
  Application.get_env(:mcp_client, :request_timeout, 30_000) +
  Application.get_env(:mcp_client, :init_timeout, 10_000) +
  Application.get_env(:mcp_client, :backoff_max, 30_000) +
  5_000  # epsilon for jitter/clock skew
)
# Default: 30s + 10s + 30s + 5s = 75 seconds
```

**Rationale for each term:**
- `request_timeout`: Maximum time before request is cancelled
- `init_timeout`: Connection may re-initialize after timeout
- `backoff_max`: Connection may wait at maximum backoff before reconnecting
- `5_000`: Buffer for jitter (backoff has ±20% jitter) and monotonic clock granularity

**Tombstone structure:**
```elixir
%{
  request_id => %{
    inserted_at_mono: integer(),  # System.monotonic_time()
    ttl_ms: @tombstone_ttl_ms
  }
}
```

**Cleanup strategy (periodic sweep):**
```elixir
# In Connection gen_statem
def handle_event(:state_timeout, :sweep_tombstones, state, data) do
  now = System.monotonic_time(:millisecond)
  tombstones = Map.reject(data.tombstones, fn {_id, tomb} ->
    now - tomb.inserted_at_mono > tomb.ttl_ms
  end)

  actions = [{:state_timeout, 60_000, :sweep_tombstones}]  # Repeat every 60s
  {:keep_state, %{data | tombstones: tombstones}, actions}
end
```

**Lookup includes TTL check:**
```elixir
defp tombstoned?(id, tombstones) do
  case Map.get(tombstones, id) do
    %{inserted_at_mono: inserted, ttl_ms: ttl} ->
      System.monotonic_time(:millisecond) - inserted < ttl
    nil -> false
  end
end
```

### Consequences

**Positive:**
- Simple: one TTL value for all tombstones
- Correct for default configuration
- Covers worst-case latency window
- Memory bounded: old tombstones are swept every 60s
- No per-request bookkeeping

**Negative/Risks:**
- Per-call timeout overrides (e.g., `timeout: 120_000`) don't extend tombstone lifetime
  - If a request uses 120s timeout but tombstone expires at 75s, a response at T+90s could theoretically arrive after tombstone expiry
  - Mitigated by: responses after full backoff cycle are always stale/invalid anyway
- Global formula may over-retain tombstones for fast requests (small memory waste)

**Neutral:**
- Tombstones are checked on every response lookup (cheap map operation)
- Sweep runs every 60s (low overhead)

## Edge Case: Per-Request Timeout Overrides

If a user calls:
```elixir
McpClient.call_tool(client, "slow_op", %{}, timeout: 120_000)
```

The tombstone will still expire after **75 seconds** (global TTL), not 120 seconds.

**Why this is acceptable:**
1. By the time the tombstone expires, the connection has likely reconnected (max backoff is 30s)
2. Responses arriving after a full backoff+reconnect cycle are stale (different session)
3. Post-MVP session IDs will provide absolute stale-response protection (see Deferred Alternatives)

**Documented limitation:**
> Tombstones use a global TTL calculated from default timeouts. Per-call timeout overrides do not extend tombstone lifetime. Responses arriving extremely late (> 75s after cancellation) during extended network partitions may bypass tombstone filtering. Use default timeouts for critical operations, or wait for post-MVP session ID support.

## Deferred Alternatives

**Session ID gating (post-MVP)**: Track a `session_id` that increments on every successful initialization. Each request stores the session ID, and responses are validated against the current session:

```elixir
def handle_event(:info, {:response, id, result}, :ready, data) do
  case Map.get(data.requests, id) do
    %{session_id: req_session} when req_session == data.session_id ->
      # Valid response from current session
      deliver(result)
    _ ->
      # Stale response from old session, drop
      :drop
  end
end
```

With session IDs, tombstone TTL can be reduced to a small constant (e.g., 10 seconds) because stale responses are filtered by session mismatch.

**Deferred because:**
- Adds complexity (session ID tracking, bump on re-init)
- MVP tombstone formula is sufficient for normal operations
- Session IDs provide stronger guarantees but aren't required for MVP correctness

## References

- Design Document 07 (claude), Section 1: "Tombstone TTL is arbitrary and wrong"
- Design Document 10 (final spec), Section 1: "Tombstone TTL: Global, not per-request"
- Design Document 10 (final spec), Section 9: "Tombstone cleanup strategy"
- Design Document 11 (gemini), Section 2: "Cancellation Protocol: Tombstone Robustness Under Network Partition"
