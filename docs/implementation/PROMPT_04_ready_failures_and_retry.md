# Implementation Prompt 04: Ready State - Failures and Retry Logic

**Goal:** Implement :ready state failure handling, transport busy retry, oversized frames, transport down, and reset notifications.

**Test Strategy:** TDD with rgr. All tests green, no warnings.

---

## Context: What You're Building

You're implementing the failure paths and retry logic for :ready state:
1. **Transport busy retry**: When send returns `:busy`, schedule retry with exponential backoff + jitter
2. **Transport down**: Fail all in-flight and in-retry requests, transition to :backoff
3. **Oversized frames**: Close transport, transition to :backoff
4. **Reset notifications**: Re-initialize connection
5. **Stop during retry**: Clear retry timers, prevent double replies

This is where **concurrent retry correctness** is critical (per-ID retry tracking).

---

## Required Reading: State Transitions

From STATE_TRANSITIONS.md, these are the exact transitions to implement:

### :ready State - Retry Path

| From | Event | Guard | Actions | To |
|------|-------|-------|---------|-----|
| :ready | `{:call, from}, {:request, method, params, opts}` | send returns `:busy` | Generate ID; track in `retries` map with attempt count; schedule retry with jitter; reply `{:ok, id}` | :ready |
| :ready | `{:state_timeout, {:retry_send, id}}` | retry exists, attempts < max | Increment attempts; retry send; if `:ok` → promote to requests with timeout; if `:busy` → reschedule retry; if error → fail request | :ready |
| :ready | `{:state_timeout, {:retry_send, id}}` | retry exists, attempts ≥ max | Reply backpressure error; tombstone; clear retry | :ready |
| :ready | `{:state_timeout, {:retry_send, id}}` | retry cleared (stop) | Ignore | :ready |

### :ready State - Failure Paths

| From | Event | Guard | Actions | To |
|------|-------|-------|---------|-----|
| :ready | `{:info, {:transport, :down, reason}}` | - | Tombstone all requests; **fail/clear retries**; do not re-arm set_active; schedule backoff | :backoff |
| :ready | `{:info, {:transport, :frame, binary}}` | byte_size > max | Log error; close transport (no set_active); **fail/clear retries**; schedule backoff | :backoff |
| :ready | `{:info, {:transport, :frame, binary}}` | reset notification | Close transport (no set_active); **fail/clear retries**; schedule backoff | :initializing |
| :ready | `{:call, from}, :stop` | - | Tombstone all requests; **fail/clear retries**; reply `:ok`; close transport; exit(normal) | - |

### Retry Tracking Structure (from ADR-0007)

```elixir
data.retries :: %{
  id => %{
    frame: binary(),                 # Pre-encoded JSON-RPC
    from: {pid(), reference()},      # For reply
    request: %{...},                 # Full request struct (includes timeout!)
    attempts: non_neg_integer()      # Current attempt count
  }
}
```

**CRITICAL**: Request struct includes `timeout` field so retry can use per-call timeout!

### Retry Configuration (from MVP_SPEC.md)

```elixir
@retry_attempts 3        # Max attempts (initial + 2 retries)
@retry_delay_ms 10       # Base delay
@retry_jitter 0.5        # Jitter factor (±50%)
```

**Jitter formula:**
```elixir
jitter_factor = 1.0 + (:rand.uniform() * 2.0 - 1.0) * @retry_jitter
delay = round(@retry_delay_ms * jitter_factor)
# Range: [5ms, 15ms] for default config
```

---

## Key Requirements from ADRs

### ADR-0007: Bounded Send Retry

**Per-ID retry tracking prevents clobbering:**
```elixir
# CORRECT: Concurrent busy requests each get their own entry
data.retries = %{
  1 => %{frame: frame1, from: from1, request: req1, attempts: 1},
  2 => %{frame: frame2, from: from2, request: req2, attempts: 1}
}
```

**Retry limit:**
- Initial send + 2 retries = 3 attempts total
- On exhaustion: reply with backpressure error

**Backpressure error:**
```elixir
%Error{
  kind: :transport,
  message: "Transport busy after #{@retry_attempts} attempts",
  details: %{request_id: id}
}
```

