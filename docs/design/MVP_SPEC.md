# MCP Client Library - MVP Specification

**Version:** 1.1.0-mvp
**Date:** 2025-11-08
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
- Defines callback contract for transports (`McpClient.Transport`)
- Concrete modules live under `McpClient.Transports.*` (e.g., `.Stdio`, `.Sse`)
- Supervisor injects `{transport_mod, transport_opts}` and starts the transport child **before** Connection
- Provides frame-based delivery semantics + active-once flow control
- Users may supply their own transport modules or override Finch/HTTP clients via the same `{module(), opts}` tuple
- See: ADR-0004 and ADR-0014

**Supervision Tree:**
```
ConnectionSupervisor (rest_for_one)
  ├─ Transport (worker)
  ├─ StatelessSupervisor (Task.Supervisor)  # for :stateless tool execution
  └─ Connection (worker)
```
- See: ADR-0002
- Supervisor always starts Transport first, Connection second
- Connection never spawns its own transport; it receives the PID in `init/1`
- Failure cascade: if Transport dies, both children restart; if Connection dies, only Connection restarts
- Stateless task supervisor is placed between Transport and Connection so it restarts alongside Connection but does not take the transport down on crash.

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
  session_mode: :required | :optional,
  tool_modes: %{String.t() => :stateful | :stateless},
  requests: %{id => request_meta},
  retries: %{id => retry_meta},
  tombstones: %{id => tombstone_meta},
  server_caps: Types.ServerCapabilities.t() | nil,
  backoff_delay: non_neg_integer(),
  notification_handlers: [function()]
}
```

`session_mode` starts at `:optional` and flips to `:required` automatically whenever a server advertises at least one stateful tool. `tool_modes` caches the server-supplied metadata from `tools/list` so the Connection can decide how to dispatch each invocation (ADR-0012).
Request/retry/tombstone metadata lives inside this struct for the MVP; ADR-0013 documents how pluggable state-store and registry adapters will hook into this surface post-MVP without changing the FSM.

**Full transition table:** See `docs/design/STATE_TRANSITIONS.md`

### 1.3 Connection Registry & Multi-Connection Support

- Every connection **must** be registered via an atom or `{:via, Registry, {module(), term()}}` tuple so supervisors and transports can locate the correct process in multi-client deployments.
- Guides document a canonical `MyApp.MCP.ConnectionRegistry` wrapper that supervisors should start alongside the client (`docs/guides/ADVANCED_PATTERNS.md`).
- ADR-0013 tracks the future work to allow pluggable registry adapters (Horde, Swarm, Redis-backed) without rewriting the connection or supervisor trees.
- Transports receive the registered connection name during `start_link/1` and never assume singleton processes, satisfying the community request for N:1 server support.

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

# Backoff: jitter(delay, 0.2) → ±20%, then clamp to [backoff_min, backoff_max]
# Retry: jitter(10, 0.5) → 5-15ms
# All math uses monotonic millisecond integers; telemetry exports native duration units
```

### 2.4 Protocol Compatibility

- MVP accepts **only** protocol version `"2024-11-05"` during `initialize`.
- Validation lives in `McpClient.Protocol.Initialize.assert_supported_version!/1` and is invoked exactly once (no duplicated policies).
- Future compatibility windows (e.g., YYYY-MM) require a new ADR; for now any other version transitions to `:backoff` with `{:error, %Error{type: :protocol}}`.

### 2.5 Timer Ownership Invariant

