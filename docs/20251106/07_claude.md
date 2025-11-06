# Feedback: MVP Scope Needs More Mechanical Precision

Your MVP reduction is **pragmatic and well-structured**, but several decisions are still underspecified in ways that will cause implementation thrash. Below are surgical questions that need answers before cutting code.

---

## Critical underspecifications

### 1. **Tombstone TTL is arbitrary and wrong**

You specify 60s TTL, but this creates a **correctness hole**:

- Request has 30s timeout
- Times out, we send cancel, insert tombstone with 60s TTL
- Network partition lasts 90s
- Response arrives at T+90s → tombstone expired → we process a stale response

**Question**: Shouldn't tombstone TTL be `max(all_active_timeouts) + epsilon`? Or tied to connection lifecycle (cleared on state transition to `:initializing`)?

**Propose**: Either:
- A) Tombstones live until next connection state transition, OR
- B) Tombstone TTL = `2 * connection_timeout` (to survive one full backoff cycle)

Which is correct and why?

### 2. **Dropping frames in `:backoff` loses correctness**

```
Any response received in `:backoff` ⇒ drop.
```

**Problem**: If we transition `:ready` → `:backoff` at T=0 due to transport hiccup, and a response arrives at T=0.5ms that was sent at T=-1s, we've dropped a valid response.

**Question**: Should we instead:
- A) Keep a **tiny bounded buffer** (say, 10 messages) during `:backoff` for up to N seconds, then drain on reconnect?
- B) Move to `:backoff` only after **flushing** all pending request IDs to tombstones?
- C) Accept the loss and document "requests may be lost during reconnect"?

Which provides the **least surprising behavior** for users?

### 3. **`:busy` with no retry is a footgun**

```
On :busy → no automatic retry in MVP; reply {:error, :backpressure}.
```

**Problem**: Every caller must now implement:
```elixir
case McpClient.call_tool(client, "search", args) do
  {:error, :backpressure} -> ??? # sleep? retry? give up?
end
```

**This is not simpler**—it's **exporting complexity** to every call site.

**Question**: Wouldn't a **bounded inline retry** be both simpler AND correct?
```elixir
def send_with_retry(transport, frame, attempts \\ 3) do
  case Transport.send_frame(transport, frame) do
    :ok -> :ok
    {:error, :busy} when attempts > 1 ->
      Process.sleep(10)  # or exponential backoff
      send_with_retry(transport, frame, attempts - 1)
    {:error, reason} -> {:error, reason}
  end
end
```

This is **~10 LOC** and prevents every caller from reinventing it. Why defer?

### 4. **`max_frame_bytes` is still undefined**

```
Add a configurable max_frame_bytes; reject frames larger than N
```

**Questions**:
- What's the **default** value? 1MB? 10MB? 100MB?
- What happens when we hit it—do we close the connection (protocol violation) or just reply with an error and continue?
- Can this limit be **negotiated** during initialization (like HTTP's `MAX_FRAME_SIZE`)?

**Propose**: Default 16MB (matches most JSON-RPC implementations), **close connection** on violation (it's a protocol error), no negotiation in MVP.

Agree or counter-proposal?

### 5. **State transition semantics are incomplete**

Your rules:
```
- Any transport loss or init timeout ⇒ :backoff
- Server notifications/cancelled ⇒ clear pending, go :initializing  
- Response in :backoff ⇒ drop
```

**Missing edges**:
- `:initializing` + transport dies → `:backoff` or `:starting`?
- `:backoff` + transport reconnects successfully → `:initializing` or `:ready`?
- `:ready` + init timeout (???) → impossible state or error?
- `:closing` + any message → drop or error?

**Ask**: Can you draw the **complete directed graph** with 5 nodes and ~15 labeled edges? Each edge should have the form `(state, event) -> action -> new_state`.

### 6. **Request tracking: map vs ETS matters**

```
Requests held in the gen_statem data (map or ETS)
```

**This is not equivalent**:

| Approach | Pros | Cons |
|----------|------|------|
| Map in state | Simple, serializes with state | Large map = slow state transitions, no concurrent reads |
| ETS (`:protected`) | Fast concurrent reads from other processes | Must handle ETS loss on crash, more code |
| ETS (`:public`) | Allows direct writes from callers | Breaks encapsulation, hard to debug |

**For MVP with inline request tracking in Connection**, map is simpler. But if you later add `RequestManager`, you'll need ETS.

**Decision needed**: Commit to **map** for MVP and document the refactor path, or use **`:protected` ETS** from the start?

### 7. **Task.Supervisor for notifications is underspecified**

Original design showed `Task.Supervisor` in the supervision tree. Your MVP says:

```
Supervision (MVP): Transport, TaskSupervisor, Connection
```

But notification handling is not in the MVP action list. **Is it in or out?**

**If IN**: Specify the behavior:
- Max concurrent notification tasks?
- What happens if a notification handler crashes? (Swallow? Log? Telemetry?)
- Delivery guarantee? (At-most-once is fine for MVP)

**If OUT**: Remove `TaskSupervisor` from the tree and handle notifications **synchronously in the Connection process**. Accept that slow handlers block the connection.

Which is it?

### 8. **Supervision tree linking is confused**

```
rest_for_one with children ordered: Transport, TaskSupervisor, Connection.
Link Connection ↔ Transport.
```

**Problem**: Under `rest_for_one`, if `Transport` (child 1) dies, **both** `TaskSupervisor` and `Connection` restart automatically. The explicit link is **redundant** and adds confusion.

**Question**: Do you mean:
- A) Remove the explicit link (rely on `rest_for_one`), OR
- B) Change strategy to `:one_for_one` and require the explicit link?

