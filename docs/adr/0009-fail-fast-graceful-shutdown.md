# 9. Fail-Fast Graceful Shutdown

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

When `McpClient.stop/1` is called or the supervisor initiates shutdown, the Connection may have in-flight requests awaiting responses. The client must decide: wait for in-flight requests to complete, or fail them immediately?

Waiting is polite to the server but risks hanging shutdown if responses never arrive. Failing immediately is predictable but leaves server-side operations incomplete.

## Decision Drivers

- Predictable shutdown latency (no unbounded waits)
- Clear error semantics for callers
- Prevent shutdown hangs from unresponsive servers
- Simple implementation for MVP
- Standard OTP shutdown pattern
- Idempotent stop operation

## Considered Options

**Option 1: Wait for in-flight requests (graceful drain)**
- Transition to `:draining` state
- Wait up to N seconds for pending responses
- Reply to callers as responses arrive
- Timeout remaining requests after N seconds

**Option 2: Fail-fast (immediate failure)**
- On entering `:closing`, iterate all in-flight requests
- Reply `{:error, :shutdown}` immediately
- Close transport without waiting
- Fast, deterministic shutdown

**Option 3: Best-effort drain**
- Send cancellation for all in-flight requests
- Wait up to 5 seconds for server acks
- Fail remaining after timeout

## Decision Outcome

Chosen option: **Fail-fast immediate failure (Option 2)**, because:

1. **Predictable latency**: Shutdown completes in milliseconds, not seconds
2. **No hangs**: Unresponsive server cannot block shutdown
3. **Clear semantics**: Callers receive explicit `{:error, :shutdown}` error
4. **Simple implementation**: Iterate requests map, send replies, close
5. **Standard OTP pattern**: Supervisor shutdown succeeds within timeout

### Implementation Details

**Stop API is synchronous:**
```elixir
@spec stop(client(), timeout()) :: :ok
def stop(client, timeout \\ 5000) do
  # Internal call returns {:ok, :ok} or {:ok, :already_closing}
  # Public API normalizes to :ok for simplicity (idempotent)
  case GenServer.call(client, :stop, timeout) do
    {:ok, _} -> :ok
  end
end
```

**Return value:** Always `:ok` (idempotent). Internally, Connection replies with `{:ok, :ok}` (first stop) or `{:ok, :already_closing}` (subsequent), but public API normalizes both to `:ok`.

**Transition to `:closing` from any state:**

| Current State | Action on `stop` |
|---------------|------------------|
| `:starting` | Reply `{:ok, :ok}`, exit(normal) → `:closing` |
| `:initializing` | Reply `{:ok, :ok}`, close transport → `:closing` |
| `:ready` | Reply `{:ok, :ok}`, fail in-flight, tombstone all, close → `:closing` |
| `:backoff` | Reply `{:ok, :ok}`, close (no transport) → `:closing` |
| `:closing` | Reply `{:ok, :already_closing}` (idempotent) |

**Implementation in `:ready` state:**
```elixir
def handle_event({:call, from}, :stop, :ready, data) do
  # Reply to stop caller first
  reply = {:reply, from, {:ok, :ok}}

  # Fail all in-flight requests
  shutdown_error = %Error{
    type: :shutdown,
    message: "client shutting down",
    code: nil
  }

  for {id, %{from: req_from}} <- data.requests do
    GenServer.reply(req_from, {:error, shutdown_error})
  end

  # Fail all in-retry requests
  for {id, %{from: req_from}} <- data.retries do
    GenServer.reply(req_from, {:error, shutdown_error})
  end

  # Tombstone IDs to prevent late responses
  data = tombstone_all_requests(data)

  # Clear retry state to cancel pending retry timers
  data = %{data | retries: %{}}

  # Close transport
  Transport.close(data.transport)

  # Emit telemetry
  :telemetry.execute(
    [:mcp_client, :connection, :transition],
    %{},
    %{from: :ready, to: :closing, reason: :stop}
  )

  # Transition to closing (will exit soon)
  {:next_state, :closing, data, [reply, {:state_timeout, 100, :exit}]}
end

def handle_event(:state_timeout, :exit, :closing, _data) do
  {:stop, :normal}
end
```

**Idempotent stop in `:closing`:**
```elixir
def handle_event({:call, from}, :stop, :closing, data) do
  {:keep_state, data, [{:reply, from, {:ok, :already_closing}}]}
end

# Ignore retry timers that fire after entering :closing
def handle_event(:info, {:retry_send, _id, _frame}, :closing, data) do
  {:keep_state, data}  # Drop silently
end

# Ignore request timeouts that fire after entering :closing
def handle_event(:info, {:req_timeout, _id}, :closing, data) do
  {:keep_state, data}  # Drop silently
end
```

**Concurrent stop calls:**
- First call: transitions to `:closing`, fails requests, returns `{:ok, :ok}`
- Subsequent calls: already in `:closing`, returns `{:ok, :already_closing}`
- No caller hangs; all receive response

### Consequences

**Positive:**
- **Fast shutdown**: Completes in < 100ms regardless of server state
- **No hangs**: Unresponsive server doesn't block application shutdown
- **Clear errors**: Callers receive `{:error, :shutdown}`, not timeout
- **Idempotent**: Multiple stop calls are safe
- **OTP-compliant**: Supervisor shutdown succeeds within `:shutdown` timeout
- **Simple**: ~30 lines of code, no drain state or complex timeout logic