- At any moment there is **at most one** `:state_timeout` armed (init timeout, tombstone sweep, or backoff tick).
- All per-request timers (timeouts, retries) use `:erlang.send_after/3` and surface through the normal `:info` path so they cannot starve the singular `:state_timeout`.

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
    retry_ref: reference() | nil,      # Busy send retry timer (if armed)
    started_at_mono: integer(),        # System.monotonic_time()
    method: String.t(),                # For telemetry
    session_id: non_neg_integer()      # Captured when session_mode == :required (for stale filtering)
  }
}
```

**Storage:** Plain map in Connection state (not ETS)
- Large request payloads keep a reference to the original encoded binary; we never slice/concatenate in-place.
- If a retry needs a mutated payload, we store `{method, params}` alongside and re-encode to avoid holding partially-copied binaries.
**See:** ADR-0003

**Retry entries (per busy send):**
```elixir
%{
  request_id => %{
    frame: binary() | iodata(),
    from: {pid(), reference()},
    request: request_meta(),
    attempts: non_neg_integer(),
    timer_ref: reference()
  }
}
```

### 3.3 Request Flow

```
1. User calls API (e.g., McpClient.call_tool/4)
2. Connection generates unique ID
3. Connection stores request metadata in map (always captures `from`)
4. Connection schedules timeout via `:erlang.send_after/3` and stores the timer ref
5. Connection sends JSON-RPC frame via `Transport.send_frame/2`
   - On `{:error, :busy}`, retry up to 3 times via retry timers (ADR-0007)
   - On fatal error, remove metadata, cancel timer, reply error immediately
   - `meta.session_id` is included only when `session_mode == :required` (ADR-0012)
6. Response arrives: cancel timer, deliver to caller, clear metadata
7. Timeout message arrives: cancel upstream, tombstone ID, reply error
```

### 3.4 Timeout Handling

**Mechanics:**
- Each request stores `timer_ref = :erlang.send_after(timeout_ms, self(), {:req_timeout, id})`
- Timeout arrives as `:info, {:req_timeout, id}` (tests can `send/2` the same tuple)
- Cancelling uses `:erlang.cancel_timer(timer_ref, async: true)`; ignore `:ok | false` result

**On timeout:**
1. Remove request from map (ignore if already handled/tombstoned)
2. Fire `send_client_cancel(id)` once (no retry, doesn't raise)
3. Insert tombstone with TTL
4. Reply `{:error, %Error{type: :timeout}}`

**Cancel helper (MVP):**
```elixir
defp send_client_cancel(%{transport: transport}, id) do
  frame = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "$/cancelRequest", "params" => %{"requestId" => id}})
  # Fire-and-forget; do not retry or crash on failure
  :ok = Transport.send_frame(transport, frame) || :ok