For MVP, **A is simpler**—`rest_for_one` gives you the semantics you want without manual links.

### 9. **Error struct consistency**

You say:
```
:initializing and :backoff reject user calls with {:error, :unavailable}
```

But the original design specified:
```elixir
{:error, %McpClient.Error{kind: :state, code: nil, message: "not ready"}}
```

**Which is it?** If you return bare atoms like `:unavailable`, you lose:
- Consistent error shape for pattern matching
- Ability to add context (e.g., "not ready, currently in backoff with 3s remaining")
- Telemetry/logging hooks that expect structs

**Recommend**: Keep the struct even for state errors. It's 2 lines of code:
```elixir
{:error, %Error{kind: :state, message: "client not ready", data: %{state: :backoff}}}
```

### 10. **Property test scope is too thin**

You KEEP only 2 properties:
1. 1:1 correlation under reordering
2. Timeouts don't leak

**But you're missing the easiest high-value property**:
3. **Cancellation is idempotent** (cancelling same ID N times = 1 time, no crashes)

This is a **~20 line test** and catches a whole class of bugs (double-remove from ETS, double-reply to caller, etc).

**Why defer?** Add it to MVP.

---

## Deliverables for MVP lock-in

Before implementation starts, provide:

### A) **Complete state transition table**

```
| Current State  | Event                  | Guard        | Action                          | Next State   |
|----------------|------------------------|--------------|----------------------------------|--------------|
| :starting      | :spawn_ok              | -            | start init handshake            | :initializing|
| :starting      | :spawn_error           | -            | schedule backoff                | :backoff     |
| :initializing  | :init_response         | valid caps   | store caps                      | :ready       |
| :initializing  | :init_timeout          | -            | clear pending, tombstone        | :backoff     |
| :initializing  | :transport_down        | -            | clear pending, tombstone        | :backoff     |
| :ready         | :transport_down        | -            | clear pending, tombstone        | :backoff     |
| :ready         | user call              | -            | send request, start timer       | :ready       |
| :ready         | :response              | known id     | reply to caller, cancel timer   | :ready       |
| :ready         | :response              | unknown id   | log + drop OR check tombstone   | :ready       |
| :backoff       | :backoff_expire        | -            | restart transport               | :starting    |
| :backoff       | any user call          | -            | reply {:error, :unavailable}    | :backoff     |
| :backoff       | :response              | -            | check tombstone, drop           | :backoff     |
| :closing       | *                      | -            | drop                            | :closing     |
```

Fill in the missing rows. Every state + event combination must have an action.

### B) **Concrete numeric defaults**

```elixir
@defaults [
  timeout: 30_000,              # per-request timeout
  init_timeout: 10_000,         # handshake timeout  
  backoff_min: 1_000,           # min backoff before reconnect
  backoff_max: 30_000,          # max backoff (with jitter)
  max_frame_bytes: 16_777_216,  # 16MB
  tombstone_ttl: :next_state_transition,  # or a number
  retry_attempts: 3,            # for send_frame :busy
  retry_delay: 10               # ms between retries
]
```

Commit to these numbers or provide alternates with justification.

### C) **Notification handling decision**

Pick one:

**Option 1: Synchronous (simpler)**
```elixir
def handle_notification(state, notif) do
  for handler <- state.handlers do
    try do
      handler.(notif)
    rescue e -> Logger.warn("handler crashed: #{inspect(e)}")
    end
  end
end
```
- Pro: No TaskSupervisor needed, simpler tree
- Con: Slow handler blocks connection

**Option 2: Async (safer)**
```elixir
def handle_notification(state, notif) do
  for handler <- state.handlers do
    Task.Supervisor.start_child(state.task_sup, fn -> handler.(notif) end)
  end
end
```
- Pro: Slow handlers don't block
- Con: Requires TaskSupervisor, no backpressure

**Option 3: Hybrid (deferred)**
Synchronous in MVP, add TaskSupervisor post-MVP.

Which do you choose and why?

---

## Final verdict

Your MVP scope is **80% there**. You correctly identified what to defer (pools, session IDs, advanced telemetry).

But you need to **commit to specifics** on:
1. Tombstone lifecycle (not 60s arbitrary)
2. `:backoff` message handling (buffering or documented loss?)
3. `:busy` retry (inline 3x is simpler than forcing callers to handle it)
4. Complete state machine (all edges defined)
5. Notification delivery model (sync or async?)

These are not "nice to haves"—they're **MVP-blocking** because every alternative has different code shapes. Choose now, ship fast, iterate later.

**Recommendation**: Take 30 minutes to fill in the state transition table and commit to the numeric defaults. Then the implementation becomes mechanical.
