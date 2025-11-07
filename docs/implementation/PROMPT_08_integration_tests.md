# Implementation Prompt 08: Integration Tests and Final Verification

**Goal:** Create comprehensive integration tests that verify the complete system working together, including the critical test scenarios from PRE_IMPLEMENTATION_CHECKLIST.md.

**Test Strategy:** Full integration tests with real components. All tests green, no warnings.

---

## Context: What You're Building

You're implementing the final integration tests that verify:
1. **Full request/response cycle** with all components
2. **Concurrent busy retries** don't interfere
3. **Transport down** clears all state correctly
4. **Oversized frames** are rejected properly
5. **Stop during retry** prevents double replies
6. **All failure paths** work correctly

These tests validate the entire system working together, not just individual units.

---

## Required Reading: Critical Test Scenarios

From PRE_IMPLEMENTATION_CHECKLIST.md, these are the MUST-PASS scenarios:

### Test 1: Concurrent Busy Retries

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
```

### Test 2: Transport Down Clears All State

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
  assert {:error, %Error{kind: :transport}} = Task.await(task1)
  assert {:error, %Error{kind: :transport}} = Task.await(task2)
end
```

### Test 3: Oversized Frame Without set_active

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
end
```

### Test 4: Stop During Retry

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
  assert {:error, %Error{kind: :shutdown}} = Task.await(task)

  # No second message arrives
  refute_receive _, 100
end
```

### Test 5: Invalid Caps with Backoff

**Scenario:** Init fails with invalid caps, then succeeds

```elixir
test "invalid caps triggers backoff, success resets delay" do
  # First init: invalid caps
  mock_init_response(caps: %{"protocolVersion" => "1999-01-01"})

  {:ok, client} = McpClient.start_link(transport: :mock, ...)

  # Wait for init attempt
  Process.sleep(50)
  # Connection should be in :backoff

  # Reconnect with valid caps
  mock_init_response(caps: %{"protocolVersion" => "2024-11-05"})

  # Eventually reaches ready
  assert_eventually(fn -> get_state(client) == :ready end)
end
```

### Test 6: Decode Errors

**Scenario:** Malformed JSON in both states

```elixir
test "invalid JSON in initializing state" do
  {:ok, client} = McpClient.start_link(transport: :mock, ...)

  # Send invalid JSON
  send(connection, {:transport, :frame, "not json {{"})

  # Connection logs warning but stays in initializing
  # set_active was called (ready for next frame)
  assert_transport_set_active_called()
end
```

---

## Implementation Requirements

### 1. Enhanced Mock Transport

Update MockTransport to support:
- Per-request send behavior (busy/ok patterns)
- Call tracking (count set_active calls, send_frame calls)
- Close detection

**File: `test/support/mock_transport.ex` (UPDATE)**

```elixir
defmodule McpClient.MockTransport do
  # ... (existing code)

  defstruct [
    :connection,
    :send_behavior,
    :active,
    :send_count,
    :set_active_count,
    :closed
  ]

  ## Add call tracking

  def get_send_count(pid) do
    GenServer.call(pid, :get_send_count)
  end

  def get_set_active_count(pid) do
    GenServer.call(pid, :get_set_active_count)
  end

  def closed?(pid) do
    GenServer.call(pid, :closed?)
  end

  ## Update handlers

  @impl true
  def init(opts) do
    # ... existing ...
    state = %__MODULE__{
      # ...
      set_active_count: 0,
      closed: false
    }
    {:ok, state}
  end

  def handle_call(:get_send_count, _from, state) do
    {:reply, state.send_count, state}
  end

  def handle_call(:get_set_active_count, _from, state) do
    {:reply, state.set_active_count, state}
  end

  def handle_call(:closed?, _from, state) do
    {:reply, state.closed, state}
  end

  def handle_call(:close, _from, state) do
    send(state.connection, {:transport, :down, :normal})
    state = %{state | closed: true}
    {:stop, :normal, :ok, state}
  end

  def handle_cast({:set_active, mode}, state) do
    state = %{state | active: mode, set_active_count: state.set_active_count + 1}
    {:noreply, state}
  end
end
```

### 2. Integration Test Suite

**File: `test/mcp_client/integration_test.exs`**