end
```

`Transport.send_frame/2` is used for notifications as well—JSON-RPC treats them as regular frames with no `id`.

### 3.5 Synchronous Call Semantics

- `gen_statem.call/3` requests in `:ready` stay **pending** until completion or timeout; never reply `{:ok, id}` immediately.
- The `from` reference is stored in the request entry and is satisfied exactly once via `GenServer.reply/2`.
- Async APIs (returning request IDs up front) are out-of-scope for MVP; future work will add explicit `request_async/4`.
- Every path that removes a request (`response`, `timeout`, `transport_down`, `shutdown`) must cancel timers and reply exactly once.

### 3.6 Reset Semantics

- MVP does **not** implement custom `"$/reset"` or `"notifications/reset"` handling.
- Re-initialization occurs only after transport failure, oversized frames, or explicit Connection shutdown.
- If a server sends a second `"initialize"` request, we treat it as a protocol violation and log at `:warning`, then transition to `:backoff`.
- Future negotiated reset behavior will require a capability flag and an ADR.

### 3.7 Tool Dispatch Modes (ADR-0012)

Tool invocations follow the `mode` declared by the server (see ADR-0012):

- `:stateless`
  - Executed inside a short-lived request process (`Task.Supervisor` child) so long-running work never blocks the Connection.
  - Requests omit `meta.session_id` when `session_mode == :optional`.
  - Results are pushed back into the Connection for delivery so timeout/tombstone logic remains centralized.
- `:stateful`
  - Executed directly inside the Connection. Requests always include `meta.session_id`.
  - Connection refuses to execute if the server has not completed initialization or if a session cannot be established.
- **Mode switching**
  - When `tools/list` arrives, `tool_modes` is rebuilt and `session_mode` recomputed (`:required` if *any* tool is stateful).
  - Stateless calls inherit session metadata when `session_mode == :required` to keep telemetry consistent even though they execute in isolated processes.

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
- Mailbox bounded to ~1 frame at a time (header parsing might enqueue a few short messages, but body bytes are left unread until activation, so the OS pipe applies backpressure before growth becomes unbounded)
- No hidden buffering in transport (the transport stops reading body chunks until Connection re-arms)
- Explicit flow control
- Connection uses `set_active_once_safe/1` helper that no-ops once transport is closed/backing off
- Transport implementations must stop reading from the external IO source until `set_active(:once)` is invoked; buffering more than 1 framed message violates MVP contract.
- Stdio transport keeps only header bytes while paused and reads the declared body **after** Connection re-activates it.
- Declared sizes above `max_frame_bytes` are rejected immediately and the transport closes before reading the body, so no large binary is ever allocated.
- Call `set_active_once_safe/1` only from states that expect more frames (`:initializing`, `:ready`); in `:backoff`/`:closing` it becomes a no-op to avoid late activation after shutdown.
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

### 4.4 Large Payload Handling

- Request entries keep either the original encoded binary or `{method, params}` tuple; we never slice derivatives of large binaries.
- Retries reuse the same reference when possible; if a frame must be rebuilt we re-encode from method/params to avoid copying 16MB binaries.
- Any code that inspects payloads **must** work on decoded structures, not binary slices, to preserve BEAM's reference-counted off-heap sharing.

### 4.5 Stdio Transport Requirements

- Framing uses `Content-Length: <bytes>\r\n\r\n<body>` exactly as in LSP/JSON-RPC; NDJSON is **not** supported.
- Reader loop: accumulate header lines until `\r\n\r\n`, parse integer, reject if `> max_frame_bytes` before allocating, then read body bytes.
- Port options: `Port.open({:spawn_executable, cmd}, [:binary, :exit_status, {:args, args}, {:env, env}, {:cd, cd}])`. We keep `:packet` disabled to preserve raw framing.
- Always drain/forward stderr using `:stderr_to_stdout` or via a dedicated Logger process so the server does not block.
- Writers emit the same `Content-Length` headers, followed by CRLF CRLF and the UTF-8 encoded JSON payload.

---

## 5. Error Handling

### 5.1 Error Structure

```elixir
defmodule McpClient.Error do
  defexception [:type, :message, :details, :server_error, :code]

  @type t :: %__MODULE__{
    type: :transport | :protocol | :jsonrpc | :state | :timeout | :shutdown,
    message: String.t(),
    details: map(),
    server_error: map() | nil,
    code: integer() | nil
  }
end
```

### 5.2 Error Types

| Type | Meaning | Example |
|------|---------|---------|
| `:transport` | Transport-level failure | Connection closed, send busy |
| `:protocol` | Protocol violation | Invalid JSON, oversized frame |
| `:jsonrpc` | JSON-RPC error response | Method not found (-32601) |
| `:state` | Invalid state for operation | Call in `:backoff` state |
| `:timeout` | Request timeout | No response within deadline |
| `:shutdown` | Client shutting down | stop/1 called |

### 5.3 Retry & Recovery Matrix

| Error Type | Connection Action | User Effect |
|------------|-------------------|-------------|
| `:transport` (port closed) | → `:backoff`, reconnect | In-flight: `{:error, :transport_down}` |
| `:protocol` (invalid JSON) | Log, drop frame, continue | None (unless tied to request) |
| `:jsonrpc` (server error) | Deliver to caller | Caller receives server error |
| `:state` (unknown response) | Drop if tombstoned, warn otherwise | None |
| `:timeout` (init timeout) | → `:backoff` with exponential retry | API calls return `{:error, :unavailable}` |
| `:busy` (transport) | Retry 3x with jitter else fail | Caller gets `{:error, :backpressure}` |

### 5.4 Unknown Response IDs

- Responses that do not match `requests` or `tombstones` log at `:debug` with `type: :unknown_response`.
- Increment `unknown_response_count` telemetry counter for future observability (exported via `measurements: %{count: 1}`).
- No user-visible error is emitted; we rely on tombstones + counter to detect gaps.

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

**Storage:** List of 1-arity functions in Connection state (hot code upgrades are not supported in MVP; restart the client after deploying new handler code)

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

**See:** ADR-0006 (current behaviour) and ADR-0015 (planned optional async mode)

### 7.3 Progress & Cancellation

- `on_progress/2` uses the same synchronous dispatch path; progress payloads are expected to be small status updates.
- Timeouts and manual cancellations send exactly one `$/cancelRequest` via `send_client_cancel/2`; the notification is best-effort and never retried.
- Server-driven `"$/progress"` updates may arrive after cancellation; we drop them if the ID is tombstoned.

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
    retry_ref = :erlang.send_after(jitter(10, 0.5), self(), {:retry_send, id, frame})
    put_in(data.requests[id].retry_ref, retry_ref)
  {:error, reason} -> # Fatal error
end
```