**Negative/Risks:**
- **Server-side operations incomplete**: Server may have processed requests but client doesn't wait for responses
  - Example: `call_tool` to write a file succeeds server-side, but client shuts down before receiving confirmation
  - Acceptable: client shutdown is explicit (user intent), not transparent
- **No polite cancellation**: Don't send `$/cancelRequest` for in-flight requests
  - Reason: Server will see connection close immediately anyway
  - Adding cancel messages delays shutdown without benefit

**Neutral:**
- Tombstones prevent late responses from being processed (unlikely, transport closed)
- In-flight requests always receive error, never timeout (shutdown is explicit failure)

## Shutdown Timing

**Typical sequence:**
```
T0: User calls McpClient.stop(client)
T0+1ms: Connection receives :stop call
T0+2ms: Connection replies :ok to stop caller
T0+2ms: Connection replies {:error, :shutdown} to N in-flight requests
T0+3ms: Connection closes transport
T0+4ms: Connection transitions to :closing
T0+104ms: Connection exits normally
Total time: ~104ms
```

**Under supervisor shutdown:**
```
T0: Supervisor.stop(supervisor, :normal)
T0+1ms: Supervisor sends shutdown to Connection child
T0+2ms: Connection handle_info(:shutdown) → calls internal stop
T0+106ms: Connection exits, supervisor shutdown completes
Total time: ~106ms (well within default 5s supervisor shutdown timeout)
```

## User Experience

**Caller waiting for response:**
```elixir
# In one process
task = Task.async(fn ->
  McpClient.call_tool(client, "long_operation", %{})
end)

# In another process
McpClient.stop(client)

# First process receives
{:error, %McpClient.Error{
  type: :shutdown,
  message: "client shutting down"
}}
```

**Application shutdown:**
```elixir
defmodule MyApp.Application do
  def stop(_state) do
    # All supervised McpClient instances will shutdown cleanly
    :ok
  end
end
```

## Alternative Approaches Considered

**Graceful drain with timeout (Option 1):**
```elixir
def handle_event({:call, from}, :stop, :ready, data) do
  data = Map.put(data, :draining, true)
  actions = [
    {:reply, from, :ok},
    {:state_timeout, 5_000, :drain_timeout}
  ]
  {:next_state, :draining, data, actions}
end

def handle_event(:info, {:response, id, result}, :draining, data) do
  # Deliver response to caller
  if Map.empty?(data.requests) do
    # All drained
    {:next_state, :closing, data}
  else
    {:keep_state, data}
  end
end

def handle_event(:state_timeout, :drain_timeout, :draining, data) do
  # Timeout, fail remaining
  {:next_state, :closing, data}
end
```

**Rejected because:**
- Adds `:draining` state (more complexity, more edges in state table)
- Shutdown latency becomes variable (0-5 seconds)
- No guarantee server will respond during drain window
- Server-side operations may be non-transactional (partial completion anyway)

**Best-effort cancel (Option 3):**
- Send `$/cancelRequest` for all in-flight IDs before closing
- Wait briefly for acks
- Fail remaining

**Rejected because:**
- Adds delay without strong benefit (server sees close immediately)
- Cancellation is optional in JSON-RPC (server may ignore)
- Requires state machine to track "cancel sent, waiting for ack"

## Deferred Alternatives

**Configurable drain timeout (post-MVP):**
```elixir
McpClient.start_link([
  # ... other opts
  shutdown_strategy: :drain,  # Default :fail_fast
  shutdown_timeout: 5_000     # Only applies to :drain
])
```

**Deferred because:**
- Adds complexity (new state, new config)
- No user request for this feature
- Fail-fast is safer default (predictable)
- Can add later if use cases emerge (e.g., transactional operations)

**Per-request shutdown handling:**
Allow callers to mark requests as "wait on shutdown":
```elixir
McpClient.call_tool(client, "critical_op", %{}, wait_on_shutdown: true)
```

**Deferred because:**
- Requires tracking per-request flags
- Complicates shutdown logic (some wait, some fail)
- No clear use case (critical ops should use their own persistence/retry)

## Testing

**Unit test: In-flight requests receive shutdown error**
```elixir
test "stop fails in-flight requests" do
  # Start call in background
  task = Task.async(fn ->
    McpClient.call_tool(client, "slow", %{})
  end)

  # Give time for request to be registered
  Process.sleep(10)

  # Stop client
  assert :ok = McpClient.stop(client)

  # Task receives shutdown error
  assert {:error, %Error{type: :shutdown}} = Task.await(task)
end
```

**Unit test: Stop is idempotent**
```elixir
test "multiple stop calls succeed" do
  assert {:ok, :ok} = McpClient.stop(client)
  assert {:ok, :already_closing} = McpClient.stop(client)
  assert {:ok, :already_closing} = McpClient.stop(client)
end
```

**Unit test: Supervisor shutdown completes quickly**
```elixir
test "supervisor shutdown completes within timeout" do
  {:ok, sup} = Supervisor.start_link([
    {McpClient, transport: :test}
  ], strategy: :one_for_one)

  start_time = System.monotonic_time(:millisecond)
  Supervisor.stop(sup, :normal, 5_000)
  duration = System.monotonic_time(:millisecond) - start_time

  assert duration < 500  # Should be ~100ms
end
```

## References

- Design Document 07 (claude), Section 10: "Graceful shutdown behavior undefined"
- Design Document 08 (gpt5.md), Section 10: "Graceful shutdown semantics"
- Design Document 10 (final spec), Section 10: "Graceful shutdown: fail-fast"
- Design Document 12 (claude), Micro-refinement 2: "Concurrent stop/1 calls"
