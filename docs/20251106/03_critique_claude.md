# Prompt for Design Refinement

You've done excellent work laying out an OTP-native MCP client architecture. Now let's tighten the design with surgical precision, focusing on **mechanical sympathy** with BEAM internals and **fault-tolerant distributed systems** patterns.

## Critical gaps to address:

### 1. **State machine semantics are underspecified**

Your `gen_statem` states (`:starting → :initializing → :ready → :backoff → :closing`) need:
- **Explicit transition guards**: What triggers backoff? Connection loss, initialization timeout, or both?
- **Re-initialization protocol**: If server sends `notifications/cancelled` for all pending requests, should we transition back to `:initializing` or stay `:ready` and just clear request table?
- **Idempotent state actions**: What happens if we receive a response while in `:backoff`? Drop it, queue it, or error?

**Ask yourself**: Can I draw a complete state transition diagram with **all edges labeled** (including error paths) that accounts for every possible message in every state?

### 2. **Supervision tree hierarchy has a subtle flaw**

You show:
```
Connection (gen_statem)
 ├─ Transport
 ├─ RequestManager  
 └─ Task.Supervisor
```

But if `Connection` spawns these as children, **who supervises the Connection itself?** The pattern should be:

```
ConnectionSupervisor (rest_for_one)
 ├─ Transport (worker)
 ├─ RequestManager (worker)  
 ├─ TaskSupervisor (supervisor)
 └─ Connection (worker) - started LAST, links to all above
```

**Why rest_for_one?** If transport dies, request manager's state is invalid (pending requests can't complete). Connection must restart and re-initialize. But if request manager dies, transport is still fine - just restart manager and continue.

**Challenge**: Prove this is correct under all failure scenarios, or propose a better strategy.

### 3. **Request manager is doing too much**

You have a GenServer managing ETS with timer refs. This creates:
- Extra message hops (send to manager → manager writes ETS → manager sends to transport)
- Shared mutable state (ETS table) that's hard to reason about in failure scenarios
- Timer cleanup complexity (what if GenServer crashes with 1000 active timers?)

**Better pattern**: Request manager should be a **pure data structure** (maybe an Agent or even just ETS owned by Connection) with the Connection itself managing timers via `:gen_statem` timeout actions.

```elixir
# In connection.ex
{:next_state, :ready, new_data, [{:state_timeout, timeout, {:request_timeout, id}}]}
```

**Question**: Can you eliminate RequestManager entirely and manage everything in the Connection's state machine with state_timeout/event_timeout actions?

### 4. **Backpressure model is incomplete**

Active-once is good for flow control, but what about:
- **Parsing costs**: Large JSON payloads (100MB+ resource contents) will block the connection process during `Jason.decode!/1`. Should you parse in a separate process?
- **Processing costs**: If a notification handler takes 5 seconds, does that delay the next `set_active(:once)` call?
- **Burst buffering**: If 1000 notifications arrive while processing one, they queue in the mailbox. Should you have a ring buffer or explicit queue?

**Design challenge**: Specify the complete flow from "bytes arrive at port" → "user callback invoked" → "ready for next message" with **latency and memory bounds** at each step.

### 5. **Transport abstraction is still too thick**

Your 4-callback behaviour is better but still conflates concerns:

```elixir
@callback init(keyword()) :: {:ok, pid()} | {:error, term()}
@callback send(pid(), iodata()) :: :ok | {:error, term()}  
@callback set_active(pid(), :once | false) :: :ok | {:error, term()}
@callback close(pid()) :: :ok
```

Problems:
- `init/1` returns a PID - this means transport manages its own process, but **who supervises it?**
- `send/2` is synchronous - what if the transport buffer is full? Block? Return error?
- No `health_check/1` or `get_info/1` for diagnostics

**Refined contract** should separate:
1. **Lifecycle** (start_link, init, terminate) - supervised by ConnectionSupervisor
2. **Data plane** (send_frame, handle_frame callback) - async, bounded
3. **Control plane** (flush, get_stats) - diagnostics

### 6. **Cancellation semantics are unclear**

You mention sending `$/cancelRequest` but:
- What if the server doesn't support cancellation? (It's optional in JSON-RPC 2.0)
- What if the response arrives **during** the send of cancel request?
- Should cancelled IDs stay in a "tombstone" set forever, or expire?
- What about **cascading cancellation** - if client process dies, cancel all its requests?

**Specify**: A formal protocol for cancellation with timing diagrams covering all race conditions.

### 7. **Missing: Connection identity and multiplexing**

Real MCP deployments will have:
- Multiple clients connecting to the same server (different processes in the BEAM)
- Clients that restart (crash recovery)
- Clients that need to coordinate (shared resource subscriptions)

Should you have:
- A **connection pool** abstraction?
- **Client identity** tokens that persist across restarts?
- **Subscription registry** shared between multiple client instances?

Or explicitly scope this library to **single client per server** and document that?

### 8. **Error handling: missing the "repair" strategy**

You define error types well, but what's the **recovery strategy** for each?

| Error Kind | Example | Repair Action |
|------------|---------|---------------|
| `:transport` | Port closed | Transition to `:backoff`, reconnect with exponential backoff |
| `:protocol` | Invalid JSON | Log, drop message, continue (server bug, not fatal) |
| `:jsonrpc` | Method not found | Return error to caller, connection is fine |
| `:state` | Request in wrong state | ??? |

**Define**: A complete repair strategy table and implement it in the state machine.

### 9. **Telemetry: missing correlation and sampling**

Your events are good but incomplete:
- No **correlation IDs** for tracing a request through multiple hops
- No **sampling** strategy (do you emit telemetry for EVERY request, or sample?)
- No **aggregation** (how do you track "requests/sec" without overwhelming telemetry consumers?)

**Add**: 
- `correlation_id` in all event metadata (generated at request creation)
- `:telemetry.span/3` usage pattern
- Sampling config (`:telemetry_sample_rate`)

### 10. **Testing: missing property-based scenarios**

You mention StreamData but don't specify what properties to test:

**Critical properties**:
1. **Request-response correlation** is 1:1 even under message reordering
2. **Cancellation is idempotent** - cancelling twice doesn't fail
3. **Timeouts don't leak** - every request eventually completes or errors
4. **State transitions are acyclic** - no infinite loops
5. **Notification delivery is at-least-once** - never silently drop notifications

**Write**: Property definitions using StreamData that verify these.

---

## Deliverable

Provide:

1. **Complete state machine diagram** with all transitions, guards, and actions
2. **Refined supervision tree** with restart strategies justified for each child
3. **Request lifecycle flowchart** from `call_tool/3` to response, including all error paths
4. **Transport behaviour contract** with formal specs and integration test requirements
5. **Cancellation protocol specification** with timing diagrams
6. **Updated module tree** showing where each concern lives (no more ambiguity about who owns what)
7. **Three example integration patterns** (Phoenix LiveView, Broadway, Oban) with concrete supervision specs

Focus on **mechanical correctness** over features. Every design decision should be justified by either:
- BEAM scheduler behavior
- Network partition scenarios  
- Process supervision semantics
- Telemetry/observability requirements

If you're unsure about any pattern, **say so explicitly** and propose alternatives with tradeoffs.
