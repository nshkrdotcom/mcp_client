# Implementation Prompt 03: Ready State - Request/Response Path

**Goal:** Implement :ready state request handling, response routing, request timeouts, and basic notifications.

> **Update (2025-11-07):** Replace any per-request `:state_timeout` actions with `:erlang.send_after/3` messages (`{:req_timeout, id}`), and keep calls synchronous (store `from`; do **not** reply `{:ok, id}` immediately). Treat the remainder of this prompt as historical context where it conflicts with ADR-0003/ADR-0007.

**Test Strategy:** TDD with rgr. All tests green, no warnings.

---

## Context: What You're Building

You're implementing the core request/response cycle in the :ready state:
1. Client calls arrive (call_tool, list_resources, etc.)
2. Generate request ID, build JSON-RPC frame
3. Send frame to transport
4. Track request with timeout
5. Route response back to caller
6. Handle request timeouts

This prompt covers the **happy path** and basic timeout handling. Retry logic and failure paths come in Prompt 04.

---

## Required Reading: State Transitions

From STATE_TRANSITIONS.md, these are the exact transitions to implement:

### :ready State - Request/Response

| From | Event | Guard | Actions | To |
|------|-------|-------|---------|-----|
| :ready | `{:call, from}, {:request, method, params, opts}` | - | Generate ID; build JSON-RPC frame; send frame; if `:ok` → track request with timeout; reply `{:ok, id}` or `{:error, reason}` | :ready |
| :ready | `{:info, {:transport, :frame, binary}}` | response with known ID | Decode; cancel timeout; reply to caller; tombstone ID; set_active(:once) | :ready |
| :ready | `{:info, {:transport, :frame, binary}}` | response with unknown ID | Log debug (tombstoned/late); set_active(:once) | :ready |
| :ready | `{:info, {:transport, :frame, binary}}` | notification | Decode; invoke handlers (sync); set_active(:once) | :ready |
| :ready | `{:state_timeout, {:request_timeout, id}}` | ID exists | Reply error; tombstone ID | :ready |
| :ready | `{:state_timeout, {:request_timeout, id}}` | ID tombstoned | Ignore (already replied) | :ready |

### Request Struct (from ADR-0003)

```elixir
data.requests :: %{
  id => %{
    from: {pid(), reference()},
    started_at_mono: integer(),      # System.monotonic_time() native
    timeout: non_neg_integer(),      # milliseconds
    method: String.t(),
    corr_id: binary()                # 8-byte random
  }
}
```

### Tombstone Struct (from ADR-0005)

```elixir
data.tombstones :: %{
  id => %{
    inserted_at_mono: integer(),     # System.monotonic_time(:millisecond)
    ttl_ms: non_neg_integer()        # data.tombstone_ttl_ms
  }
}
```

---

## Key Requirements from ADRs

### ADR-0003: Request Tracking

**Per-request timeout preservation:**
```elixir
# When tracking request:
timeout = opts[:timeout] || @default_request_timeout
request = %{
  from: from,
  method: method,
  started_at_mono: System.monotonic_time(),
  timeout: timeout,  # MUST store this for retry path
  corr_id: :crypto.strong_rand_bytes(8)
}
```

**Timeout action:**
```elixir
action = {:state_timeout, timeout, {:request_timeout, id}}
```

### ADR-0005: Tombstones

**Create tombstone on terminal events:**
```elixir
defp tombstone_request(data, id) do
  now = System.monotonic_time(:millisecond)
  tombstone = %{
    inserted_at_mono: now,
    ttl_ms: data.tombstone_ttl_ms
  }
  data = Map.update!(data, :tombstones, &Map.put(&1, id, tombstone))
  Map.update!(data, :requests, &Map.delete(&1, id))
end
```

**Check tombstone:**
```elixir
defp tombstoned?(data, id) do
  Map.has_key?(data.tombstones, id)
end
```

### ADR-0006: Notification Handlers

**Synchronous execution with error isolation:**
```elixir
defp invoke_notification_handlers(data, notification) do
  for handler <- data.notification_handlers do
    try do
      handler.(notification)
    rescue
      error ->
        Logger.warning("Notification handler crashed: #{inspect(error)}")
    end
  end
  data
end
```

---

## Implementation Requirements

### 1. Add Module Constants

```elixir
@default_request_timeout 30_000
@protocol_version "2024-11-05"
```

### 2. Request ID Generation

```elixir
defp generate_request_id(data) do
  # Simple incrementing ID (JSON-RPC allows any type)
  # Start at 1 (ID 0 reserved for initialize)
  existing_ids = Map.keys(data.requests) ++ Map.keys(data.retries)
  next_id = if Enum.empty?(existing_ids), do: 1, else: Enum.max(existing_ids) + 1
  next_id
end
```

