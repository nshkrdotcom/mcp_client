# 8. 16MB Maximum Frame Size Limit with Connection Close

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

JSON-RPC over MCP has no inherent frame size limit. A malicious or buggy server could send extremely large payloads (100MB+) that exhaust client memory, cause OOM crashes, or block the Connection process for extended periods during JSON decode.

The client must enforce a reasonable maximum frame size and handle violations safely.

## Decision Drivers

- Prevent memory exhaustion from unbounded payloads
- Protect against malicious servers
- Align with common JSON-RPC implementation limits
- Clear failure semantics (don't silently truncate)
- Simple implementation for MVP
- No negotiation overhead

## Considered Options

**Option 1: No limit**
- Accept frames of any size
- Simple but unsafe

**Option 2: 16MB hard limit, close connection**
- Reject frames > 16MB
- Close transport and transition to `:backoff`
- No error response sent

**Option 3: 16MB limit, send error response**
- Parse frame header to extract `id`
- Send JSON-RPC error before closing
- More complex

**Option 4: Configurable limit, negotiated during init**
- Exchange `max_frame_size` capability during initialize
- Complex protocol extension

## Decision Outcome

Chosen option: **16MB hard limit, close connection (Option 2)**, because:

1. **Safe default**: 16MB provides a generous ceiling for JSON-RPC; HTTP/2's default frame size is 16KB, and we're 1000x more permissive for large payloads
2. **Simple implementation**: Check `byte_size(frame)` before decode
3. **Clear failure mode**: Oversized frame = protocol violation = close connection
4. **No parsing required**: Don't attempt to extract `id` from unsafe payload
5. **Prevents DoS**: Attacker can't send 1GB payload to exhaust memory

### Implementation Details

**Configuration:**
```elixir
@max_frame_bytes 16_777_216  # 16MB = 16 * 1024 * 1024
```

**Check in frame handler:**
```elixir
def handle_event(:info, {:transport, :frame, binary}, state, data)
    when byte_size(binary) > @max_frame_bytes do
  Logger.error("""
  Frame size exceeds limit: #{byte_size(binary)} bytes (max: #{@max_frame_bytes})
  Closing connection due to protocol violation.
  """)

  # Close transport immediately
  Transport.close(data.transport)

  # Tombstone all in-flight requests
  data = tombstone_all_requests(data)

  # Emit telemetry
  :telemetry.execute(
    [:mcp_client, :protocol, :violation],
    %{frame_size: byte_size(binary)},
    %{reason: :oversized_frame, max: @max_frame_bytes}
  )

  # Transition to backoff
  {:next_state, :backoff, data, schedule_backoff(data)}
end
```

**State transitions with oversized frames:**

| State | Event | Action |
|-------|-------|--------|
| `:starting` | (N/A - no frames yet) | - |
| `:initializing` | `frame(oversized)` | Close transport; schedule backoff → `:backoff` |
| `:ready` | `frame(oversized)` | Close transport; tombstone all; schedule backoff → `:backoff` |
| `:backoff` | `frame(oversized)` | Drop (shouldn't happen, transport inactive) |
| `:closing` | `frame(oversized)` | Drop (already closing) |

### Consequences

**Positive:**
- Memory safe: no 100MB+ allocations
- DoS resistant: attacker can't send huge payloads
- Simple: no header parsing, no error response complexity
- Clear semantics: oversized frame = protocol violation
- Fast check: `byte_size/1` is O(1)

**Negative/Risks:**
- **Server state desync**: Server may have sent a valid response, but we close without error reply
  - Server's request handler may be left waiting for response
  - Acceptable: server violated protocol by sending oversized frame
- **No granular error**: Client receives `{:error, :transport_down}` for in-flight requests, not "frame too large"
  - Mitigated: Detailed error logged, telemetry emitted with size
- **Fixed limit**: No per-server negotiation (post-MVP feature)

**Neutral:**
- Reconnect via backoff may succeed if oversized frame was transient (unlikely)
- Real-world JSON-RPC rarely exceeds 1MB; 16MB is generous

## Rationale for 16MB

**Typical JSON-RPC frame sizes:**
- Request/response: 100 bytes - 10 KB
- Resource content: 10 KB - 1 MB (text files, small images)
- Large resource: 1 MB - 5 MB (large files, base64 images)
- Extreme: 5 MB - 16 MB (huge documents, very large images)

**16MB provides:**
- Room for large but legitimate payloads
- Protection against obviously malicious/broken servers
- Alignment with common RPC limits (gRPC default: 4MB; we're generous compared to HTTP/2's 16KB default)

**Examples that fit:**
- 10MB text file encoded in JSON string
- 5MB PNG image base64-encoded (~7MB in JSON)
- 1000-element tool list with descriptions

**Examples that don't fit (and shouldn't):**
- 50MB video file (should use streaming/chunking)
- 100MB database dump (should use separate transfer mechanism)
- 1GB log file (server bug)

## Why Not Send Error Response?

**Option 3 (send error before close) is tempting** but has problems:

1. **Safety**: Must parse frame header to extract `id`; parsing unsafe data defeats the purpose
2. **Partial parse risk**: Truncated or malformed huge frames may not have valid JSON header
3. **Complexity**: Need specialized "extract ID without full parse" logic
4. **Delayed protection**: Still allocate memory to check structure

**Verdict**: Fail-fast by closing immediately is safer and simpler for MVP.

## Server Behavior

When client closes connection due to oversized frame:

**Server perspective:**
- Sees connection close (transport shutdown)
- May log "client disconnected" without context
- No JSON-RPC error received

**Mitigation (server-side):**
- Servers should implement their own frame size limits
- MCP spec should recommend maximum payload sizes
- Chunking/streaming for large resources (post-MVP MCP extension)

**Client logging provides context:**
```
[error] Frame size exceeds limit: 18874368 bytes (max: 16777216)
[error] Closing connection due to protocol violation.
```

## Deferred Alternatives

**Negotiated frame size limit (post-MVP)**: Exchange during initialize handshake:

```json
// Client sends
{
  "jsonrpc": "2.0",
  "method": "initialize",
  "params": {
    "clientInfo": {...},
    "capabilities": {
      "experimental": {
        "maxFrameSize": 16777216
      }
    }
  }
}

// Server responds
{
  "result": {
    "serverInfo": {...},
    "capabilities": {
      "experimental": {
        "maxFrameSize": 8388608  // Server wants 8MB max
      }
    }
  }
}

// Client enforces min(client_max, server_max)
```

**Deferred because:**
- Adds protocol complexity
- Not in current MCP spec
- Fixed 16MB sufficient for MVP
- Requires coordination with MCP spec maintainers

**Configurable limit (post-MVP):**
```elixir
McpClient.start_link([
  # ... other opts
  max_frame_bytes: 32 * 1024 * 1024  # User overrides to 32MB
])
```

**Deferred because:**
- Fixed default is safer (users must opt into risk)
- No user request for this flexibility yet

## Testing

**Unit test: Reject oversized frame**
```elixir
test "closes connection on oversized frame" do
  huge_frame = :binary.copy(<<0>>, 17_000_000)  # 17MB
  send(connection, {:transport, :frame, huge_frame})

  assert_receive {:transport_closed, _reason}
  assert state(connection) == :backoff
end
```

**Unit test: Accept at limit**
```elixir
test "accepts frame exactly at limit" do
  frame = :binary.copy(<<0>>, 16_777_216)  # Exactly 16MB
  send(connection, {:transport, :frame, frame})

  # Should attempt decode (will fail as invalid JSON, but not rejected for size)
  refute_receive {:transport_closed, _reason}
end
```

**Integration test: In-flight requests tombstoned**
```elixir
test "in-flight requests fail when oversized frame closes connection" do
  task = Task.async(fn -> McpClient.call_tool(client, "test", %{}) end)

  # Server sends oversized frame
  send_oversized_frame(server)

  assert {:error, %Error{type: :transport}} = Task.await(task)
end
```

## References

- Design Document 07 (claude), Section 4: "Frame size violation needs protocol-level handling"
- Design Document 08 (gpt5.md), Section 4: "`max_frame_bytes`"
- Design Document 10 (final spec), Section 4: "16MB frame limit"
- Design Document 10 (final spec), Section 5: State transition table (oversized frame edges)
