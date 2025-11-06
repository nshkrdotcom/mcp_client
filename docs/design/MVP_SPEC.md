# MCP Client Library - MVP Specification

**Version:** 1.0.0-mvp
**Date:** 2025-11-06
**Status:** Locked for Implementation

---

## Overview

This document provides the complete technical specification for the Minimum Viable Product (MVP) release of the Elixir MCP (Model Context Protocol) client library. All decisions documented here are **locked** and should not be changed without writing a new Architecture Decision Record (ADR).

See `docs/adr/` for detailed rationale behind each decision.

---

## 1. Architecture

### 1.1 Core Components

**Connection (gen_statem):**
- Manages connection lifecycle state machine
- Handles JSON-RPC request/response correlation
- Tracks in-flight requests with timeouts
- Implements backoff/retry logic
- See: ADR-0001

**Transport (behavior):**
- Abstracts communication layer (stdio, SSE, HTTP)
- Provides frame-based delivery semantics
- Implements active-once flow control
- See: ADR-0004

**Supervision Tree:**
```
ConnectionSupervisor (rest_for_one)
  ├─ Transport (worker)
  └─ Connection (worker)
```
- See: ADR-0002

### 1.2 State Machine

**States:**
- `:starting` - Spawning/attaching transport
- `:initializing` - MCP handshake in progress
- `:ready` - Normal operation
- `:backoff` - Exponential backoff before reconnect
- `:closing` - Graceful shutdown

**State Data:**
```elixir
%{
  transport: pid(),
  session_id: non_neg_integer(),
  requests: %{id => request_meta},
  tombstones: %{id => tombstone_meta},
  server_caps: Types.ServerCapabilities.t() | nil,
  backoff_delay: non_neg_integer(),
  notification_handlers: [function()]
}
```

**Full transition table:** See `docs/design/STATE_TRANSITIONS.md`

---

## 2. Configuration

### 2.1 Numeric Defaults (Locked)

```elixir
@defaults [
  # Request handling
  request_timeout: 30_000,        # Per-request timeout (ms)
  init_timeout: 10_000,           # Handshake timeout (ms)

  # Backoff strategy
  backoff_min: 1_000,             # Minimum backoff delay (ms)
  backoff_max: 30_000,            # Maximum backoff delay (ms)
  backoff_jitter: 0.2,            # ±20% jitter on backoff

  # Frame handling
  max_frame_bytes: 16_777_216,    # 16MB hard limit

  # Retry behavior
  retry_attempts: 3,              # send_frame busy retries (total)
  retry_delay_ms: 10,             # Base delay between retries
  retry_jitter: 0.5,              # ±50% jitter on retry

  # Tombstone management
  tombstone_sweep_ms: 60_000,     # Periodic cleanup interval
]
```

### 2.2 Tombstone TTL Formula

```elixir
tombstone_ttl_ms =
  request_timeout +     # 30,000
  init_timeout +        # 10,000
  backoff_max +         # 30,000
  5_000                 # epsilon for jitter
# Total: 75 seconds (default)
```

**Rationale:** Covers worst-case latency window (request timeout → backoff → re-init)
**See:** ADR-0005

### 2.3 Jitter Implementation

```elixir
# Seed once in Connection.init/1
:rand.seed(:exsplus, {node(), self(), System.monotonic_time()})

defp jitter(ms, factor) do
  scale = 1.0 + (:rand.uniform() - 0.5) * (factor * 2.0)
  max(0, round(ms * scale))
end

# Backoff: jitter(delay, 0.2) → ±20%
# Retry: jitter(10, 0.5) → 5-15ms
```

---

## 3. Request Lifecycle

### 3.1 Request ID Generation

```elixir
defp next_id(), do: System.unique_integer([:positive, :monotonic])
```

**Guaranteed properties:**
- Unique across connection lifetime
- Monotonically increasing
- No collisions

### 3.2 Request Tracking

