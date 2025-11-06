# 7. Bounded Send Retry for Busy Transport

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

When the Connection attempts to send a JSON-RPC frame via `Transport.send_frame/2`, the transport may return `{:error, :busy}` if its internal buffer is saturated. The Connection must decide: should it retry, fail immediately, or block?

Failing immediately pushes retry logic to every caller. Blocking violates the non-blocking transport contract. A bounded inline retry provides the best UX without adding external retry infrastructure.

## Decision Drivers

- Avoid pushing retry complexity to every API caller
- Keep transport non-blocking (no indefinite waits)
- Bounded retry attempts (fail eventually)
- Inline retry in Connection (no separate retry process)
- Use gen_statem timeouts (no manual timers)
- Provide clear error when retry exhausted

## Considered Options

**Option 1: No retry - fail immediately**
- Return `{:error, :busy}` to caller on first failure
- Caller must implement retry logic
- Simple but poor UX

**Option 2: Bounded inline retry in Connection**
- Retry N times with small delay between attempts
- Use gen_statem `:state_timeout` for retry scheduling
- Return `{:error, :backpressure}` if all retries fail

**Option 3: Separate retry process**
- Spawn retry worker for each busy send
- Add complexity and process overhead

**Option 4: Block until transport ready**
- Call `send_frame` in loop until success
- Violates non-blocking contract, risks deadlock

## Decision Outcome

Chosen option: **Bounded inline retry in Connection (Option 2)**, because:

1. **Good UX**: Callers don't need retry logic for transient busy conditions
2. **Bounded**: After 3 attempts (1 initial + 2 retries), fail with clear error
3. **Non-blocking**: Uses gen_statem timeout, doesn't block connection
4. **Deterministic**: Fixed retry count and delay (with jitter)
5. **Minimal code**: ~20 lines in Connection, no extra processes

### Implementation Details

**Configuration:**
```elixir
@retry_attempts 3           # Total attempts (initial + 2 retries)
@retry_delay_ms 10          # Base delay in milliseconds
@retry_jitter 0.5           # ±50% jitter
```

**Jitter calculation:**
```elixir
defp jitter(ms, factor) do
  # Seed :rand in init/1 with {:node(), self(), System.monotonic_time()}
  scale = 1.0 + (:rand.uniform() - 0.5) * (factor * 2.0)
  max(0, round(ms * scale))
end

# Example: jitter(10, 0.5) → 5-15ms
```

**Initial send attempt:**
```elixir
def handle_event({:call, from}, {:call_tool, name, args, opts}, :ready, data) do
  id = next_id()
  frame = encode_request(id, "tools/call", %{name: name, arguments: args})

  case Transport.send_frame(data.transport, frame) do
    :ok ->
      # Success - start request timeout
      request = %{from: from, method: "tools/call", ...}
      data = put_in(data.requests[id], request)
      actions = [{:state_timeout, opts[:timeout] || 30_000, {:request_timeout, id}}]
      {:keep_state, data, actions}

    {:error, :busy} ->
      # First failure - schedule retry
      retry_state = %{id: id, frame: frame, from: from, attempts: 1}
      data = Map.put(data, :retry, retry_state)
      delay = jitter(@retry_delay_ms, @retry_jitter)
      actions = [{:state_timeout, delay, :retry_send}]
      {:keep_state, data, actions}

    {:error, reason} ->
      # Fatal error - fail immediately
      reply = {:reply, from, {:error, %Error{kind: :transport, message: "send failed"}}}
      {:keep_state, data, [reply]}
  end
end
```

**Retry handler:**
```elixir
def handle_event(:state_timeout, :retry_send, :ready, data) do
  %{id: id, frame: frame, from: from, attempts: attempts} = data.retry

  case Transport.send_frame(data.transport, frame) do
    :ok ->
      # Retry succeeded - start request tracking
      request = %{from: from, ...}
      data = data
             |> Map.delete(:retry)
             |> put_in([:requests, id], request)
      actions = [{:state_timeout, 30_000, {:request_timeout, id}}]
      {:keep_state, data, actions}

    {:error, :busy} when attempts < @retry_attempts ->
      # Still busy, retry again
      data = put_in(data.retry.attempts, attempts + 1)
      delay = jitter(@retry_delay_ms, @retry_jitter)
      actions = [{:state_timeout, delay, :retry_send}]
      {:keep_state, data, actions}

    {:error, :busy} ->
      # Exhausted retries - fail with backpressure error
      data = Map.delete(data, :retry)
      error = %Error{
        kind: :transport,
        message: "transport busy after #{@retry_attempts} attempts",
        data: %{retries: attempts}
      }
      {:keep_state, data, [{:reply, from, {:error, error}}]}

    {:error, reason} ->
      # Fatal error
      data = Map.delete(data, :retry)
      error = %Error{kind: :transport, message: "send failed: #{inspect(reason)}"}
      {:keep_state, data, [{:reply, from, {:error, error}}]}
  end
end
```