### 3. Implement Request Sending

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

  case Transport.send_frame(data.transport, frame) do
    :ok ->
      # Track request
      request = %{
        from: from,
        started_at_mono: System.monotonic_time(),
        timeout: timeout,
        method: method,
        corr_id: corr_id
      }

      data = Map.update!(data, :requests, &Map.put(&1, id, request))
      actions = [{:state_timeout, timeout, {:request_timeout, id}}]

      {:keep_state, data, [{:reply, from, {:ok, id}} | actions]}

    {:error, reason} ->
      # Send failed - reply immediately with error
      {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
  end
end
```

### 4. Implement Response Routing

```elixir
# Guard against oversized frames (applies to all states)
def handle_event(:info, {:transport, :frame, binary}, _, data)
    when byte_size(binary) > @max_frame_bytes do
  Logger.error("Frame exceeds #{@max_frame_bytes} bytes: #{byte_size(binary)}")
  Transport.close(data.transport)
  # This transitions to backoff - will be implemented in Prompt 04
  {:next_state, :backoff, data, schedule_backoff_action(data)}
end

# Decode and route frame in :ready state
def handle_event(:info, {:transport, :frame, binary}, :ready, data) do
  case Jason.decode(binary) do
    {:ok, json} ->
      data = process_ready_frame(json, data)
      :ok = Transport.set_active(data.transport, :once)
      {:keep_state, data}

    {:error, reason} ->
      Logger.warning("Invalid JSON in ready: #{inspect(reason)}")
      :ok = Transport.set_active(data.transport, :once)
      {:keep_state_and_data, []}
  end
end

defp process_ready_frame(%{"id" => id, "result" => result}, data) when is_integer(id) do
  handle_response(id, {:ok, result}, data)
end

defp process_ready_frame(%{"id" => id, "error" => error}, data) when is_integer(id) do
  handle_response(id, {:error, error}, data)
end

defp process_ready_frame(%{"method" => method, "params" => params}, data) do
  # Notification (no id field)
  notification = %{method: method, params: params}
  invoke_notification_handlers(data, notification)
end

defp process_ready_frame(other, data) do
  Logger.debug("Unexpected frame in ready: #{inspect(other)}")
  data
end

defp handle_response(id, response, data) do
  case Map.get(data.requests, id) do
    nil ->
      # Unknown ID - could be tombstoned or race
      if tombstoned?(data, id) do
        Logger.debug("Response for tombstoned request: #{id}")
      else
        Logger.debug("Response for unknown request: #{id}")
      end
      data

    request ->
      # Reply to caller
      case response do
        {:ok, result} ->
          GenServer.reply(request.from, {:ok, result})
        {:error, error} ->
          GenServer.reply(request.from, {:error, error})
      end

      # Tombstone and clear
      tombstone_request(data, id)
  end
end
```

### 5. Implement Request Timeout

```elixir
def handle_event(:state_timeout, {:request_timeout, id}, :ready, data) do
  case Map.get(data.requests, id) do
    nil ->
      # Already handled (could be tombstoned)
      {:keep_state_and_data, []}

    request ->
      # Reply with timeout error
      error = %{
        "code" => -32000,
        "message" => "Request timeout after #{request.timeout}ms"
      }
      GenServer.reply(request.from, {:error, error})

      # Tombstone
      data = tombstone_request(data, id)
      {:keep_state, data}
  end
end
```

### 6. Implement Helper Functions

```elixir
defp tombstone_request(data, id) do
  now = System.monotonic_time(:millisecond)
  tombstone = %{
    inserted_at_mono: now,
    ttl_ms: data.tombstone_ttl_ms
  }

  data
  |> Map.update!(:tombstones, &Map.put(&1, id, tombstone))
  |> Map.update!(:requests, &Map.delete(&1, id))
end

defp tombstoned?(data, id) do
  Map.has_key?(data.tombstones, id)
end

defp invoke_notification_handlers(data, notification) do
  for handler <- data.notification_handlers do
    try do
      handler.(notification)
    rescue
      error ->
        Logger.warning("Notification handler crashed: #{inspect(error)}")
    end
  end
  data
end
```

---

## Test File: test/mcp_client/connection_test.exs

Add these tests:

```elixir
describe ":ready state - requests" do
  setup do
    {:ok, pid} = Connection.start_link(transport: :mock)

    # Transition to ready (simulate full handshake)
    send(pid, {:transport, :up})
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
    send(pid, {:transport, :frame, Jason.encode!(init_response)})
    Process.sleep(10)

    {:ok, connection: pid}
  end

  test "sends request and tracks it", %{connection: conn} do
    # Make request
    task = Task.async(fn ->
      :gen_statem.call(conn, {:request, "tools/call", %{"name" => "test"}, []})
    end)

    # Should get back {:ok, request_id}
    assert {:ok, id} = Task.await(task)
    assert is_integer(id)
  end

  test "routes response back to caller", %{connection: conn} do
    # Make request
    task = Task.async(fn ->
      {:ok, id} = :gen_statem.call(conn, {:request, "tools/call", %{}, []})

      # Wait for response
      receive do
        msg -> msg
      after
        1000 -> :timeout
      end
    end)

    Process.sleep(10)

    # Send response
    response = %{
      "jsonrpc" => "2.0",
      "id" => 1,  # First user request ID
      "result" => %{"output" => "success"}
    }
    send(conn, {:transport, :frame, Jason.encode!(response)})

    # Caller should receive response
    assert {:ok, %{"output" => "success"}} = Task.await(task)
  end

  test "handles error responses", %{connection: conn} do
    task = Task.async(fn ->
      {:ok, _id} = :gen_statem.call(conn, {:request, "tools/call", %{}, []})

      receive do
        msg -> msg
      after
        1000 -> :timeout
      end
    end)

    Process.sleep(10)

    # Send error response
    response = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{"code" => -32601, "message" => "Method not found"}
    }
    send(conn, {:transport, :frame, Jason.encode!(response)})

    assert {:error, %{"code" => -32601}} = Task.await(task)
  end

  test "handles request timeout", %{connection: conn} do
    # Make request with short timeout
    task = Task.async(fn ->
      :gen_statem.call(conn, {:request, "tools/call", %{}, timeout: 100})
    end)

    # Get request ID
    {:ok, id} = Task.await(task)

    # Trigger timeout manually
    send(conn, {:state_timeout, {:request_timeout, id}})

    # Original caller should get timeout error via mailbox
    # (This is simplified - real test needs proper async coordination)
  end

  test "ignores responses for unknown IDs", %{connection: conn} do
    # Send response for ID that doesn't exist
    response = %{
      "jsonrpc" => "2.0",
      "id" => 9999,
      "result" => %{"data" => "orphaned"}
    }

    send(conn, {:transport, :frame, Jason.encode!(response)})

    # Should log and continue
    Process.sleep(10)
    assert Process.alive?(conn)
  end

  test "invokes notification handlers", %{connection: conn} do
    # Register a handler that sends to test process
    test_pid = self()
    handler = fn notif -> send(test_pid, {:notification, notif}) end

    # Add handler to connection (need API for this - will implement later)
    # For now, send notification directly
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/message",
      "params" => %{"level" => "info", "data" => "test"}
    }

    send(conn, {:transport, :frame, Jason.encode!(notification)})

    # Handler should be invoked
    # (Actual test needs handler registration API)
  end

  test "handles notification handler crashes", %{connection: conn} do
    # Handler that raises
    # (Need handler registration API)

    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/message",
      "params" => %{}
    }

    send(conn, {:transport, :frame, Jason.encode!(notification)})

    # Should log warning but not crash connection
    Process.sleep(10)
    assert Process.alive?(conn)
  end

  test "generates sequential request IDs", %{connection: conn} do
    # Make multiple requests
    {:ok, id1} = :gen_statem.call(conn, {:request, "test1", %{}, []})
    {:ok, id2} = :gen_statem.call(conn, {:request, "test2", %{}, []})
    {:ok, id3} = :gen_statem.call(conn, {:request, "test3", %{}, []})

    assert id1 == 1
    assert id2 == 2
    assert id3 == 3
  end

  test "tombstones completed requests", %{connection: conn} do
    {:ok, id} = :gen_statem.call(conn, {:request, "test", %{}, []})

    # Send response
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"ok" => true}
    }
    send(conn, {:transport, :frame, Jason.encode!(response)})
    Process.sleep(10)

    # Send duplicate response - should be ignored (tombstoned)
    send(conn, {:transport, :frame, Jason.encode!(response)})

    # Should log and not crash
    Process.sleep(10)
    assert Process.alive?(conn)
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
- ✅ Request/response cycle works
- ✅ Timeouts are tracked correctly
- ✅ Tombstones prevent duplicate replies
- ✅ Notifications are handled