**Structure:**
```elixir
%{
  request_id => %{
    from: {pid(), reference()},       # GenServer reply target
    timer_ref: reference(),            # Timeout reference
    started_at_mono: integer(),        # System.monotonic_time()
    method: String.t(),                # For telemetry
    session_id: non_neg_integer()      # For stale filtering (post-MVP)
  }
}
```

**Storage:** Plain map in Connection state (not ETS)
**See:** ADR-0003

### 3.3 Request Flow

```
1. User calls API (e.g., McpClient.call_tool/4)
2. Connection generates unique ID
3. Connection stores request metadata in map
4. Connection sends JSON-RPC frame via Transport.send_frame/2
   - On :busy, retry up to 3 times (see ADR-0007)
   - On fatal error, fail immediately
5. Connection sets state timeout for request timeout
6. Response arrives: deliver to caller, clear timeout
7. OR timeout fires: cancel upstream, tombstone ID, reply error
```

### 3.4 Timeout Handling

**Per-request timeout (via gen_statem action):**
```elixir
actions = [{:state_timeout, timeout_ms, {:request_timeout, id}}]
```

**On timeout:**
1. Remove request from map
2. Send `$/cancelRequest` to server (best-effort)
3. Insert tombstone with TTL
4. Reply `{:error, %Error{kind: :timeout}}`

---

## 4. Backpressure

### 4.1 Active-Once Flow Control

**Transport contract:**
```elixir
@callback set_active(pid(), :once | false) :: :ok | {:error, term()}
```

**Flow:**
```
1. Transport delivers frame → Connection mailbox
2. Connection processes frame (decode, route, handle)
3. Connection calls Transport.set_active(transport, :once)
4. Transport can now deliver next frame
5. Repeat
```

**Properties:**
- Mailbox bounded to ~1 frame at a time
- No hidden buffering in transport
- Explicit flow control
**See:** ADR-0004

### 4.2 JSON Decode Strategy

**MVP: Inline decode**
- All frames decoded synchronously in Connection process
- No decoder pool, no Task.Supervisor
- Adequate for typical payloads (< 10KB)

**Trade-off:**
- Simple implementation
- Large frames (10MB+) block Connection briefly
- Head-of-line blocking for mixed sizes
**See:** ADR-0004, Section on fairness

### 4.3 Frame Size Protection

**Hard limit:** 16,777,216 bytes (16MB)

**On violation:**
1. Log error with actual size
2. Close transport immediately
3. Tombstone all in-flight requests
4. Transition to `:backoff`
5. No attempt to parse or send error

**See:** ADR-0008

---

## 5. Error Handling

### 5.1 Error Structure

```elixir
defmodule McpClient.Error do
  defexception [:kind, :code, :message, :data]

  @type t :: %__MODULE__{
    kind: :transport | :protocol | :jsonrpc | :state | :timeout | :shutdown,
    code: integer() | nil,
    message: String.t(),
    data: term()
  }
end
```

### 5.2 Error Kinds

| Kind | Meaning | Example |
|------|---------|---------|
| `:transport` | Transport-level failure | Connection closed, send busy |
| `:protocol` | Protocol violation | Invalid JSON, oversized frame |
| `:jsonrpc` | JSON-RPC error response | Method not found (-32601) |
| `:state` | Invalid state for operation | Call in `:backoff` state |
| `:timeout` | Request timeout | No response within deadline |
| `:shutdown` | Client shutting down | stop/1 called |

### 5.3 Retry & Recovery Matrix

| Error Kind | Connection Action | User Effect |
|------------|-------------------|-------------|
| `:transport` (port closed) | → `:backoff`, reconnect | In-flight: `{:error, :transport_down}` |
| `:protocol` (invalid JSON) | Log, drop frame, continue | None (unless tied to request) |
| `:jsonrpc` (server error) | Deliver to caller | Caller receives server error |
| `:state` (unknown response) | Drop if tombstoned, warn otherwise | None |
| `:timeout` (init timeout) | → `:backoff` with exponential retry | API calls return `{:error, :unavailable}` |
| `:busy` (transport) | Retry 3x with jitter else fail | Caller gets `{:error, :backpressure}` |