**Error returned to caller after exhausted retries:**
```elixir
{:error, %McpClient.Error{
  kind: :transport,
  message: "transport busy after 3 attempts",
  data: %{retries: 3}
}}
```

### Consequences

**Positive:**
- Callers don't need retry logic for common transient busy conditions
- Bounded retry (no infinite loops)
- Non-blocking (uses timeout, not busy loop)
- Clear error when retry exhausted
- Minimal memory (single retry state in Connection data)

**Negative/Risks:**
- Only one request can be in retry at a time (MVP limitation)
  - If send fails during retry, new request must wait or also fail
  - Acceptable for MVP (rare to have sustained transport saturation)
- Retry delay blocks new requests (Connection is in `:ready` but processing retry)
  - Mitigated by: short delay (10ms), jittered to avoid thundering herd

**Neutral:**
- Retry count and delay are fixed (not configurable in MVP)
- Jitter prevents synchronized retries across multiple connections

## Retry Timing

**Best case (immediate success):**
```
T0: send_frame → :ok
Total time: ~0ms overhead
```

**Worst case (3 attempts, all busy):**
```
T0: send_frame → :busy
T0+7ms: retry 1 → :busy  (jittered 10±50% → ~7ms)
T0+23ms: retry 2 → :busy (jittered 10±50% → ~13ms)
T0+23ms: return {:error, :backpressure}
Total time: ~23ms + send_frame latency
```

**Typical case (busy, then success):**
```
T0: send_frame → :busy
T0+12ms: retry 1 → :ok
Total time: ~12ms + send_frame latency
```

## Alternative Approaches Considered

**Exponential backoff**: Retry delays increase (10ms, 20ms, 40ms)
- **Rejected**: Transport busy is usually transient; fast retries more appropriate
- Would increase worst-case latency unnecessarily

**Configurable retry count**: Allow users to set retry attempts
- **Deferred**: Adds config complexity; fixed value works for MVP
- Can add `send_retry_attempts` config post-MVP if needed

**Separate retry queue**: Queue failed sends, process in background
- **Rejected**: Adds state complexity and can reorder requests
- Violates principle of minimal hidden queuing

## Deferred Alternatives

**Per-method retry policies (post-MVP)**: Allow different retry strategies for different call types:

```elixir
config :mcp_client,
  retry_policies: %{
    "tools/call" => [attempts: 5, delay: 20],
    "resources/read" => [attempts: 3, delay: 10],
    "sampling/createMessage" => [attempts: 1, delay: 0]  # Fail fast
  }
```

**Deferred because:**
- Adds configuration complexity
- MVP uses uniform policy for all requests
- No evidence yet that different methods need different strategies

## Testing

**Unit test: Retry success on second attempt**
```elixir
test "retries once on busy, succeeds" do
  # Mock transport: :busy first call, :ok second call
  assert {:ok, result} = McpClient.call_tool(client, "test", %{})
  assert_received {:transport_send, _frame}  # Initial
  assert_received {:transport_send, _frame}  # Retry
  refute_received {:transport_send, _frame}  # No third attempt
end
```

**Unit test: Exhausted retries**
```elixir
test "returns error after 3 busy responses" do
  # Mock transport: always :busy
  assert {:error, %Error{kind: :transport, message: msg}} =
    McpClient.call_tool(client, "test", %{})
  assert msg =~ "busy after 3 attempts"
end
```

**Property test: Retry is deterministic**
```elixir
property "retry count matches configuration" do
  check all busy_count <- integer(1..5) do
    # Mock returns :busy N times, then :ok
    expected_send_count = min(busy_count + 1, @retry_attempts)
    # Verify exact number of send attempts
  end
end
```

## References

- Design Document 07 (claude), Section 3: "`:busy` with no retry is a footgun"
- Design Document 08 (gpt5.md), Section 3: "`:busy` handling (transport backpressure)"
- Design Document 10 (final spec), Section 3: "`:busy` handling (transport backpressure)"
- Design Document 06 (gemini), Section 5: "Transport Contract: `send_frame/2` Busy-Wait Retry"
