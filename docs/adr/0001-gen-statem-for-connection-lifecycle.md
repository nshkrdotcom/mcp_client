# 1. Use gen_statem for Connection Lifecycle Management

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

The MCP client requires managing a complex connection lifecycle with multiple states (starting, initializing, ready, backoff, closing) and state-dependent behavior for handling requests, responses, and failures. Connection state transitions must be explicit, predictable, and testable.

Using a plain GenServer would require manual state tracking with nested case statements and implicit state transitions, making it difficult to reason about all possible state/event combinations and verify completeness.

## Decision Drivers

- Need explicit state machine semantics for connection lifecycle
- Must handle all possible state/event combinations deterministically
- Backoff/retry logic requires state-aware transitions
- Testing requires ability to verify all transitions and guards
- BEAM scheduler efficiency under high message load
- Clear failure semantics and recovery paths

## Considered Options

**Option 1: Plain GenServer with state field**
- Store current state in GenServer state map
- Use case statements in handle_call/cast/info
- Manual state transition management

**Option 2: gen_statem with handle_event_function**
- Explicit states as atoms
- Pattern match on (event_type, event, state, data)
- Built-in timeout and action semantics

**Option 3: Custom behavior with FSM library**
- Third-party FSM library (e.g., gen_fsm wrapper)
- Additional dependency

## Decision Outcome

Chosen option: **gen_statem with handle_event_function**, because:

1. **Explicit state transitions**: Every `(state, event) -> action -> next_state` edge is visible and testable
2. **Timer discipline**: Built-in `:state_timeout`/`:event_timeout` cover the single outstanding timers (init, drain, backoff) while per-request timers use `:erlang.send_after/3` and enter through the regular `:info` path
3. **Table-driven completeness**: We keep the transitions in a locked table and add a default clause that logs + crashes (in test builds) whenever an unexpected `(state, event)` arrives
4. **Standard OTP**: No external dependencies; well-documented pattern
5. **Backoff/retry**: State machine actions encode retry scheduling + failure semantics in one place

### Implementation Details

**States defined:**
```elixir
:starting      # Spawning/attaching transport
:initializing  # MCP handshake in progress
:ready         # Normal operation
:backoff       # Exponential backoff before reconnect
:closing       # Graceful shutdown
```

**State machine data:**
```elixir
%{
  transport: pid(),
  session_id: non_neg_integer(),
  requests: %{id => %{from, timer_ref, started_at_mono, method}},
  tombstones: map(),
  server_caps: Types.ServerCapabilities.t() | nil,
  backoff_delay: non_neg_integer()
}
```

**Callback mode:**
```elixir
@impl true
def callback_mode, do: :handle_event_function
```

**Example transition with timeout:**
```elixir
def handle_event(:internal, {:spawn_transport, opts}, :starting, data) do
  {:ok, transport} = start_transport(opts)
  actions = [{:state_timeout, init_timeout, :init_timeout}]
  {:next_state, :initializing, %{data | transport: transport}, actions}
end

# Catch-all (guard rail)
def handle_event(event_type, event, state, data) do
  Logger.error("Unhandled transition", event_type: event_type, event: event, state: state)
  :telemetry.execute([:mcp_client, :connection, :missing_transition], %{count: 1}, %{state: state})
  if Mix.env() == :test, do: raise("missing transition #{inspect({state, event_type, event})}")
  {:keep_state_and_data, []}
end
```

### Consequences

**Positive:**
- Complete transition table can be reviewed and tested exhaustively
- Impossible states are mechanically prevented
- Timeout logic is declarative and built-in
- Clear separation between state transitions and side effects
- Easier to reason about under all failure scenarios

**Negative/Risks:**
- Slightly more boilerplate than GenServer (callback_mode, state tuple returns)
- Team must understand gen_statem semantics (less common than GenServer)
- Pattern matching on 4-tuple requires discipline
- Missing `(state, event)` clauses surface at runtime, so we instrument a catch-all handler that logs at `:error`, increments telemetry, and crashes immediately under `MIX_ENV=test`

**Neutral:**
- All transitions must be explicitly defined (good for correctness, more initial code)
- State timeouts replace manual timer management (different idiom)

## Deferred Alternatives

None. This is a foundational architectural choice for MVP.

## References

- Design Document 02 (gpt5.md), Section 1: "OTP process model: make the connection a proper state machine"
- Design Document 10 (final spec), Section 5: Complete state transition table
- Erlang/OTP gen_statem documentation: https://www.erlang.org/doc/man/gen_statem.html
- MCP Specification: https://spec.modelcontextprotocol.io/
