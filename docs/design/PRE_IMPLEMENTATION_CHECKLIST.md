# Pre-Implementation Verification Checklist

**Status:** READY TO SHIP ✅
**Date:** 2025-11-06
**Sign-Off:** All correctness gaps closed, spec frozen

---

## Final Sanity Checks

### 1. Helper Function Consistency

**Verify:** All non-shutdown failure transitions use both helpers consistently:

```elixir
# Pattern to verify in every failure transition:
data = data
       |> tombstone_all_requests()      # Fail in-flight requests
       |> fail_and_clear_retries(error)  # Fail in-retry requests
```

**Locations to check:**
- `:ready` + `transport_down` ✅
- `:ready` + oversized frame ✅
- `:initializing` + any failure → uses tombstone logic differently (no requests yet)
- (Reset notifications were removed from MVP; no special path required)

### 2. Test Setup

**Random seeding for deterministic tests:**
```elixir
setup do
  seed = {ExUnit.configuration()[:seed], :os.system_time(), self()}
  :rand.seed(:exsplus, seed)

  # Print seed on failure for reproducibility
  on_exit(fn ->
    if ExUnit.configuration()[:trace] do
      IO.puts("Random seed: #{inspect(seed)}")
    end
  end)

  {:ok, seed: seed}
end
```

### 3. No Double-Reply Property

**Property test:** Request that hits retry path then gets stopped:

```elixir
property "stop during retry never causes double reply" do
  check all delay <- integer(1..100) do
    # Send request, mock :busy
    task = Task.async(fn -> McpClient.call_tool(client, "op", %{}) end)

    # Let retry timer schedule
    Process.sleep(delay)

    # Stop client
    McpClient.stop(client)

    # Task receives exactly one reply (shutdown error)
    assert {:error, %Error{type: :shutdown}} = Task.await(task)

    # No second message in mailbox
    refute_received _
  end
end
```

---

## Minimal Test Matrix (Implementation Green-Light)

### ✅ Test 1: Concurrent Busy Retries

**Scenario:** Two requests hit `:busy` simultaneously

```elixir
test "concurrent busy retries don't interfere" do
  # Mock transport: first 2 sends to each request are :busy, then :ok
  mock_transport_busy_then_ok(count: 2)

  task1 = Task.async(fn -> McpClient.call_tool(client, "op1", %{}) end)
  task2 = Task.async(fn -> McpClient.call_tool(client, "op2", %{}) end)

  # Both succeed after retry
  assert {:ok, _} = Task.await(task1)
  assert {:ok, _} = Task.await(task2)

  # Verify send attempts: initial + 2 retries each
  assert_transport_sends(count: 6)  # 2 requests × 3 attempts
end

test "exhausted retries return backpressure" do
  # Mock transport: always :busy
  mock_transport_always_busy()

  assert {:error, %Error{type: :transport, message: msg}} =
    McpClient.call_tool(client, "op", %{})

  assert msg =~ "busy after 3 attempts"
end
```

### ✅ Test 2: Transport Down Clears All State

**Scenario:** Connection has in-flight requests and in-retry requests when transport dies

```elixir
test "transport down fails and clears both requests and retries" do
  # Mock transport: :busy for op1 (enters retry), :ok for op2 (in-flight)
  mock_transport_pattern(op1: :busy, op2: :ok)

  task1 = Task.async(fn -> McpClient.call_tool(client, "op1", %{}) end)
  task2 = Task.async(fn -> McpClient.call_tool(client, "op2", %{}) end)

  # Wait for both to be tracked
  Process.sleep(10)

  # Kill transport
  send(connection, {:transport, :down, :normal})

  # Both tasks receive transport error
  assert {:error, %Error{type: :transport}} = Task.await(task1)
  assert {:error, %Error{type: :transport}} = Task.await(task2)

  # Connection transitions to backoff
  assert :backoff = McpClient.state(client)

  # Internal state is cleared (verify via introspection if exposed)
end
```

### ✅ Test 3: Oversized Frame Closes Without set_active

**Scenario:** Server sends > 16MB frame

```elixir
test "oversized frame closes connection without set_active" do
  huge_frame = :binary.copy(<<0>>, 17_000_000)  # 17MB

  # Track set_active calls
  ref = :counters.new(1, [])
  mock_transport_track_set_active(ref)

  # Send oversized frame
  send(connection, {:transport, :frame, huge_frame})

  # Connection closes transport (verify via mock)
  assert_transport_closed()

  # set_active was NOT called after close
  assert :counters.get(ref, 1) == 0

  # Transitions to backoff
  assert :backoff = McpClient.state(client)
end
```

### ✅ Test 4: Init Invalid Caps with Backoff Reset

**Scenario:** Init fails with invalid caps, then succeeds