---

## Constraints

- **DO NOT** implement retry logic yet (Prompt 04)
- **DO NOT** implement failure transitions yet (Prompt 04)
- **DO NOT** implement :backoff state yet
- **DO NOT** implement cancellation yet
- Focus only on happy path and basic timeouts
- Use exact timeout units (milliseconds for config, native for monotonic)

---

## Implementation Notes

### Transport Dependency

Continue using MockTransport from Prompt 02. Assume:
- `Transport.send_frame/2` returns `:ok` or `{:error, reason}`
- `Transport.set_active/2` returns `:ok`
- Transport sends frames as `{:transport, :frame, binary}`

### Request ID Strategy

Using simple incrementing IDs starting at 1 (0 reserved for initialize). This is adequate for MVP. Post-MVP could use:
- Random IDs (prevent guessing)
- UUIDs (distributed coordination)
- Per-session counter with prefix

### Notification Handler API

Handlers are currently stored in `data.notification_handlers` (list of functions). Public API for registration will be added in later prompt covering the public API module.

### Time Units

**CRITICAL - from STATE_TRANSITIONS.md invariants:**
- `started_at_mono`: `System.monotonic_time()` in native units
- `inserted_at_mono`: `System.monotonic_time(:millisecond)`
- `timeout` config: milliseconds
- Never compare native and millisecond values

---

## Deliverable

Provide the updated `lib/mcp_client/connection.ex` that:
1. Implements :ready state request/response path
2. Handles request timeouts correctly
3. Implements tombstones correctly
4. Invokes notification handlers synchronously
5. Passes all tests
6. Compiles without warnings

If any requirement is unclear, insert `# TODO: <reason>` and stop.
