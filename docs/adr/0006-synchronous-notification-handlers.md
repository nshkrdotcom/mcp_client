# 6. Synchronous Notification Handlers (No TaskSupervisor)

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

The MCP protocol allows servers to send notifications (e.g., resource updates, log messages, progress updates) that clients must handle. The client library needs to dispatch these notifications to user-registered callback functions.

Asynchronous dispatch via TaskSupervisor would isolate the Connection process from slow handlers but adds supervision complexity and obscures backpressure signals. Synchronous dispatch is simpler but requires careful documentation of handler requirements.

## Decision Drivers

- Minimize MVP supervision tree complexity
- Make backpressure behavior explicit to users
- Avoid hidden concurrency (tasks that users don't see)
- Keep notification delivery semantics simple
- Balance safety vs. simplicity for MVP

## Considered Options

**Option 1: Async dispatch via TaskSupervisor**
- User handlers run in separate Task processes
- Connection never blocks on handler execution
- Requires TaskSupervisor in supervision tree
- No backpressure signal to slow handlers

**Option 2: Synchronous inline dispatch**
- Handlers run in Connection process
- Connection blocks during handler execution
- No additional supervision required
- Slow handlers delay next frame processing

**Option 3: Hybrid (sync with timeout)**
- Run handlers in Connection with hard timeout (e.g., 5s)
- Kill slow handlers after timeout
- Requires timer management

## Decision Outcome

Chosen option: **Synchronous inline dispatch (Option 2)**, because:

1. **Simplicity**: No TaskSupervisor in MVP supervision tree
2. **Explicit behavior**: Users see backpressure directly (slow handler = slow connection)
3. **Deterministic**: Notifications processed in order they arrive
4. **Fewer failure modes**: No task crashes to handle, no orphaned tasks
5. **Adequate for MVP**: Most handlers should be fast dispatch (logging, state updates)

### Implementation Details

**Handler registration:**
```elixir
@spec on_notification(client(), (Types.Notification.t() -> any())) :: :ok
def on_notification(client, callback) when is_function(callback, 1) do
  GenServer.cast(client, {:register_notification_handler, callback})
end
```

**Stored in Connection state:**
```elixir
defstruct [
  # ... other fields
  notification_handlers: []  # List of 1-arity functions
]
```

**Synchronous dispatch:**
```elixir
def handle_event(:info, {:transport, :frame, binary}, :ready, data) do
  case parse_frame(binary) do
    {:notification, notification} ->
      dispatch_notification(notification, data.notification_handlers)
      :ok = Transport.set_active(data.transport, :once)
      {:keep_state, data}

    # ... other frame types
  end
end

defp dispatch_notification(notification, handlers) do
  for handler <- handlers do
    try do
      handler.(notification)
    rescue
      error ->
        Logger.warn("""
        Notification handler crashed: #{inspect(error)}
        Notification: #{inspect(notification)}
        """)
    end
  end
  :ok
end
```

**Handler exceptions are caught** - a crashing handler does not crash the Connection.

### Consequences

**Positive:**
- Minimal code and supervision complexity
- Backpressure is visible: slow handlers delay the connection
- Handlers execute in predictable order (FIFO)
- No hidden concurrency to debug
- Exception handling prevents handler crashes from affecting connection

**Negative/Risks:**
- **Slow handlers block Connection** - this is the critical trade-off
  - Handler doing I/O (database write, HTTP call) blocks frame processing
  - Connection cannot read next frame until handler returns
  - Mailbox grows if notifications arrive faster than handlers complete
- **Unbounded handler execution time** - no timeout enforcement
- **Resource contention** - multiple handlers share Connection process heap

**Neutral:**
- Handler order matches notification arrival order
- All handlers see every notification (no selective dispatch in MVP)

## Critical Documentation Requirements

Users **must** be warned about handler performance requirements:

> **⚠️ Notification Handler Performance**
>
> Handlers registered via `on_notification/2` run **synchronously in the connection process**. Slow handlers will delay all connection processing, including:
> - Response delivery for pending requests
> - Processing subsequent notifications
> - Connection heartbeat/ping

### Handler Requirements

**DO:**
- Keep handlers fast (< 5ms typical)
- Perform quick in-memory operations (counter increments, ets writes, logging)
- Send messages to other processes for heavy work
- Use `GenServer.cast/2` or `send/2` for async dispatch

**Example of correct async pattern:**
```elixir
McpClient.on_notification(client, fn notification ->
  # Fast dispatch to another process
  GenServer.cast(MyApp.NotificationProcessor, {:process, notification})
end)
```

**DON'T:**
- Perform I/O (database queries, HTTP calls, file operations)
- Run expensive computations
- Call blocking functions
- Use `GenServer.call/2` (synchronous)

### Failure Symptoms

If a handler violates these requirements, users will see:
- Increased latency for `call_tool/4` and other API calls
- Delayed notification processing (notifications queue in mailbox)
- Connection timeout failures (server stops responding due to backpressure)
- Missed ping/heartbeat timeouts

## Deferred Alternatives

**Async dispatch with TaskSupervisor (post-MVP)**: Add optional async mode:

```elixir
McpClient.start_link([
  # ... config
  notification_mode: :async,  # Default :sync
  max_notification_tasks: 16  # Cap concurrent handlers
])
```

**Implementation:**
- Add TaskSupervisor to supervision tree
- Check `notification_mode` config in dispatch
- Track concurrent task count, apply backpressure when cap reached

**Deferred because:**
- Adds supervision complexity (3rd child in tree)
- Requires task pool management (state tracking)
- Obscures backpressure (users don't see slow handlers)
- MVP users should fix slow handlers, not hide the problem

## Testing Notes

Property test: **Notification delivery is at-least-once**
```elixir
property "handlers receive all notifications even under load" do
  check all notifications <- list_of(notification_generator(), min_length: 100) do
    # Track received notifications in counter
    counter = :counters.new(1, [])
    handler = fn _notif -> :counters.add(counter, 1, 1) end

    # Send burst
    for notif <- notifications, do: send(client, {:notification, notif})

    # Verify count
    assert :counters.get(counter, 1) == length(notifications)
  end
end
```

## References

- Design Document 04 (v2_gpt5.md), Section 6: "Notification delivery: decouple from client process"
- Design Document 08 (gpt5.md), Section 7: "Synchronous notification danger"
- Design Document 10 (final spec), Section 7: "Synchronous notification hazard (MVP)"
- Design Document 10 (final spec), Section 8: "Supervision tree (final)" - No TaskSupervisor
