# 2. Use rest_for_one Supervision Strategy Without Explicit Links

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

The MCP client consists of two primary processes: Transport (handles stdio/SSE/HTTP communication) and Connection (manages protocol state machine). These processes have a critical dependency: if Transport dies, Connection's state becomes invalid because pending requests cannot complete. The supervision strategy must ensure both processes restart together in the correct order.

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
- Children ordered: Transport (first), Connection (second)
- No explicit linking required

**Option 3: one_for_all**
- Any child failure restarts all children
- Overkill for 2-child tree

## Decision Outcome

Chosen option: **rest_for_one without explicit links**, because:

1. **Automatic dependency handling**: When Transport (child 1) dies, supervisor automatically restarts children after it (Connection)
2. **Correct ordering**: Transport starts first, Connection starts second and receives fresh Transport PID
3. **No manual linking**: Supervisor handles all restart logic; Connection doesn't need to trap exits or handle EXIT signals
4. **Simpler mental model**: Fewer process signals to track; standard OTP pattern
5. **Failure isolation**: If Connection dies (bug), only Connection restarts; Transport remains stable

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
    children = [
      {McpClient.Transport, Keyword.take(opts, [:transport, :command, :args, :url])},
      {McpClient.Connection, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

**Child ordering critical:**
- Transport must be first child
- Connection must be second child
- Order determines restart cascade

**Failure scenarios:**

| Scenario | Behavior |
|----------|----------|
| Transport dies | Supervisor restarts Transport, then Connection (both fresh) |
| Connection dies | Supervisor restarts only Connection (Transport unaffected) |
| Both die | Standard supervisor restart logic (intensity/period limits) |

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
