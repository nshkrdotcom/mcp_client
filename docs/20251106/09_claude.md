# Final Review: Decisioned MVP Spec

**Overall verdict: 95% mechanically sound.** You've made defensible choices on all major underspecifications. Below are the remaining 5% edge cases and implementation details that will bite during coding if not locked now.

---

## Critical gaps (must resolve before implementation)

### 1. **Tombstone TTL: per-request vs global**

Your formula:
```elixir
tombstone_ttl = request_timeout + init_timeout + backoff_max + 5_000
```

**Problem**: Requests can have **different** per-call timeouts:
```elixir
McpClient.call_tool(client, "fast", %{}, timeout: 5_000)
McpClient.call_tool(client, "slow", %{}, timeout: 120_000)
```

If both timeout and get tombstoned, do they share one global TTL or have individual TTLs?

**Option A (simpler)**: Global TTL calculated from **configured defaults**, ignore per-call overrides
```elixir
# All tombstones expire at same time relative to state transition
tombstone_inserted_at + global_ttl
```

**Option B (correct)**: Per-tombstone TTL calculated from **actual request timeout**
```elixir
%{id => {tombstone_inserted_at, request_timeout + backoff_window}}
```

**Recommendation**: **Option A** for MVP. Document that per-request timeout overrides don't extend tombstone lifetime (they shouldn't need to—responses after backoff are stale anyway).

**Decision needed**: Confirm A or justify B.

---

### 2. **Race condition: response during tombstoning**

Your rule:
```
On transition to :backoff, tombstone all inflight ids first
```

**Scenario**:
```
T0: Send request id=42
T1: Timeout fires, begin tombstoning
T2: Response for id=42 arrives (network delay)
T3: Tombstone insertion completes
```

At T2, is `42` already tombstoned? The `gen_statem` processes messages sequentially, so this **should** be safe—but you need to **document the ordering guarantee**:

> "All tombstone insertions complete **atomically during state transition** before any further messages are processed. Therefore, responses arriving after timeout+tombstone will always see the tombstone."

**Action**: Add this guarantee to the state table notes or it's undefined behavior.

---

### 3. **Jitter implementation must be deterministic**

You specify:
```
retry_delay_ms: 10  # base delay; jitter ±50%
backoff_max: 30_000 # with jitter 0.2
```

**Questions**:
- ±50% jitter on retry = `10 * (1 ± 0.5)` = [5ms, 15ms]? 
- 0.2 jitter on backoff = `backoff * (1 ± 0.2)` = [0.8x, 1.2x]?
- Which PRNG? `:rand.uniform/1` requires per-process seeding. If you don't seed, all connections will have identical "random" patterns (bad for thundering herd).

**Specify**:
```elixir
# Jitter calculation (commit to this)
jittered_delay = base_delay * (1.0 + (:rand.uniform() - 0.5) * jitter_factor)

# Backoff with jitter
next_backoff = min(current_backoff * 2, backoff_max) 
               |> jitter(0.2)

# Ensure :rand is seeded in Connection init/1:
:rand.seed(:exsplus, {node(), self(), System.monotonic_time()})
```

**Decision needed**: Confirm this jitter formula and seeding strategy.

---

### 4. **Frame size violation needs protocol-level handling**

You say:
```
If frame > 16MB: close transport, transition to :backoff
```

**But**: The server doesn't know you dropped the message. If it was a request, the server is now waiting for a response forever.

**Better**: Before closing, send a JSON-RPC error response (if the frame had a parseable ID):
```json
{"jsonrpc": "2.0", "id": <id_if_known>, "error": {
  "code": -32700,
  "message": "frame exceeds max_frame_bytes"
}}
```

Then close. This keeps the server's state machine sane.

**Decision needed**: Can you extract `id` from oversized frames without parsing? If yes, send error. If no, document that server may have dangling state.

---

### 5. **State table missing edges**

Your table has 20+ rows but misses:

**Missing in `:initializing`**:
```
| :initializing | frame(oversized) | size > max | close+backoff | :backoff |
```

**Missing in `:ready`**:
```
| :ready | frame(oversized) | size > max | close+backoff | :backoff |
```

**Missing in `:starting`**:
```
| :starting | stop | - | (no transport yet, just exit) | :closing |
```

**Ambiguous**:
```
| :ready | server_notification(cancelled_all) | ...
```
Is this MCP-specific or JSON-RPC `$/cancelled`? Specify the exact notification method name.

**Add these rows** or explicitly state they're absorbed by existing rules.

---

### 6. **Map structure for requests must be specified**

You chose map over ETS. **What's the shape?**

**Option A**: Flat map
```elixir
%{
  42 => %{from: from, timer_ref: ref, started_at: mono_time},
  43 => %{...}
}
```

**Option B**: Nested by method (for better telemetry)
```elixir
%{
  tools: %{42 => %{...}},
  resources: %{43 => %{...}}
}
```