**After 3 attempts:**
```elixir
{:error, %Error{
  type: :transport,
  message: "transport busy after 3 attempts",
  details: %{attempts: 3}
}}
```

- Retry timers deliver as `:info, {:retry_send, id, frame}`; handlers must check `requests[id]` before resending.
- Cancel outstanding `retry_ref` with `:erlang.cancel_timer/1` once the send succeeds or the request terminates.
- `:state_timeout` is reserved for single outstanding timers (init, drain); per-request retries never use it.

**See:** ADR-0007

---

## 9. Shutdown

### 9.1 Fail-Fast Strategy

**On `McpClient.stop/1` or supervisor shutdown:**

1. Reply to stop caller: `{:ok, :ok}`
2. Iterate all in-flight requests
3. Reply to each: `{:error, %Error{type: :shutdown}}`
4. Tombstone all IDs
5. Ask transport to terminate gracefully (`Transport.close/1` → Port.close/SIGTERM + wait for `{:exit_status, code}`)
6. Transition to `:closing`
7. Exit normally after 100ms (or sooner if transport confirms shutdown)

**Timing:** ~100ms total regardless of server state

- Stdio transport forwards stderr either via `:stderr_to_stdout` or a dedicated Logger task; never leave the pipe unread.
- On shutdown we always drain pending stderr bytes before closing the port to avoid blocked subprocesses.

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

**Units:** All duration measurements are reported in native units (`System.monotonic_time/0`). Configuration/backoff math stays in milliseconds but never leaves the Connection process.

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

[:mcp_client, :response, :unknown]
  meta: %{client: pid()}
  measurements: %{count: 1}

```

Example handler:

```elixir
:telemetry.attach(
  "log-unknown-responses",
  [:mcp_client, :response, :unknown],
  fn _event, %{count: count}, %{client: pid}, _ ->
    Logger.debug("Unknown response id", client: pid, count: count)
  end,
  nil
)
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

**Timer testing guideline:** Tests trigger timeout paths either by shortening durations via config or by `send(conn, {:req_timeout, id})`/`{:retry_send, id, frame}`. Never fabricate `{:state_timeout, ...}` messages.
- Example (manual trigger):
  ```elixir
  send(conn, {:req_timeout, id})
  assert_receive {:error, %Error{type: :timeout}}
  ```
- Example (real timer with short duration):
  ```elixir
  conn = start_conn(request_timeout: 5)
  {:ok, _} = McpClient.Tools.call(conn, "slow", %{}, timeout: 5)
  # timer fires naturally without slowing tests
  ```
- Example (retry tick):
  ```elixir
  send(conn, {:retry_send, id, frame})
  assert_receive {:mcp_retry_attempted, ^id} # via your test transport/mocks
  ```

### 11.2 Unit Tests (Required)

- ✅ All public API functions
- ✅ State machine transitions (all edges)
- ✅ Error handling (all error types)
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
- ✅ Shell-based fixtures (e.g., `cat`, `printf`) run only when `System.find_executable/1` finds them; otherwise tests skip with helpful message

---

## 12. API Surface (Public)

### 12.1 Connection Lifecycle (McpClient)

