# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records for the MCP Client library. Each ADR captures a significant architectural decision made during the MVP design process, including the context, alternatives considered, and rationale for the chosen approach.

## Index

### Core Architecture

**[ADR-0001: Use gen_statem for Connection Lifecycle](0001-gen-statem-for-connection-lifecycle.md)**
Decision to use OTP's gen_statem behavior for managing connection state machine instead of plain GenServer. Provides explicit state transitions, built-in timeout actions, and mechanical completeness for all state/event combinations.

**[ADR-0002: Use rest_for_one Supervision Strategy](0002-rest-for-one-supervision-strategy.md)**
Decision to supervise Transport and Connection with `:rest_for_one` strategy without explicit process links. Ensures Transport failure triggers Connection restart while keeping supervision simple.

**[ADR-0003: Inline Request Tracking in Connection](0003-inline-request-tracking-in-connection.md)**
Decision to store request metadata in Connection state map rather than separate RequestManager process or ETS table. Minimizes message hops and simplifies lifecycle management for MVP.

### Flow Control & Reliability

**[ADR-0004: Active-Once Backpressure Model](0004-active-once-backpressure-model.md)**
Decision to use active-once flow control with inline JSON decode. Bounds mailbox size and provides predictable backpressure, trading off simplicity for potential head-of-line blocking on large frames.

**[ADR-0005: Global Tombstone TTL Strategy](0005-global-tombstone-ttl-strategy.md)**
Decision to use global tombstone TTL calculated from configuration defaults (request_timeout + init_timeout + backoff_max + epsilon = 75s default). Prevents stale response delivery after cancellation/timeout.

**[ADR-0007: Bounded Send Retry for Busy Transport](0007-bounded-send-retry-for-busy-transport.md)**
Decision to retry `send_frame` up to 3 times with jittered delay when transport returns `:busy`. Provides good UX without pushing retry complexity to callers.

**[ADR-0008: 16MB Maximum Frame Size Limit](0008-16mb-max-frame-size-limit.md)**
Decision to enforce 16MB hard limit on incoming frames and close connection on violation. Protects against memory exhaustion and DoS attacks with clear failure semantics.

### User-Facing Behavior

**[ADR-0006: Synchronous Notification Handlers](0006-synchronous-notification-handlers.md)**
Decision to dispatch notifications synchronously in Connection process for MVP. Keeps supervision simple but requires handlers to be fast and non-blocking.

**[ADR-0009: Fail-Fast Graceful Shutdown](0009-fail-fast-graceful-shutdown.md)**
Decision to fail all in-flight requests immediately on shutdown rather than waiting for responses. Provides predictable shutdown latency (~100ms) and prevents hangs.

### Scope & Planning

**[ADR-0010: MVP Scope and Explicit Deferrals](0010-mvp-scope-and-deferrals.md)**
Complete definition of what's included vs. deferred in MVP. Covers protocol features, transports, reliability, observability, and explicitly lists post-MVP enhancements.

**[ADR-0011: Client Features Architecture](0011-client-features-architecture.md)**
Architecture for high-level MCP feature APIs (Tools, Resources, Prompts, Sampling, Roots, Logging) built on top of core connection layer. Defines clean API boundary, error normalization, notification routing, and incremental implementation strategy.

### Tool Modes & Sessions

**[ADR-0012: Tool Modes and Session Flexibility](0012-tool-modes-and-session-flexibility.md)**
Defines per-tool execution modes (stateful vs. stateless), optional session semantics, and the requirement for registry-backed multi-connection supervision so the client can scale beyond single-instance transports.

### Extensibility & Roadmap

**[ADR-0013: Pluggable State Store and Registry Adapters](0013-pluggable-state-store-and-registry-adapters.md)**
Records the plan for shipping adapter behaviours so request/tombstone storage and connection registries can move to ETS, Redis, Horde, or custom implementations without rewriting the core FSM.

**[ADR-0014: Transport Customization and HTTP Client Overrides](0014-transport-customization-and-http-client-overrides.md)**
Documents the transport plug-in contract, including how custom transports and Finch/HTTP client overrides integrate with the supervisor tree.

**[ADR-0015: Asynchronous Notification Dispatch Roadmap](0015-async-notification-dispatch-roadmap.md)**
Explains why synchronous handlers remain for MVP (ADR-0006) and how the optional async/Task.Supervisor mode will be introduced post-MVP.

## Reading Order

For new contributors or implementers:

1. Start with **ADR-0010** (MVP Scope) to understand boundaries
2. Read **ADR-0001** (gen_statem) and **ADR-0002** (supervision) for architecture foundation
3. Read **ADR-0003** through **ADR-0009** for detailed subsystem decisions
4. Read **ADR-0011** (Client Features) for high-level API architecture
5. Consult `../design/MVP_SPEC.md` for complete implementation specification
6. Reference `../design/STATE_TRANSITIONS.md` while implementing state machine

## Design Evolution

These ADRs were derived from a comprehensive design review process documented in `docs/20251106/`:

1. **01_initial_claude.md**: Initial comprehensive design
2. **02_gpt5.md**: OTP refinements and mechanical sympathy
3. **03_critique_claude.md**: Critical gap analysis
4. **04_v2_gpt5.md**: Refined design with explicit semantics
5. **05_critique_gemini.md**: Final mechanical soundness review
6. **06_gpt5.md**: Session ID and supervision hardening
7. **07_claude.md**: MVP scope reduction
8. **08_gpt5.md**: Decisioned MVP choices
9. **09_claude.md**: Critical underspecifications identified
10. **10_gpt5.md**: Final locked MVP specification
11. **11_gemini.md**: Final confirmation of soundness
12. **12_claude.md**: Micro-refinement edge cases
13. **13_gpt5.md**: Final micro-refinement resolution

The design process prioritized:
- Mechanical correctness (BEAM scheduler, supervision semantics)
- Explicit trade-offs (no hidden complexity)
- Testable properties (exhaustive state machine coverage)
- Pragmatic MVP scope (ship in 2-3 weeks)

## ADR Status

All ADRs in this directory have status **Accepted** and are **locked for MVP implementation**. Changes to these decisions require:

1. Writing a new ADR documenting the change
2. Updating affected ADRs to reference the change
3. Team review and approval
4. Updating MVP_SPEC.md to reflect changes

## Related Documentation

- **Complete Specification**: `../design/MVP_SPEC.md`
- **State Transition Table**: `../design/STATE_TRANSITIONS.md`
- **Design Process**: `../20251106/*.md`
- **MCP Specification**: https://spec.modelcontextprotocol.io/

## Questions?

For questions about these architectural decisions:

1. Check if answered in the ADR itself (see "Consequences" and "Deferred Alternatives")
2. Review related ADRs (see "References" section in each ADR)
3. Consult MVP_SPEC.md for implementation details
4. Check design process documents for historical context

## Contributing

When proposing changes to architectural decisions:

1. Write a draft ADR in `docs/adr/draft/`
2. Reference existing ADRs that would be affected
3. Explain why the change is necessary (user feedback, performance data, etc.)
4. Propose alternatives with trade-offs
5. Submit for team review before implementation

---

**Last Updated**: 2025-11-10
**ADR Count**: 15
**Status**: Locked for MVP