### Failure Path Helper (from FINAL_CORRECTIONS.md)

**CRITICAL**: All non-shutdown failures must use:
```elixir
defp fail_and_clear_retries(data, error) do
  for {_id, %{from: from}} <- data.retries do
    GenServer.reply(from, {:error, error})
  end
  %{data | retries: %{}}
end
```

### ADR-0009: Shutdown with Retry Clearing

**Stop must:**
1. Fail all in-flight requests
2. Fail all in-retry requests
3. Clear retry map
4. Tombstone all IDs
5. Reply to stop caller

**Retry timers in :closing:**
```elixir
def handle_event(:state_timeout, {:retry_send, _id}, :closing, data) do
  {:keep_state_and_data, []}  # Ignore
end
```

### Cancellation Policy (from STATE_TRANSITIONS.md)

**Cancel requests are not retried:**
```elixir
# Cancel is single-attempt send
# If send fails, skip—tombstone already prevents late delivery
# Avoids re-ordering risks from retry logic
```

---

## Implementation Requirements

### 1. Add Retry Configuration

```elixir
@retry_attempts 3
@retry_delay_ms 10
@retry_jitter 0.5
```

### 2. Update Request Handling for Busy Path

Modify the handle_event for `{:call, from}, {:request, method, params, opts}` from Prompt 03:

```elixir
def handle_event({:call, from}, {:request, method, params, opts}, :ready, data) do
  id = generate_request_id(data)
  corr_id = :crypto.strong_rand_bytes(8)
  timeout = opts[:timeout] || @default_request_timeout

  # Build JSON-RPC request
  request_json = %{
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => method,
    "params" => params
  }

  frame = Jason.encode!(request_json)

  # Build request struct (for tracking or retry)
  request = %{
    from: from,
    started_at_mono: System.monotonic_time(),
    timeout: timeout,
    method: method,
    corr_id: corr_id
  }

  case Transport.send_frame(data.transport, frame) do
    :ok ->
      # Track request normally
      data = Map.update!(data, :requests, &Map.put(&1, id, request))
      actions = [{:state_timeout, timeout, {:request_timeout, id}}]
      {:keep_state, data, [{:reply, from, {:ok, id}} | actions]}

    :busy ->
      # Enter retry path
      retry_state = %{
        frame: frame,
        from: from,
        request: request,
        attempts: 1
      }
      data = Map.update!(data, :retries, &Map.put(&1, id, retry_state))

      delay = compute_retry_delay()
      actions = [{:state_timeout, delay, {:retry_send, id}}]

      {:keep_state, data, [{:reply, from, {:ok, id}} | actions]}

    {:error, reason} ->
      # Send failed permanently
      error = %{kind: :transport, message: "Send failed: #{inspect(reason)}"}
      {:keep_state_and_data, [{:reply, from, {:error, error}}]}
  end
end
```

### 3. Implement Retry Logic

```elixir
def handle_event(:state_timeout, {:retry_send, id}, :ready, data) do
  case Map.get(data.retries, id) do
    nil ->
      # Retry cleared (e.g., during stop) - ignore
      {:keep_state_and_data, []}

    retry_state ->
      handle_retry_attempt(id, retry_state, data)
  end
end

defp handle_retry_attempt(id, retry_state, data) do
  %{frame: frame, from: from, request: request, attempts: attempts} = retry_state

  if attempts >= @retry_attempts do
    # Exhausted retries - fail with backpressure
    error = %{
      kind: :transport,
      message: "Transport busy after #{@retry_attempts} attempts",
      details: %{request_id: id}
    }
    GenServer.reply(from, {:error, error})

    # Tombstone and clear retry
    data = tombstone_request(data, id)
    data = Map.update!(data, :retries, &Map.delete(&1, id))

    {:keep_state, data}
  else
    # Retry send
    case Transport.send_frame(data.transport, frame) do
      :ok ->
        # Success! Promote to in-flight request
        data = Map.update!(data, :retries, &Map.delete(&1, id))
        data = Map.update!(data, :requests, &Map.put(&1, id, request))

        # Use stored timeout from request
        timeout_action = {:state_timeout, request.timeout, {:request_timeout, id}}
        {:keep_state, data, [timeout_action]}

      :busy ->
        # Still busy, schedule next retry
        new_attempts = attempts + 1
        retry_state = %{retry_state | attempts: new_attempts}
        data = Map.update!(data, :retries, &Map.put(&1, id, retry_state))

        delay = compute_retry_delay()
        {:keep_state, data, [{:state_timeout, delay, {:retry_send, id}}]}

      {:error, reason} ->
        # Permanent failure
        error = %{
          kind: :transport,
          message: "Send failed: #{inspect(reason)}",
          details: %{request_id: id, attempt: attempts}
        }
        GenServer.reply(from, {:error, error})

        # Tombstone and clear retry
        data = tombstone_request(data, id)
        data = Map.update!(data, :retries, &Map.delete(&1, id))

        {:keep_state, data}
    end
  end
end

defp compute_retry_delay do
  jitter_factor = 1.0 + (:rand.uniform() * 2.0 - 1.0) * @retry_jitter
  round(@retry_delay_ms * jitter_factor)
end
```

