# MCP Client Documentation

Complete documentation for the Elixir Model Context Protocol (MCP) client library.

## Quick Links

- **[MVP Specification](design/MVP_SPEC.md)** - Complete technical specification for MVP implementation
- **[State Transitions](design/STATE_TRANSITIONS.md)** - Complete state machine transition table
- **[Architecture Decision Records](adr/)** - Why we made each architectural decision

## Documentation Structure

### Design Documents

**[design/MVP_SPEC.md](design/MVP_SPEC.md)**
- Complete locked specification for MVP implementation
- Configuration defaults (all numeric values)
- Request lifecycle and error handling
- API surface and options
- Testing requirements
- Implementation checklist

**[design/STATE_TRANSITIONS.md](design/STATE_TRANSITIONS.md)**
- Complete state machine transition table
- Every (state, event) → action → next_state defined
- Guard functions and common action patterns
- Invariants and testing strategies
- Example sequence diagrams

### Architecture Decision Records (ADRs)

Located in [`adr/`](adr/), these capture the **why** behind each major design decision:

#### Core Architecture
- **[ADR-0001](adr/0001-gen-statem-for-connection-lifecycle.md)**: gen_statem for connection lifecycle
- **[ADR-0002](adr/0002-rest-for-one-supervision-strategy.md)**: rest_for_one supervision strategy
- **[ADR-0003](adr/0003-inline-request-tracking-in-connection.md)**: Inline request tracking

#### Flow Control & Reliability
- **[ADR-0004](adr/0004-active-once-backpressure-model.md)**: Active-once backpressure model
- **[ADR-0005](adr/0005-global-tombstone-ttl-strategy.md)**: Global tombstone TTL strategy
- **[ADR-0007](adr/0007-bounded-send-retry-for-busy-transport.md)**: Bounded send retry
- **[ADR-0008](adr/0008-16mb-max-frame-size-limit.md)**: 16MB frame size limit

#### User-Facing Behavior
- **[ADR-0006](adr/0006-synchronous-notification-handlers.md)**: Synchronous notification handlers
- **[ADR-0009](adr/0009-fail-fast-graceful-shutdown.md)**: Fail-fast graceful shutdown

#### Scope
- **[ADR-0010](adr/0010-mvp-scope-and-deferrals.md)**: MVP scope and explicit deferrals

### Design Process Archive

The [`20251106/`](20251106/) directory contains the complete design evolution:

| Document | Description |
|----------|-------------|
| 01_initial_claude.md | Initial comprehensive design with full module structure |
| 02_gpt5.md | OTP refinements focusing on mechanical sympathy |
| 03_critique_claude.md | Critical gap analysis identifying underspecifications |
| 04_v2_gpt5.md | Refined design with explicit state machine semantics |
| 05_critique_gemini.md | Mechanical soundness review |
| 06_gpt5.md | Session ID gating and supervision hardening |
| 07_claude.md | MVP scope reduction decisions |
| 08_gpt5.md | Decisioned MVP choices with locked values |
| 09_claude.md | Critical underspecifications identified |
| 10_gpt5.md | **Final locked MVP specification** |
| 11_gemini.md | Final confirmation of mechanical soundness |
| 12_claude.md | Micro-refinement edge cases (init validation, concurrent stop) |
| 13_gpt5.md | Final micro-refinement resolution |

**Start with document 10** (10_gpt5.md) for the final locked specification, then trace backwards through the design process if you need historical context.

## For Implementers

**Start here:**
1. Read [MVP_SPEC.md](design/MVP_SPEC.md) - Complete implementation specification
2. Review [STATE_TRANSITIONS.md](design/STATE_TRANSITIONS.md) - State machine guide
3. Consult [ADRs](adr/) as needed for decision rationale

**Implementation order:**
1. Core types and error handling
2. Transport behavior and stdio implementation
3. Connection gen_statem (following state table exactly)
4. Public API wrapper
5. Tests (property tests first, then unit/integration)

**Testing priorities:**
1. Property tests (3 core guarantees - see MVP_SPEC.md §11.1)
2. State machine coverage (all edges in STATE_TRANSITIONS.md)
3. Integration tests with real servers

## For Contributors

**Proposing changes:**
1. Check if it's deferred in [ADR-0010](adr/0010-mvp-scope-and-deferrals.md)
2. Write draft ADR in `adr/draft/`
3. Reference affected ADRs
4. Explain necessity (user feedback, measurements, etc.)
5. Submit for review

**Adding features:**
- Post-MVP features should have ADRs
- Update MVP_SPEC.md if changing core behavior
- Update STATE_TRANSITIONS.md if adding states/events
- Mark superseded ADRs with status update

## Key Design Principles

These principles guided all decisions:

1. **Mechanical correctness over features**: Every state/event combination defined explicitly
2. **BEAM sympathy**: Leverage OTP patterns (gen_statem, supervision) correctly
3. **Explicit trade-offs**: No hidden complexity or "magic"
4. **Testable properties**: Core guarantees verified with property tests
5. **Fail-fast**: Predictable failure modes over silent corruption
6. **MVP pragmatism**: Ship working client in 2-3 weeks, iterate post-launch

## Reference Links

- **MCP Specification**: https://spec.modelcontextprotocol.io/
- **Erlang gen_statem**: https://www.erlang.org/doc/man/gen_statem.html
- **Hex Package**: _(coming soon)_
- **GitHub Issues**: _(coming soon)_

## Document Status

| Document | Version | Status | Last Updated |
|----------|---------|--------|--------------|
| MVP_SPEC.md | 1.0.0-mvp | Locked | 2025-11-06 |
| STATE_TRANSITIONS.md | 1.0.0 | Locked | 2025-11-06 |
| ADR-0001 through ADR-0010 | - | Accepted | 2025-11-06 |

**"Locked" means**: No changes without new ADR and team approval.

---

**Questions?** Start with MVP_SPEC.md, then consult relevant ADRs. For historical context, see design process documents in `20251106/`.