```elixir
start_link(opts) :: GenServer.on_start()
stop(client()) :: :ok
await_initialized(client(), timeout()) :: :ok | {:error, term()}
state(client()) :: :starting | :initializing | :ready | :backoff | :closing
server_capabilities(client()) :: {:ok, Capabilities.t()} | {:error, McpClient.Error.t()}
server_info(client()) :: {:ok, Implementation.t()} | {:error, McpClient.Error.t()}
on_notification(client(), handler :: (map() -> any())) :: :ok
on_progress(client(), handler :: (map() -> any())) :: :ok
```

`McpClient` owns lifecycle + notification registration only. All feature APIs live under dedicated modules below.

### 12.2 Feature Modules (Required)

| Module | Functions | Capability guard |
|--------|-----------|------------------|
| `McpClient.Tools` | `list/2`, `call/4` (Tool struct exposes `mode`) | `server_caps.tools? == true` |
| `McpClient.Resources` | `list/2`, `read/3`, `subscribe/2`, `unsubscribe/2`, `list_templates/1` | `server_caps.resources? == true` |
| `McpClient.Prompts` | `list/1`, `get/3` | `server_caps.prompts? == true` |
| `McpClient.Sampling` | `create_message/2` | `server_caps.sampling? == true` |
| `McpClient.Roots` | `list/1` | `server_caps.roots? == true` |
| `McpClient.Logging` | `set_level/2` | `server_caps.logging? == true` |

- Each feature call **first** inspects cached server capabilities and returns `{:error, %Error{type: :capability_not_supported, details: %{required: capability}}}` if absent.
- Feature modules expose typed structs (via `TypedStruct`, dev-only dependency) for responses/results; this dependency is declared as `runtime: false` in `mix.exs`.
- No top-level convenience wrappers (`McpClient.list_tools/2`) ship in MVP; we will add them only if real users request it.

### 12.3 start_link/1 Options

```elixir
[
  # Required
  transport: {module(), keyword()},   # e.g., {McpClient.Transports.Stdio, cmd: "repo/mcp-server"},

  # Common
  name: atom() | {:via, module(), term()},
  client_info: %{name: String.t(), version: String.t()},
  capabilities: map(),                # Advertised client capabilities
  request_timeout: timeout(),
  init_timeout: timeout(),
  backoff_min: non_neg_integer(),
  backoff_max: non_neg_integer(),
  stateless_supervisor: module() | {module(), keyword()},  # Defaults to internal Task.Supervisor

  # Stdio transport opts (subset)
  cmd: String.t(),
  args: [String.t()],
  env: %{String.t() => String.t()},
  cd: String.t() | nil,
  stderr: :merge | :log,              # :merge => :stderr_to_stdout, :log => spawn logger task

  # SSE/HTTP transports add url/header-specific keys
]
```

Always pass a `:name` when starting supervised connections. Multi-connection applications should favor `{:via, Registry, {MyApp.MCP.Registry, key}}` so transports and helper processes can find the correct Connection PID without global singletons (see Section 1.3).

**call_*/N options:**
```elixir
[timeout: timeout()]  # Override default per-call
```

### 12.4 JSON Example Convention

All request/response examples in this doc use **string keys** (matching JSON) even when written as Elixir maps. Encoding/decoding helpers convert to atoms only after validation; never assume snake_case atoms map 1:1 to JSON keys.

---

## 13. What's NOT in MVP

**See: ADR-0010 for complete list**

**Critical deferrals:**
- ❌ Session ID gating (post-MVP correctness hardening)
- ❌ Async notification dispatch (TaskSupervisor, see ADR-0015)
- ❌ Offload JSON decode pool
- ❌ Connection pooling
- ❌ ETS-based request tracking (see ADR-0013)
- ❌ WebSocket transport
- ❌ Compression / custom HTTP client features (see ADR-0014)
- ❌ Streaming/chunking
- ❌ Request replay after reconnect

**Rationale:** MVP still prioritizes mechanical correctness, but with ADR-0012 we now include the registry + tool-mode groundwork so multi-connection deployments and stateless sessions are first-class. Post-MVP continues to optimize for scale and advanced capabilities (pooling, session ID gating, etc.).

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
