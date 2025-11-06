# 4. Active-Once Backpressure Model with Inline Decode

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

The MCP client must handle incoming JSON-RPC frames from the transport (stdio/SSE/HTTP) without overwhelming the Connection process mailbox or blocking the BEAM scheduler. Large JSON payloads (potentially 10MB+ resource contents) can cause long decode times, while high-volume notifications can flood the mailbox.

Without backpressure, the transport could deliver frames faster than the Connection can process them, leading to unbounded memory growth and latency spikes.

## Decision Drivers

- Prevent mailbox flooding under burst load
- Bound memory growth from incoming frames
- Avoid long reductions in Connection process (scheduler fairness)
- Keep implementation simple for MVP
- Balance throughput vs. latency
- No hidden queuing or buffering

## Considered Options

**Option 1: Active-always transport**
- Transport continuously delivers frames to Connection
- No flow control
- Simple but unsafe

**Option 2: Active-once with offload decode pool**
- Transport paused after each frame
- Large frames (> threshold) decoded in Task.Supervisor pool
- Connection waits for decode before re-enabling transport

**Option 3: Active-once with inline decode**
- Transport paused after each frame
- All frames decoded inline in Connection
- Re-enable transport after processing each frame

**Option 4: Ring buffer with bounded queue**
- Explicit queue between Transport and Connection
- Drop oldest frames when full

## Decision Outcome

Chosen option: **Active-once with inline decode (Option 3)**, because:

1. **Predictable backpressure**: Connection explicitly controls transport via `set_active(:once)` after each frame
2. **Bounded mailbox**: Transport only delivers one frame per enable call
3. **Simple implementation**: No Task pool, no queue, no complex coordination
4. **Adequate for MVP**: Most frames are small (< 10KB); inline decode is fast
5. **Explicit flow**: Easy to reason about; no hidden buffering

### Implementation Details

**Transport contract:**
```elixir
@callback set_active(pid(), :once | false) :: :ok | {:error, term()}
```

**Flow:**
```
1. Port/SSE delivers frame → Transport
2. Transport sends {:transport, :frame, binary} to Connection
3. Connection mailbox receives frame (paused transport)
4. Connection decodes JSON inline
5. Connection processes frame (route request/response/notification)
6. Connection calls Transport.set_active(transport, :once)
7. Repeat from step 1
```

**Implementation in Connection:**
```elixir
def handle_event(:info, {:transport, :frame, binary}, :ready, data) do
  case Jason.decode(binary) do
    {:ok, json} ->
      data = process_frame(json, data)
      :ok = Transport.set_active(data.transport, :once)
      {:keep_state, data}

    {:error, reason} ->
      Logger.warn("Invalid JSON: #{inspect(reason)}")
      :ok = Transport.set_active(data.transport, :once)
      {:keep_state, data}
  end
end
```

**No explicit decoder pool** - all decode is inline for MVP.

**Frame size protection:**
- Hard limit: `max_frame_bytes = 16_777_216` (16MB)
- Oversized frames close connection and trigger `:backoff`
- See ADR-0008 for details

### Consequences

**Positive:**
- Mailbox size bounded to ~1 frame at a time
- No scheduler surprise from decode pool context switches
- Deterministic processing order (FIFO)
- Simple code path (no async coordination)
- Easy to debug (linear flow)

**Negative/Risks:**
- Large frames (10MB+) block Connection during decode (seconds)
- Head-of-line blocking: small frame after large frame waits
- No parallelism in decode (single-threaded)
- Connection cannot process responses during decode

**Neutral:**
- Throughput limited by single-threaded decode (acceptable for MVP)
- Latency variance depends on frame size distribution

## Trade-off: Fairness vs. Simplicity

We explicitly **prioritize stability over fairness** under mixed large/small frame loads:

> A single large decode occupies the Connection process. Subsequent small frames must wait in the transport buffer until the large decode completes (head-of-line blocking). If strict fairness is required (small frames never delayed by large frames), consider post-MVP:
> - Two-queue decoder (small-frame fast lane)
> - Weighted concurrency limiter
> - Streaming JSON parser with yield points

**These add complexity and overhead; MVP behavior is predictable and bounded.**

## Deferred Alternatives

**Offload decode pool (post-MVP)**: If profiling shows decode blocking is a real issue:
- Add `decode_threshold_bytes` config (e.g., 128KB)
- Frames > threshold decoded in Task.Supervisor
- Connection tracks `in_flight_decoders` count with cap (e.g., 8)
- Connection defers `set_active(:once)` if decoder pool saturated

Deferred because:
- Adds Task.Supervisor to supervision tree (complexity)
- Requires decoder cap management (more state)
- MVP users unlikely to hit decode bottleneck (most frames < 10KB)
- Can measure in production before optimizing

## References

- Design Document 02 (gpt5.md), Section 4: "Backpressure model is incomplete"
- Design Document 04 (v2_gpt5.md), Section 4: "Backpressure & CPU isolation"
- Design Document 06 (gemini), Section 4: "Backpressure: A Note on Fairness"
- Design Document 10 (final spec), Section 4: "Backpressure & CPU isolation"