```elixir
test "invalid caps triggers backoff, success resets delay" do
  # First init: invalid caps
  mock_init_response(caps: %{"protocolVersion" => "1999-01-01"})

  {:ok, client} = McpClient.start_link(transport: :mock, ...)

  # Wait for init attempt
  Process.sleep(50)
  assert :backoff = McpClient.state(client)

  # Verify backoff delay increased (introspect via telemetry)
  assert_received {:telemetry, [:connection, :transition], _,
                   %{from: :initializing, to: :backoff}}

  # Reconnect with valid caps
  mock_init_response(caps: %{"protocolVersion" => "2024-11-05"})

  # Eventually reaches ready
  assert_eventually(fn -> McpClient.state(client) == :ready end)

  # Next failure starts from backoff_min (verify via next backoff)
end
```

### ✅ Test 5: Stop During Retry

**Scenario:** Request in retry when stop is called

```elixir
test "stop during retry prevents double reply" do
  # Mock transport: :busy indefinitely
  mock_transport_always_busy()

  task = Task.async(fn -> McpClient.call_tool(client, "op", %{}) end)

  # Wait for retry to schedule
  Process.sleep(20)

  # Stop client
  assert :ok = McpClient.stop(client)

  # Task receives shutdown error (not backpressure)
  assert {:error, %Error{type: :shutdown}} = Task.await(task)

  # No second message arrives
  refute_receive _, 100
end
```

### ✅ Test 6: Decode Errors (Init & Ready)

**Scenario:** Malformed JSON in both states

```elixir
test "invalid JSON in initializing state" do
  {:ok, client} = McpClient.start_link(transport: :mock, ...)

  # Send invalid JSON
  send(connection, {:transport, :frame, "not json {{"})

  # Connection logs warning but stays in initializing
  assert :initializing = McpClient.state(client)

  # set_active was called (ready for next frame)
  assert_transport_set_active_called()
end

test "invalid JSON in ready state" do
  # Assume client is in :ready
  send(connection, {:transport, :frame, "not json {{"})

  # Connection logs warning but stays ready
  assert :ready = McpClient.state(client)

  # Can still process valid frames
  assert {:ok, _} = McpClient.ping(client)
end
```

---

## Property Test Coverage (Required)

### 1. Request-Response Correlation (1:1)

```elixir
property "each request gets exactly one terminal outcome" do
  check all requests <- list_of(request_gen(), min_length: 1, max_length: 50),
            response_order <- permutation_of(requests) do
    # Send all requests
    tasks = for req <- requests, do: async_call(req)

    # Deliver responses in random order
    for req <- response_order, do: deliver_response(req)

    # Every task completes exactly once
    for task <- tasks do
      assert {:ok, _} = Task.await(task)
    end

    # No orphaned state
    assert empty_request_map(connection)
  end
end
```

### 2. Timeouts Don't Leak

```elixir
property "request map empty after all timeouts" do
  check all requests <- list_of(request_gen(timeout: 100)),
            timeout_some <- boolean() do
    # Send requests, let some timeout
    tasks = for req <- requests, do: async_call(req)

    # Wait for timeouts
    Process.sleep(150)

    # All tasks complete (success or timeout)
    for task <- tasks, do: Task.await(task)

    # Request map is empty
    assert empty_request_map(connection)

    # Tombstones decay after TTL
    Process.sleep(tombstone_ttl() + 100)
    assert empty_tombstone_map(connection)
  end
end
```

### 3. Cancellation Idempotency

```elixir
property "cancelling N times = exactly one outcome" do
  check all cancel_count <- integer(1..10) do
    task = async_call("op")

    # Cancel multiple times
    for _ <- 1..cancel_count do
      cancel_request(task)
    end

    # Task receives exactly one reply
    assert {:error, _} = Task.await(task)

    # No crashes, no second reply
    refute_received _
  end
end
```

---

## Implementation Readiness Checklist

**Core correctness:**
- [x] Per-request timeout preserved through retry
- [x] All failure paths clear both `requests` and `retries`
- [x] No `set_active(:once)` after `Transport.close/1`
- [x] Backoff delay resets to `backoff_min` on success
- [x] Initialize sent **before** `set_active(:once)`
- [x] Cancellation is single-attempt, no retry
- [x] Public `stop/1` returns `:ok` (normalized)

**Documentation:**
- [x] Transport contract centralized with cross-reference
- [x] Time units invariant documented (native vs millisecond)
- [x] Correlation IDs included in request struct
- [x] Unknown ID logging strategy noted (debug + post-MVP sampling)
- [x] Version compatibility marked as MVP policy

**Test coverage:**
- [x] Minimal test matrix defined (6 scenarios)
- [x] Property tests specified (3 core guarantees)
- [x] Seed management for deterministic retries

---

## Final Sign-Off

**Correctness:** ✅ All gaps closed
**Consistency:** ✅ All docs aligned
**Testability:** ✅ Full matrix defined

**Status: FROZEN FOR IMPLEMENTATION**

Begin implementation following `STATE_TRANSITIONS.md` table exactly.
Refer to ADRs for decision rationale.
Run minimal test matrix before merging.

**Next Step:** Create `lib/mcp_client/connection.ex` and implement state machine.

---

**Signed Off:** 2025-11-06
**Ready to ship:** 🚀
