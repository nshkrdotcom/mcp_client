# 13. Pluggable State Store and Registry Adapters

**Status:** Accepted  
**Date:** 2025-11-10  
**Deciders:** Engineering Team  
**Context:** Follow-up to ADR-0003 (request tracking) and ADR-0012 (registry-backed multi-connection support)

## Context and Problem Statement

ADR-0003 intentionally keeps all request/retry/tombstone metadata inside the `McpClient.Connection` process to
minimise message hops and ship the MVP faster. Community feedback (see José Valim’s thread 2025-08-01) highlighted two
gaps:

1. **State store pluggability** – large deployments want ETS, Horde, Redis, or custom stores so request metadata can be
   inspected or shared outside a single process.
2. **Registry adapters** – applications often run more than one MCP connection per server. They want a standard way to
   plug in registries beyond `Registry` (e.g. `Horde.Registry`, pg2-like adapters) without forking the library.

The MVP still targets single-node, single-process tracking, but we need an architectural hook so future releases can add
pluggable stores/registries without rewriting the connection FSM.

## Decision

1. **State store behaviour**
   - Introduce `McpClient.StateStore` behaviour (post-MVP) with callbacks to read/write request metadata, retries, and
     tombstones.
   - Ship an in-memory implementation (`McpClient.StateStore.InMemory`) that preserves ADR-0003 semantics and remains
     the default for MVP.
   - Require every store to surface sweep semantics (TTL-based deletes) so `Connection` can continue to drive timers.
   - Configuration key: `state_store: {module(), keyword()}` on `McpClient.start_link/1`.

2. **Registry adapter behaviour**
   - Define `McpClient.RegistryAdapter` behaviour that wraps `start_child/1`, `whereis/1`, and `via_tuple/2`
     primitives.
   - Default implementation proxies to `Registry`, matching MVP guidance.
   - Supervisors and transports will accept `registry_adapter: {module(), keyword()}` so multi-node applications can
     substitute Horde, Swarm, etc. without changing Connection internals.

3. **Documentation**
   - MVP spec remains unchanged (maps + Registry), but `docs/design/MVP_SPEC.md` and relevant prompts will reference
     this ADR when describing future enhancements.
   - Roadmap will list ETS/Redis adapters under “Post-MVP” with ADR-0013 as the canonical reference.

This ADR does **not** overturn ADR-0003 for MVP; it records the follow-up architecture so the Connection FSM can adopt
pluggable stores later without new design churn.

## Consequences

- ✅ Provides a clear path for ETS/Redis/Horde adoption once benchmarks demand it.
- ✅ Keeps MVP implementation simple: the default adapters wrap the current maps/Registry usage.
- ✅ Gives community contributors a sanctioned extension point instead of forking `Connection`.
- ⚠ Requires additional testing once alternative stores exist (consistency, timer semantics).
- ⚠ `McpClient.Connection` must be written with adapter boundaries in mind (no private direct map mutations once
  alternate stores land).

## Alternatives Considered

1. **Switch to ETS immediately**
   - Rejected: increases MVP scope, adds concurrency primitives we don’t need for single-node targets, and would still
     require custom adapters later for Redis/Horde.

2. **Keep everything hard-coded**
   - Rejected: contradicts repeated community feedback and would encourage forks for simple pluggability.

3. **Expose internal state via public APIs only**
   - Rejected: observation APIs don’t solve persistence or cross-node coordination; the core ask was storage
     substitution.

## References

- ADR-0003: Inline Request Tracking in Connection
- ADR-0010: MVP Scope and Explicit Deferrals (Performance Optimizations – ETS-based tracking)
- ADR-0012: Tool Modes and Session Flexibility (registry requirements)
- José Valim / community feedback thread (2025-08-01)
