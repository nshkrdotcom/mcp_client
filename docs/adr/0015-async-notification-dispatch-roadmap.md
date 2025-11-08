# 15. Asynchronous Notification Dispatch Roadmap

**Status:** Accepted  
**Date:** 2025-11-10  
**Deciders:** Engineering Team  
**Context:** Follow-up to ADR-0006 (synchronous notification handlers)

## Context and Problem Statement

ADR-0006 locked synchronous notification dispatch for the MVP so the connection process stays simple and deterministic.
Community reviewers (Valim et al.) asked for an asynchronous option so long-running handlers (e.g., `resources/
list_changed`) do not stall the connection mailbox. We need to codify how and when we will expose async dispatch without
changing the MVP delivery timeline.

## Decision

1. **MVP remains synchronous**
   - ADR-0006 stands: handlers run inside `McpClient.Connection`, and users must keep them lightweight.

2. **Post-MVP async mode**
   - We will introduce an optional `notification_dispatch: :sync | {:async, supervisor_opts}` setting (default `:sync`).
   - When `:async` is selected, Connection forwards notifications to a dedicated `Task.Supervisor` (started alongside
     the connection) that runs handlers concurrently while preserving ordering per notification type.
   - Failures bubble through `Task.Supervisor` so supervision trees remain transparent.

3. **Documentation + prompts**
   - MVP spec references this ADR wherever synchronous dispatch is mentioned, clarifying the future upgrade path.
   - Implementation prompts (PROMPT_10+) note that handlers should be written to be async-safe (idempotent) even though
     MVP keeps them synchronous.

## Consequences

- ✅ Users have clarity that async dispatch is planned and how it will look.
- ✅ Maintains MVP simplicity; no additional processes or mailboxes right now.
- ✅ Once implemented, high-volume notification workloads will no longer risk starving the FSM.
- ⚠ Async mode introduces ordering/telemetry complexities—we must document guarantees carefully.
- ⚠ Task supervision adds runtime cost; defaults remain synchronous to avoid surprises.

## Alternatives Considered

1. **Switch to async immediately**
   - Rejected: increases MVP scope and complicates deterministic testing before core FSM is shipped.

2. **Leave async entirely out-of-scope**
   - Rejected: contradicts repeated user requests; without a plan, forks would emerge.

3. **Let users spawn their own Task Supervisor**
   - Rejected: leads to duplicated effort and inconsistent failure semantics; better to provide a built-in option with
     well-defined guarantees.

## References

- ADR-0006: Synchronous Notification Handlers
- ADR-0010: MVP Scope (Performance Optimizations – async dispatch deferred)
- Community feedback thread on notification latency (2025-08-01)