### 4. Implement Failure Helpers

```elixir
defp tombstone_all_requests(data) do
  now = System.monotonic_time(:millisecond)
  tombstone = %{inserted_at_mono: now, ttl_ms: data.tombstone_ttl_ms}

  new_tombstones =
    Map.keys(data.requests)
    |> Enum.into(%{}, fn id -> {id, tombstone} end)

  data
  |> Map.update!(:tombstones, &Map.merge(&1, new_tombstones))
  |> Map.put(:requests, %{})
end

defp fail_and_clear_retries(data, error) do
  for {_id, %{from: from}} <- data.retries do
    GenServer.reply(from, {:error, error})
  end
  %{data | retries: %{}}
end
```

### 5. Implement Transport Down

```elixir
def handle_event(:info, {:transport, :down, reason}, :ready, data) do
  Logger.error("Transport down in ready: #{inspect(reason)}")

  # Fail all in-flight requests
  error = %{kind: :transport, message: "Transport down: #{inspect(reason)}"}
  for {_id, %{from: from}} <- data.requests do
    GenServer.reply(from, {:error, error})
  end

  # Tombstone and clear requests
  data = tombstone_all_requests(data)

  # Fail and clear retries
  data = fail_and_clear_retries(data, error)

  # Schedule backoff (do not call set_active)
  {:next_state, :backoff, data, schedule_backoff_action(data)}
end
```

### 6. Implement Reset Notification

```elixir
# Add to process_ready_frame/2:
defp process_ready_frame(%{"method" => "notifications/cancelled"}, data) do
  # Handle cancellation notification if needed
  data
end

defp process_ready_frame(%{"method" => method}, data) when method in [
  "$/reset",
  "notifications/reset"  # Or whatever the spec defines
] do
  Logger.warning("Received reset notification - re-initializing")

  # Fail all requests and retries
  error = %{kind: :reset, message: "Connection reset by server"}
  for {_id, %{from: from}} <- data.requests do
    GenServer.reply(from, {:error, error})
  end

  data = tombstone_all_requests(data)
  data = fail_and_clear_retries(data, error)

  # Close transport and transition to initializing
  Transport.close(data.transport)
  # Return marker to trigger state transition
  {:reset_transition, data}
end

# Update handle_event to handle reset:
def handle_event(:info, {:transport, :frame, binary}, :ready, data) do
  case Jason.decode(binary) do
    {:ok, json} ->
      case process_ready_frame(json, data) do
        {:reset_transition, new_data} ->
          # Transition to initializing with backoff
          {:next_state, :initializing, new_data, schedule_backoff_action(new_data)}

        new_data ->
          :ok = Transport.set_active(data.transport, :once)
          {:keep_state, new_data}
      end

    {:error, reason} ->
      Logger.warning("Invalid JSON in ready: #{inspect(reason)}")
      :ok = Transport.set_active(data.transport, :once)
      {:keep_state_and_data, []}
  end
end
```

### 7. Update Stop Handling

