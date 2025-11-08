# 2. Use rest_for_one Supervision Strategy Without Explicit Links

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

The MCP client now consists of three tightly-related processes: Transport (handles stdio/SSE/HTTP communication), a per-connection `Task.Supervisor` for stateless tool executions, and Connection (manages the protocol state machine). Transport failure invalidates both Connection and any stateless tasks. Likewise, Connection should restart alongside the stateless supervisor so leaked tasks never outlive their parent connection. The supervision strategy must ensure all three restart together in the correct order.

## Decision Drivers

- Transport failure must trigger Connection restart (state invalidation)
- Connection must start after Transport (needs Transport PID)
- No manual process linking required (simpler, fewer signals)
- Clear restart semantics under all failure scenarios
- Minimal supervision tree complexity for MVP

## Considered Options

**Option 1: one_for_one with explicit links**
- Supervisor uses `:one_for_one` strategy
- Connection explicitly links to Transport in init/1
- Manual signal handling for EXIT messages

**Option 2: rest_for_one without links**
- Supervisor uses `:rest_for_one` strategy
- Children ordered: Transport (first), StatelessSupervisor (second), Connection (third)
- No explicit linking required

**Option 3: one_for_all**
- Any child failure restarts all children
- Overkill for 2-child tree

## Decision Outcome

Chosen option: **rest_for_one without explicit links**, because:

1. **Automatic dependency handling**: When Transport (child 1) dies, supervisor automatically restarts children after it (StatelessSupervisor + Connection)
2. **Correct ordering**: Transport starts first, StatelessSupervisor second, Connection third (receives fresh Transport PID and supervisor reference)
3. **No manual linking**: Supervisor handles all restart logic; Connection doesn't need to trap exits or handle EXIT signals
4. **Simpler mental model**: Fewer process signals to track; standard OTP pattern
5. **Failure isolation**: If Connection dies (bug), only Connection restarts; Transport + StatelessSupervisor remain stable (stateless tasks get restarted by their supervisor)

### Implementation Details

**Transport contract:** All transport implementations **must** emit exactly the message shapes defined in `docs/design/STATE_TRANSITIONS.md` under "Transport Message Contract":
- `{:transport, :up}` - exactly once after ready
- `{:transport, :frame, binary()}` - only after `set_active(:once)`
- `{:transport, :down, reason}` - on any failure

See STATE_TRANSITIONS.md for complete requirements.

**Supervision tree:**
```elixir
defmodule McpClient.ConnectionSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    {transport_mod, transport_opts} = Keyword.fetch!(opts, :transport)

    transport_child =
      Supervisor.child_spec(
        {transport_mod, transport_opts},
        id: :transport
      )

    stateless_name = opts[:stateless_supervisor] || Module.concat(McpClient.StatelessSupervisor, make_ref())

    stateless_child =
      Supervisor.child_spec(
        {Task.Supervisor, name: stateless_name},
        id: :stateless_supervisor
      )

    connection_child =
      Supervisor.child_spec(
        {McpClient.Connection,
         opts
         |> Keyword.put(:transport_mod, transport_mod)
         |> Keyword.put(:stateless_supervisor, stateless_name)},
        id: :connection
      )

    children = [transport_child, stateless_child, connection_child]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

**Child ordering critical:**
- Transport must be first child
- Stateless supervisor must be second child
- Connection must be third child
- Order determines restart cascade (transport failure restarts supervisors + connection; connection failure does not tear down transport)
- Connection never spawns its own transport or task supervisor; instead, the supervisor provides the module + options and the Connection receives the running transport PID + stateless supervisor via its `init/1` arguments/result of `Transport.attach/1`.

**Failure scenarios:**

| Scenario | Behavior |
|----------|----------|
| Transport dies | Supervisor restarts Transport, then Connection (both fresh) |
| Connection dies | Supervisor restarts only Connection (Transport unaffected) |
| Both die | Standard supervisor restart logic (intensity/period limits) |

- `opts[:transport]` is a `{module, keyword}` tuple (e.g., `{McpClient.Transports.Stdio, cmd: ...}`); the supervisor is the only place that knows how to start children.
- Connection receives the transport PID in `init/1` via `{:ok, transport_pid}` return from the transport child (or by reading `Process.whereis/1` if using named processes). No internal `spawn_link` calls remain.

### Consequences

**Positive:**
- Zero manual process links or monitors in Connection code
- Transport/Connection pairs are always consistent (no stale references)
- Standard OTP pattern, well-understood by Elixir community
- Connection init/1 doesn't need `Process.flag(:trap_exit, true)`
- Fewer edge cases to test (no EXIT signal races)

**Negative/Risks:**
- Requires strict child ordering (Transport before Connection)
- If child order is accidentally reversed, behavior is wrong
- Connection restart discards all in-flight request state (intended, but must be documented)

**Neutral:**
- Connection must handle being restarted (clear ETS, reset timers)
- Both processes restart on Transport failure (acceptable for MVP)

## Deferred Alternatives

**Session-aware restart coordination**: Post-MVP could add a third "coordinator" process that preserves session state across Connection restarts, allowing Transport to remain stable while Connection recovers from bugs. Deferred because:
- Adds complexity (3rd process, shared ETS)
- MVP priority is correctness over uptime optimization
- Most Connection bugs should be fixed, not worked around

## References

- Design Document 02 (gpt5.md), Section 2: "Supervision tree hierarchy has a subtle flaw"
- Design Document 08 (gpt5.md), Section 8: "Supervision/linking"
- Design Document 10 (final spec), Section 8: "Supervision tree (final)"
- Design Document 06 (gemini), Section 3: "Supervision Hierarchy: Clarifying Process Linking Semantics"