```elixir
defmodule McpClient.IntegrationTest do
  use ExUnit.Case, async: false  # Some tests manipulate processes

  alias McpClient.{Error, MockTransport}

  setup do
    # Start mock transport with configurable behavior
    {:ok, client} = McpClient.start_link(
      transport: :mock,
      command: "test",
      retry_attempts: 3,
      retry_delay_ms: 5  # Fast retries for testing
    )

    # Wait for connection to be ready
    wait_for_ready(client)

    {:ok, client: client}
  end

  describe "concurrent busy retries" do
    test "don't interfere with each other", %{client: client} do
      # Configure mock: first 2 sends are :busy, then :ok
      transport = get_transport(client)
      send_pattern = fn count ->
        if count < 2, do: :busy, else: :ok
      end
      MockTransport.configure(transport, send_behavior: send_pattern)

      # Make two concurrent requests
      task1 = Task.async(fn ->
        McpClient.call_tool(client, "op1", %{})
      end)

      task2 = Task.async(fn ->
        McpClient.call_tool(client, "op2", %{})
      end)

      # Both should eventually succeed
      assert {:ok, _} = Task.await(task1, 1000)
      assert {:ok, _} = Task.await(task2, 1000)

      # Verify total send attempts: 2 requests × 3 attempts = 6
      send_count = MockTransport.get_send_count(transport)
      assert send_count == 6
    end

    test "exhausted retries return backpressure error", %{client: client} do
      # Configure mock: always :busy
      transport = get_transport(client)
      MockTransport.configure(transport, send_behavior: :busy)

      result = McpClient.call_tool(client, "op", %{})

      assert {:error, %Error{kind: :transport, message: msg}} = result
      assert msg =~ "busy after 3 attempts"
    end
  end

  describe "transport down" do
    test "fails and clears both requests and retries", %{client: client} do
      transport = get_transport(client)

      # Configure: first request gets :busy (enters retry)
      MockTransport.configure(transport, send_behavior: fn count ->
        if count == 0, do: :busy, else: :ok
      end)

      # Start two requests
      task1 = Task.async(fn ->
        McpClient.call_tool(client, "op1", %{})
      end)

      # Let first request enter retry
      Process.sleep(10)

      task2 = Task.async(fn ->
        McpClient.call_tool(client, "op2", %{})
      end)

      # Let second request send
      Process.sleep(10)

      # Kill transport
      connection = get_connection(client)
      send(connection, {:transport, :down, :test_failure})

      # Both should receive transport error
      assert {:error, %Error{kind: :transport}} = Task.await(task1)
      assert {:error, %Error{kind: :transport}} = Task.await(task2)
    end
  end

  describe "oversized frame" do
    test "closes connection without set_active", %{client: client} do
      transport = get_transport(client)
      connection = get_connection(client)

      initial_set_active_count = MockTransport.get_set_active_count(transport)

      # Send 17MB frame
      huge_frame = :binary.copy(<<0>>, 17_000_000)
      send(connection, {:transport, :frame, huge_frame})

      # Wait for processing
      Process.sleep(50)

      # Transport should be closed
      assert MockTransport.closed?(transport)

      # set_active should NOT have been called after oversized frame
      final_count = MockTransport.get_set_active_count(transport)
      assert final_count == initial_set_active_count
    end
  end

  describe "stop during retry" do
    test "prevents double reply", %{client: client} do
      transport = get_transport(client)

      # Configure: always :busy
      MockTransport.configure(transport, send_behavior: :busy)

      # Start request (will enter retry)
      task = Task.async(fn ->
        McpClient.call_tool(client, "op", %{})
      end)

      # Wait for retry to schedule
      Process.sleep(30)

      # Stop client
      assert :ok = McpClient.stop(client)

      # Task should receive shutdown error
      assert {:error, %Error{kind: :shutdown}} = Task.await(task)

      # No second message
      refute_receive _, 100
    end
  end

  describe "invalid capabilities" do
    test "triggers backoff, success resets delay" do
      # This test needs to control init response
      # For now, skip or use manual mocking
    end
  end

  describe "decode errors" do
    test "invalid JSON in initializing" do
      # Start new connection
      {:ok, client} = McpClient.start_link(
        transport: :mock,
        command: "test"
      )

      connection = get_connection(client)

      # Send transport up
      send(connection, {:transport, :up})

      # Send invalid JSON
      send(connection, {:transport, :frame, "not json {{"})

      # Should not crash
      Process.sleep(10)
      assert Process.alive?(connection)

      McpClient.stop(client)
    end

    test "invalid JSON in ready", %{client: client} do
      connection = get_connection(client)

      # Send invalid JSON
      send(connection, {:transport, :frame, "not json {{"})

      # Should log warning but stay ready
      Process.sleep(10)
      assert Process.alive?(connection)

      # Can still process valid requests
      assert {:ok, _} = McpClient.ping(client)
    end
  end

  describe "full request lifecycle" do
    test "successful tool call", %{client: client} do
      # Mock response
      transport = get_transport(client)
      connection = get_connection(client)

      # Start request
      task = Task.async(fn ->
        McpClient.call_tool(client, "get_weather", %{"city" => "NYC"})
      end)

      # Wait for request to be sent
      Process.sleep(10)

      # Send response
      response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"temperature" => 72}
      }
      send(connection, {:transport, :frame, Jason.encode!(response)})

      # Task should complete
      assert {:ok, %{"temperature" => 72}} = Task.await(task)
    end

    test "server error response", %{client: client} do
      connection = get_connection(client)

      task = Task.async(fn ->
        McpClient.call_tool(client, "invalid_tool", %{})
      end)

      Process.sleep(10)

      # Send error response
      response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => %{"code" => -32601, "message" => "Method not found"}
      }
      send(connection, {:transport, :frame, Jason.encode!(response)})

      assert {:error, %Error{kind: :server, message: "Method not found"}} =
        Task.await(task)
    end

    test "request timeout", %{client: client} do
      connection = get_connection(client)

      # Make request with short timeout
      task = Task.async(fn ->
        McpClient.call_tool(client, "slow_op", %{}, timeout: 100)
      end)

      # Don't send response - let it timeout
      assert {:error, %Error{kind: :timeout}} = Task.await(task, 200)
    end
  end

  describe "tombstones" do
    test "prevent late responses", %{client: client} do
      connection = get_connection(client)

      # Make request
      task = Task.async(fn ->
        McpClient.call_tool(client, "op", %{}, timeout: 50)
      end)

      # Let it timeout
      assert {:error, %Error{kind: :timeout}} = Task.await(task)

      # Send late response
      response = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"data" => "late"}
      }
      send(connection, {:transport, :frame, Jason.encode!(response)})

      # Should be ignored (no crash)
      Process.sleep(10)
      assert Process.alive?(connection)
    end
  end

  ## Helpers

  defp wait_for_ready(client) do
    # Send init sequence manually
    connection = get_connection(client)

    send(connection, {:transport, :up})
    Process.sleep(10)

    init_response = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "test", "version" => "1.0"}
      }
    }
    send(connection, {:transport, :frame, Jason.encode!(init_response)})
    Process.sleep(10)
  end

  defp get_connection(client) do
    # If client is supervisor, get Connection PID
    # For MVP (no supervisor), client IS the connection
    client
  end

  defp get_transport(client) do
    # Get transport PID from connection state
    :sys.get_state(client).transport
  end
end
```