```elixir
def handle_event({:call, from}, :stop, :ready, data) do
  Logger.info("Stopping connection")

  # Fail all in-flight requests
  error = %{kind: :shutdown, message: "Connection stopped"}
  for {_id, %{from: req_from}} <- data.requests do
    GenServer.reply(req_from, {:error, error})
  end

  # Fail all in-retry requests
  for {_id, %{from: req_from}} <- data.retries do
    GenServer.reply(req_from, {:error, error})
  end

  # Tombstone and clear
  data = tombstone_all_requests(data)
  data = %{data | retries: %{}}

  # Close transport
  Transport.close(data.transport)

  # Reply to caller and exit
  {:stop_and_reply, :normal, [{:reply, from, :ok}]}
end

# In :closing state (or handle stop in other states):
def handle_event(:state_timeout, {:retry_send, _id}, :closing, _data) do
  # Ignore retry timers after shutdown initiated
  {:keep_state_and_data, []}
end
```

---

## Test File: test/mcp_client/connection_test.exs

Add these tests:

```elixir
describe ":ready state - retry logic" do
  setup do
    # Setup connection in :ready state (same as Prompt 03)
    {:ok, pid} = Connection.start_link(transport: :mock)
    # ... transition to :ready ...
    {:ok, connection: pid}
  end

  test "handles transport busy with retry", %{connection: conn} do
    # Configure mock transport to return :busy then :ok
    # (MockTransport needs to be enhanced)

    task = Task.async(fn ->
      :gen_statem.call(conn, {:request, "test", %{}, []})
    end)

    # Should get request ID back immediately
    assert {:ok, id} = Task.await(task)

    # Retry should eventually succeed
    # (Test needs to verify retry happened via telemetry or mock tracking)
  end

  test "fails after max retry attempts", %{connection: conn} do
    # Configure mock to always return :busy

    task = Task.async(fn ->
      {:ok, _id} = :gen_statem.call(conn, {:request, "test", %{}, []})

      receive do
        msg -> msg
      after
        1000 -> :timeout
      end
    end)

    # Should eventually receive backpressure error
    assert {:error, %{kind: :transport, message: msg}} = Task.await(task)
    assert msg =~ "busy after 3 attempts"
  end

  test "concurrent busy requests don't interfere", %{connection: conn} do
    # Make two concurrent requests that both hit busy path
    task1 = Task.async(fn ->
      :gen_statem.call(conn, {:request, "test1", %{}, []})
    end)

    task2 = Task.async(fn ->
      :gen_statem.call(conn, {:request, "test2", %{}, []})
    end)

    # Both should get unique IDs
    assert {:ok, id1} = Task.await(task1)
    assert {:ok, id2} = Task.await(task2)
    assert id1 != id2

    # Both should eventually complete (not clobber each other)
  end

  test "preserves per-request timeout through retry", %{connection: conn} do
    # Make request with custom timeout
    task = Task.async(fn ->
      :gen_statem.call(conn, {:request, "test", %{}, timeout: 60_000})
    end)

    {:ok, id} = Task.await(task)

    # After retry completes, timeout should still be 60s, not default 30s
    # (Verify via state introspection or timeout event)
  end
end

describe ":ready state - failure paths" do
  setup do
    # Setup connection in :ready state
    {:ok, pid} = Connection.start_link(transport: :mock)
    # ... transition to :ready ...
    {:ok, connection: pid}
  end

  test "transport down fails all requests and retries", %{connection: conn} do
    # Make one request in flight
    task1 = Task.async(fn ->
      {:ok, _id} = :gen_statem.call(conn, {:request, "test1", %{}, []})
      receive do
        msg -> msg
      after
        1000 -> :timeout
      end
    end)

    # Make one request in retry (mock busy)
    task2 = Task.async(fn ->
      {:ok, _id} = :gen_statem.call(conn, {:request, "test2", %{}, []})
      receive do
        msg -> msg
      after
        1000 -> :timeout
      end
    end)

    Process.sleep(10)

    # Kill transport
    send(conn, {:transport, :down, :normal})

    # Both should receive transport error
    assert {:error, %{kind: :transport}} = Task.await(task1)
    assert {:error, %{kind: :transport}} = Task.await(task2)
  end

  test "oversized frame closes connection", %{connection: conn} do
    huge_frame = :binary.copy(<<0>>, 17_000_000)  # 17MB

    send(conn, {:transport, :frame, huge_frame})

    # Should transition to backoff
    Process.sleep(10)
    # Verify via state query (needs API)
  end

  test "reset notification re-initializes", %{connection: conn} do
    # Make a request
    task = Task.async(fn ->
      {:ok, _id} = :gen_statem.call(conn, {:request, "test", %{}, []})
      receive do
        msg -> msg
      after
        1000 -> :timeout
      end
    end)

    Process.sleep(10)

    # Send reset notification
    reset = %{
      "jsonrpc" => "2.0",
      "method" => "$/reset",
      "params" => %{}
    }
    send(conn, {:transport, :frame, Jason.encode!(reset)})

    # Request should fail
    assert {:error, %{kind: :reset}} = Task.await(task)

    # Connection should transition to initializing
    # (Verify via state query)
  end
end

describe "stop during retry" do
  setup do
    {:ok, pid} = Connection.start_link(transport: :mock)
    # ... transition to :ready ...
    {:ok, connection: pid}
  end

  test "prevents double reply", %{connection: conn} do
    # Make request that enters retry
    task = Task.async(fn ->
      {:ok, _id} = :gen_statem.call(conn, {:request, "test", %{}, []})
      receive do
        msg -> msg
      after
        1000 -> :timeout
      end
    end)

    # Wait for retry to schedule
    Process.sleep(20)

    # Stop connection
    assert :ok = :gen_statem.call(conn, :stop)

    # Task should receive shutdown error (not backpressure)
    assert {:error, %{kind: :shutdown}} = Task.await(task)

    # No second message
    refute_receive _, 100
  end

  test "ignores retry timers in closing", %{connection: conn} do
    # Make request that enters retry
    {:ok, _id} = :gen_statem.call(conn, {:request, "test", %{}, []})

    # Stop
    :gen_statem.call(conn, :stop)

    # Manually trigger retry timer (shouldn't happen but test robustness)
    send(conn, {:state_timeout, {:retry_send, 1}})

    # Should not crash
    refute Process.alive?(conn)  # Already stopped
  end
end
```