---

## 6. Tombstones

### 6.1 Purpose

Prevent late responses from being delivered after:
- Request timeout
- Request cancellation
- Connection restart

### 6.2 Lifecycle

**Insertion triggers:**
- Request timeout fires
- User calls cancellation (future)
- Connection transitions to `:backoff` (tombstone all in-flight)
- Server sends `notifications/cancelled`

**Structure:**
```elixir
%{
  request_id => %{
    inserted_at_mono: integer(),  # System.monotonic_time(:millisecond)
    ttl_ms: 75_000                # From formula
  }
}
```

**Cleanup:**
- Periodic sweep every 60 seconds
- Remove entries where `now - inserted_at > ttl_ms`
- Also check TTL on every lookup (belt-and-suspenders)

**See:** ADR-0005

---

## 7. Notifications

### 7.1 Handler Registration

```elixir
McpClient.on_notification(client, fn notification ->
  # Handler logic
end)
```

**Storage:** List of 1-arity functions in Connection state

### 7.2 Dispatch (MVP: Synchronous)

**Flow:**
```elixir
for handler <- handlers do
  try do
    handler.(notification)
  rescue
    error -> Logger.warn("Handler crashed: #{inspect(error)}")
  end
end
```

**Properties:**
- Handlers run in Connection process
- Exceptions caught (don't crash Connection)
- Processing order: FIFO

**Requirements (documented):**
- Handlers must be fast (< 5ms typical)
- No I/O or blocking operations
- Use `GenServer.cast/2` or `send/2` for async work

**See:** ADR-0006

---

## 8. Transport Busy Handling

### 8.1 Retry Strategy

**Attempts:** 3 total (1 initial + 2 retries)
**Delay:** 10ms base with ±50% jitter (5-15ms)

**Implementation:**
```elixir
case Transport.send_frame(transport, frame) do
  :ok -> # Success path
  {:error, :busy} ->
    # Schedule retry via state timeout
    {:keep_state, data, [{:state_timeout, jitter(10, 0.5), :retry_send}]}
  {:error, reason} -> # Fatal error
end
```

**After 3 attempts:**
```elixir
{:error, %Error{
  kind: :transport,
  message: "transport busy after 3 attempts"
}}
```

**See:** ADR-0007

---

## 9. Shutdown

### 9.1 Fail-Fast Strategy

**On `McpClient.stop/1` or supervisor shutdown:**

1. Reply to stop caller: `{:ok, :ok}`
2. Iterate all in-flight requests
3. Reply to each: `{:error, %Error{kind: :shutdown}}`
4. Tombstone all IDs
5. Close transport
6. Transition to `:closing`
7. Exit normally after 100ms

**Timing:** ~100ms total regardless of server state

**See:** ADR-0009

### 9.2 Idempotent Stop

| Current State | stop/1 Returns |
|---------------|----------------|
| `:starting`, `:initializing`, `:ready`, `:backoff` | `{:ok, :ok}` |
| `:closing` | `{:ok, :already_closing}` |

**Property:** Multiple concurrent stop calls all succeed without hanging

---

## 10. Telemetry

### 10.1 Events (Stable Schema)

**Request lifecycle:**
```elixir
[:mcp_client, :request, :start]
  meta: %{client: pid(), method: String.t(), id: integer(), corr_id: binary()}
  measurements: %{system_time: integer()}

[:mcp_client, :request, :stop]
  meta: %{client: pid(), method: String.t(), id: integer(), corr_id: binary()}
  measurements: %{duration: native_time()}

[:mcp_client, :request, :exception]
  meta: %{client: pid(), method: String.t(), id: integer(), reason: term()}
  measurements: %{}
```

**State transitions:**
```elixir
[:mcp_client, :connection, :transition]
  meta: %{from: atom(), to: atom(), reason: term() | nil}
  measurements: %{}
```

**Notifications:**
```elixir
[:mcp_client, :notification, :received]
  meta: %{method: String.t()}
  measurements: %{}
```

**Protocol violations:**
```elixir
[:mcp_client, :protocol, :violation]
  meta: %{reason: atom(), ...}
  measurements: %{frame_size: integer() | ...}
```

### 10.2 Sampling (Future)

**Not in MVP:** Sampling configuration deferred
**Rationale:** Most events are low-volume (< 100/s typical)

---

## 11. Testing Requirements

### 11.1 Property Tests (Required)

**1. Request-response correlation is 1:1 under reordering**
```elixir
property "each request receives exactly one terminal outcome" do
  check all requests <- list_of(request_generator(), min_length: 1, max_length: 50),
            order <- permutation(length(requests)) do
    # Send N requests, receive responses in arbitrary order
    # Verify each request gets exactly one outcome
  end
end
```

**2. Timeouts don't leak**
```elixir
property "request map is empty after all timeouts/responses" do
  check all requests <- list_of(request_generator()),
            timeout_some <- boolean() do
    # Send requests, timeout some, respond to others
    # Verify Connection.requests map is empty
    # Verify tombstones <= N and decay after TTL
  end
end
```

**3. Cancellation is idempotent**
```elixir
property "cancelling N times = cancelling once" do
  check all id <- request_id_generator(),
            cancel_times <- integer(1..10) do
    # Cancel same request N times
    # Verify exactly one terminal outcome
    # Verify no crashes
  end
end
```

**Parameters (locked):**
```elixir
@property_iterations 100
@max_concurrent_requests 50
@max_reorder_window_ms 100
@cancellation_attempts 10
```

### 11.2 Unit Tests (Required)

- ✅ All public API functions
- ✅ State machine transitions (all edges)
- ✅ Error handling (all error kinds)
- ✅ Timeout behavior
- ✅ Retry logic (busy transport)
- ✅ Frame size limit enforcement
- ✅ Graceful shutdown
- ✅ Notification dispatch
- ✅ Tombstone cleanup

### 11.3 Integration Tests (Required)

- ✅ Real stdio transport with reference servers
- ✅ SSE transport with mock server
- ✅ HTTP transport with mock server
- ✅ Initialize handshake with capability negotiation
- ✅ Tool invocation end-to-end
- ✅ Resource read with subscriptions
- ✅ Connection failure and recovery

---

## 12. API Surface (Public)

### 12.1 Core Functions

```elixir
# Lifecycle
start_link(opts) :: GenServer.on_start()
stop(client()) :: :ok
await_initialized(client(), timeout()) :: :ok | {:error, term()}

# Resources
list_resources(client(), opts) :: {:ok, [Resource.t()]} | {:error, term()}
read_resource(client(), uri(), opts) :: {:ok, map()} | {:error, term()}
subscribe_resource(client(), uri()) :: :ok | {:error, term()}
unsubscribe_resource(client(), uri()) :: :ok | {:error, term()}
list_resource_templates(client()) :: {:ok, list()} | {:error, term()}

# Prompts
list_prompts(client()) :: {:ok, list()} | {:error, term()}
get_prompt(client(), name(), args()) :: {:ok, map()} | {:error, term()}

# Tools
list_tools(client()) :: {:ok, [Tool.t()]} | {:error, term()}
call_tool(client(), name(), args(), opts) :: {:ok, map()} | {:error, term()}

# Sampling
create_message(client(), params()) :: {:ok, map()} | {:error, term()}

# Roots
list_roots(client()) :: {:ok, list()} | {:error, term()}

# Logging
set_log_level(client(), level()) :: :ok | {:error, term()}

# Health
ping(client()) :: :ok | {:error, term()}

# Notifications
on_notification(client(), (Notification.t() -> any())) :: :ok
on_progress(client(), (map() -> any())) :: :ok

# Introspection
state(client()) :: atom()
server_capabilities(client()) :: {:ok, Capabilities.t()} | {:error, term()}
server_info(client()) :: {:ok, Implementation.t()} | {:error, term()}
```

### 12.2 Options

**start_link/1 options:**
```elixir
[
  # Required
  transport: :stdio | :sse | :http_sse,

  # Transport-specific (stdio)
  command: String.t(),
  args: [String.t()],
  env: %{String.t() => String.t()},

  # Transport-specific (SSE)
  url: String.t(),
  headers: [{String.t(), String.t()}],

  # Transport-specific (HTTP)
  base_url: String.t(),
  sse_endpoint: String.t(),
  message_endpoint: String.t(),

  # Common
  name: atom() | {:via, module(), term()},
  client_info: %{name: String.t(), version: String.t()},
  capabilities: Capabilities.t(),
  timeout: timeout(),
  initialize_timeout: timeout()
]
```

**call_*/N options:**
```elixir
[
  timeout: timeout()  # Override default per-call
]
```

---

## 13. What's NOT in MVP

**See: ADR-0010 for complete list**

**Critical deferrals:**
- ❌ Session ID gating (post-MVP correctness hardening)
- ❌ Async notification dispatch (TaskSupervisor)
- ❌ Offload JSON decode pool
- ❌ Connection pooling
- ❌ ETS-based request tracking
- ❌ WebSocket transport
- ❌ Compression
- ❌ Streaming/chunking
- ❌ Request replay after reconnect

**Rationale:** MVP focuses on mechanical correctness for single-connection scenarios. Post-MVP optimizes for scale and advanced use cases.

---

## 14. Acceptance Criteria

**MVP is complete when:**

1. ✅ Passes all property tests (3 core guarantees)
2. ✅ Passes all unit tests (100% coverage of state machine)
3. ✅ Passes all integration tests (real servers)
4. ✅ Works with reference MCP servers (filesystem, git, etc.)
5. ✅ Runs under supervision without crashes
6. ✅ Handles all failure scenarios gracefully
7. ✅ Documentation complete (moduledocs, guides, examples)
8. ✅ ADRs published and linked
9. ✅ Hex package published with >= 0.1.0
10. ✅ Used in at least one real application

---

## 15. Implementation Checklist

### 15.1 Modules

- [ ] `McpClient` (public API)
- [ ] `McpClient.Connection` (gen_statem)
- [ ] `McpClient.Transport.Behaviour`
- [ ] `McpClient.Transport.Stdio`
- [ ] `McpClient.Transport.SSE`
- [ ] `McpClient.Transport.HTTP`
- [ ] `McpClient.Protocol.JSONRPC` (encode/decode)
- [ ] `McpClient.Protocol.Initialize`
- [ ] `McpClient.Protocol.Ping`
- [ ] `McpClient.Types` (structs)
- [ ] `McpClient.Error` (exception)
- [ ] `McpClient.ConnectionSupervisor`

### 15.2 Tests

- [ ] Property tests (3 required)
- [ ] Unit tests (state machine, API)
- [ ] Integration tests (real transports)
- [ ] Mock transport for testing

### 15.3 Documentation

- [ ] README with quick start
- [ ] Moduledocs for all public modules
- [ ] Function docs with examples
- [ ] Integration guides (LiveView, Oban, Broadway)
- [ ] Link to ADRs from README

---

## 16. References

- **ADRs:** `docs/adr/`
- **State Table:** `docs/design/STATE_TRANSITIONS.md`
- **MCP Spec:** https://spec.modelcontextprotocol.io/
- **Design Documents:** `docs/20251106/`

---

**Version History:**
- 1.0.0-mvp (2025-11-06): Initial locked specification