**Recommendation**: **Option A**—simpler, method is in telemetry metadata anyway.

**Lock it**: Confirm the struct fields: `%{from, timer_ref, started_at, method, params}` or subset?

---

### 7. **Synchronous notification danger**

You say:
```
Document: "Handlers must be quick; slow handlers will delay the connection."
```

**But you don't specify how to enforce "quick."** 

**Missing safeguard**: Either:
- A) Add a **hard timeout** (5s?) and kill slow handlers:
  ```elixir
  task = Task.async(fn -> handler.(notif) end)
  Task.await(task, 5_000) |> rescue TimeoutError -> :ok
  ```
- B) Document the exact failure mode (connection hangs, telemetry stops, etc.)

**For MVP**: Option B (document) is fine, but you must **spell out the symptoms** users will see when they screw this up.

---

### 8. **Supervision tree inconsistency**

Your supervision tree shows:
```
ConnectionSupervisor (rest_for_one)
  ├─ Transport (worker)
  └─ Connection (worker)
```

But in your state table you reference:
```
| :ready | user_call(...) | ... | send_frame with bounded retry; start timer | :ready |
```

**Question**: If there's no `TaskSupervisor`, where do timers live? In the `Connection` process?

**Also**: Earlier docs showed `RequestManager` and `TaskSupervisor`. Your MVP drops both. **Confirm** the tree is exactly 2 children (Transport, Connection) and nothing else.

---

### 9. **Tombstone cleanup mechanism unspecified**

You calculate TTL but don't say **how** tombstones expire:

**Option A**: Lazy cleanup (check on lookup)
```elixir
def tombstoned?(id, now) do
  case Map.get(tombstones, id) do
    {inserted_at, ttl} when now - inserted_at > ttl -> false
    {_inserted_at, _ttl} -> true
    nil -> false
  end
end
```

**Option B**: Eager cleanup (timer per tombstone)
```elixir
Process.send_after(self(), {:expire_tombstone, id}, ttl)
```

**Option C**: Periodic sweep (one timer, batch cleanup)
```elixir
Process.send_after(self(), :clean_tombstones, 60_000)
```

**Recommendation**: **Option C** for MVP—one timer, sweep every 60s, drop expired tombstones. Simple and bounded.

**Lock it**: Confirm cleanup strategy.

---

### 10. **Graceful shutdown behavior undefined**

Your `:closing` state:
```
| :closing | any | - | drop | :closing |
```

**But**: What about inflight requests? Do we:
- A) Wait up to N seconds for them to complete?
- B) Immediately fail them with `{:error, :shutdown}`?
- C) Let them timeout naturally (but connection is closed)?

**For MVP**: **Option B**—on entering `:closing`, iterate all inflight requests and reply `{:error, %Error{kind: :shutdown}}`. Then close transport.

**Lock it**: Confirm shutdown semantics.

---

## Property test parameters missing

You list 3 properties but don't specify:

```elixir
# These must be locked for reproducible CI
@property_iterations 100
@max_concurrent_requests 50
@max_reorder_window_ms 100
@cancellation_attempts 5
```

**Lock these** or your property tests will be flaky / non-deterministic.

---

## Acceptance checklist (amended)

Before cutting code, you MUST have written answers to:

- [ ] Tombstone TTL: per-request or global? (Recommend global)
- [ ] Race condition ordering: documented guarantee? (Yes, atomic during transition)
- [ ] Jitter PRNG: seeding strategy? (Seed in init with `{node(), self(), monotonic}`)
- [ ] Oversized frames: send error before close? (Extract ID if possible, else document)
- [ ] State table: add 3 missing edges (oversized in ready/init, stop in starting)
- [ ] Request map structure: locked shape? (`%{id => %{from, timer_ref, started_at, method}}`)
- [ ] Notification timeout: hard limit or documented failure mode? (Document for MVP)
- [ ] Supervision tree: confirm exactly 2 children? (Yes, only Transport + Connection)
- [ ] Tombstone cleanup: lazy, eager, or periodic? (Periodic sweep every 60s)
- [ ] Graceful shutdown: wait or fail-fast? (Fail-fast, reply `:shutdown` to all inflight)
- [ ] Property test params: iterations, bounds, timeouts? (Lock numbers above)

---

## Final recommendation

You're **1 hour of documentation away** from a locked MVP spec. 

Write a `design/MVP_SPEC.md` that includes:
1. The state transition table (with 3 added rows)
2. The numeric defaults (with jitter formula)
3. The 11 decisions above (tombstone strategy, jitter seeding, etc.)
4. A 1-paragraph "What's NOT in MVP" section (pools, session IDs, async notifications, etc.)

Then **freeze it**. Anyone who wants to change these decisions post-freeze must write a separate ADR (Architecture Decision Record).

Ship this and you'll have a tight, predictable MCP client that won't surprise users or contributors.