---

## Success Criteria

Run tests with:
```bash
mix test test/mcp_client/connection_test.exs
```

**Must achieve:**
- ✅ All tests pass (green)
- ✅ No warnings
- ✅ Retry logic handles concurrent requests correctly
- ✅ Per-request timeout preserved through retry
- ✅ Failure paths clear both requests and retries
- ✅ Stop during retry prevents double replies
- ✅ No set_active after close operations

---

## Constraints

- **DO NOT** implement :backoff state yet (Prompt 05)
- **DO NOT** implement cancellation API yet
- **DO NOT** add features beyond spec
- Retry attempts: exactly 3 (initial + 2 retries)
- Jitter range: [5ms, 15ms] for default config
- Use exact error shapes from spec

---

## Implementation Notes

### Concurrent Retry Correctness

The per-ID retry map ensures:
- Request ID 1 busy → stored in `data.retries[1]`
- Request ID 2 busy → stored in `data.retries[2]`
- Each has independent timer: `{:retry_send, 1}` and `{:retry_send, 2}`
- No clobbering possible

### Timeout Preservation

**CRITICAL**: Request struct stored in retry state includes `timeout` field:
```elixir
retry_state = %{
  frame: frame,
  from: from,
  request: request,  # ← Contains timeout: 60_000
  attempts: 1
}

# On promote to in-flight:
{:state_timeout, request.timeout, {:request_timeout, id}}
```

### Reset Notification Method

The spec uses `$/reset` for protocol reset. Verify exact method name in MCP spec and adjust if needed.

### MockTransport Enhancement

For testing busy/retry path, MockTransport needs to support returning `:busy`:
```elixir
# In test setup:
MockTransport.configure(send_response: :busy, count: 2)  # Busy twice, then ok
```

---

## Deliverable

Provide the updated `lib/mcp_client/connection.ex` that:
1. Implements retry logic with per-ID tracking
2. Preserves per-request timeout through retry
3. Clears both requests and retries on all failure paths
4. Handles stop during retry without double replies
5. Never calls set_active after close
6. Passes all tests
7. Compiles without warnings

If any requirement is unclear, insert `# TODO: <reason>` and stop.