---

## Success Criteria

Run tests with:
```bash
mix test test/mcp_client/integration_test.exs
```

**Must achieve:**
- ✅ All critical tests pass (6 scenarios from checklist)
- ✅ No warnings
- ✅ Concurrent retries work correctly
- ✅ Transport down clears all state
- ✅ Oversized frames handled correctly
- ✅ Stop during retry works
- ✅ Full request lifecycle works
- ✅ No race conditions or double replies

---

## Constraints

- **DO NOT** skip critical test scenarios
- **DO NOT** use sleeps > 100ms (keep tests fast)
- Mock transport must track all calls
- Tests must be deterministic (use seeded :rand if needed)
- All tests must pass reliably

---

## Implementation Notes

### Test Determinism

Use `ExUnit.configuration()[:seed]` for reproducible random behavior:

```elixir
setup do
  seed = {ExUnit.configuration()[:seed], :os.system_time(), self()}
  :rand.seed(:exsplus, seed)
  {:ok, seed: seed}
end
```

### Process Introspection

For getting internal state:
```elixir
:sys.get_state(pid)  # Returns full state struct
```

Use sparingly - tests should primarily verify behavior, not internal state.

### Async vs Sync Tests

Most integration tests should use `async: false` to avoid process interference. Unit tests can use `async: true`.

### MockTransport Patterns

**Always busy:**
```elixir
MockTransport.configure(transport, send_behavior: :busy)
```

**Busy N times, then ok:**
```elixir
send_pattern = fn count ->
  if count < 2, do: :busy, else: :ok
end
MockTransport.configure(transport, send_behavior: send_pattern)
```

**Per-request pattern:**
Store request context in mock, return different behavior per request.

### Testing Backoff

Backoff delays make tests slow. Use short delays for testing:
```elixir
{:ok, client} = McpClient.start_link(
  transport: :mock,
  backoff_min: 10,       # 10ms instead of 1000ms
  backoff_max: 50,       # 50ms instead of 30000ms
  retry_delay_ms: 5      # 5ms instead of 10ms
)
```

---

## Deliverable

Provide:
1. Updated `test/support/mock_transport.ex` with call tracking
2. `test/mcp_client/integration_test.exs` with all critical scenarios
3. All tests passing
4. No warnings
5. Test coverage for all critical paths

All files must:
- Pass reliably (no flaky tests)
- Run reasonably fast (< 5 seconds total)
- Cover all critical scenarios from checklist
- Verify correct behavior, not just absence of crashes

If any requirement is unclear, insert `# TODO: <reason>` and stop.
