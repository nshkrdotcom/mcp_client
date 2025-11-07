# MCP Client Documentation

Complete documentation for the Elixir Model Context Protocol (MCP) client library.

## Quick Links

**For Implementers:**
- **[MVP Specification](design/MVP_SPEC.md)** - Complete technical specification for MVP implementation
- **[Implementation Prompts](implementation/)** - Step-by-step implementation guides (PROMPT_01-15)
- **[State Transitions](design/STATE_TRANSITIONS.md)** - Complete state machine transition table

**For Users:**
- **[Getting Started Guide](guides/GETTING_STARTED.md)** - Quick start and common patterns
- **[Client Features](design/CLIENT_FEATURES.md)** - High-level API design for MCP primitives
- **[Roadmap](ROADMAP.md)** - Post-MVP features and timeline

**Reference:**
- **[Protocol Details](design/PROTOCOL_DETAILS.md)** - Complete JSON-RPC and MCP message schemas
- **[Transport Specifications](design/TRANSPORT_SPECIFICATIONS.md)** - stdio, SSE, HTTP+SSE details
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

**[design/CLIENT_FEATURES.md](design/CLIENT_FEATURES.md)**
- High-level API design for MCP primitives (Tools, Resources, Prompts, Sampling, Roots, Logging)
- Module structure and type specifications
- Error handling and notification routing patterns
- Implementation checklist and testing strategy

**[design/TRANSPORT_SPECIFICATIONS.md](design/TRANSPORT_SPECIFICATIONS.md)**
- Complete transport layer specifications (stdio, SSE, HTTP+SSE)
- Transport behavior contract and message protocol
- Implementation details for each transport type
- OAuth 2.1 support for HTTP transport
- Testing requirements

**[design/PROTOCOL_DETAILS.md](design/PROTOCOL_DETAILS.md)**
- JSON-RPC 2.0 foundation and message formats
- Complete error code mappings (standard + MCP-specific)
- Connection lifecycle and capability negotiation
- Request parameter schemas for all MCP methods
- Progress tokens and cancellation

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
- **[ADR-0011](adr/0011-client-features-architecture.md)**: Client features architecture

### Implementation Prompts

Located in [`implementation/`](implementation/), these provide step-by-step implementation guides:

**Core (PROMPT_01-09):**
- Connection scaffold, state machine (01-05)
- Transport behavior and stdio (06)
- Public API and integration tests (07-08)
- Documentation (09)

**Client Features (PROMPT_10-15):**
- Error & notification infrastructure (10)
- Tools, Resources, Prompts (11-13)
- Sampling, Roots, Logging (14)
- Feature integration tests (15)

See [implementation/README.md](implementation/README.md) for complete prompt index.

### User Guides

Located in [`guides/`](guides/), these provide practical usage documentation:

- **[GETTING_STARTED.md](guides/GETTING_STARTED.md)**: Quick start and common patterns
- **[CONFIGURATION.md](guides/CONFIGURATION.md)**: Complete configuration reference
- **[ERROR_HANDLING.md](guides/ERROR_HANDLING.md)**: Comprehensive error handling strategies
- **[ADVANCED_PATTERNS.md](guides/ADVANCED_PATTERNS.md)**: Production patterns (caching, pooling, monitoring)
- **[FAQ.md](guides/FAQ.md)**: Frequently asked questions

### Roadmap

**[ROADMAP.md](ROADMAP.md)**
- Post-MVP feature timeline and priorities
- Tier 1 features: Code generation tool, progressive discovery, async handlers
- Tier 2 features: Connection pooling, ETS tracking, resource caching
- Tier 3 features: WebSocket transport, compression, skills pattern
- Release timeline (v0.2.x - v1.0.x)
- How to influence priorities and contribute

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
| **Design Documents** | | | |
| MVP_SPEC.md | 1.0.0-mvp | Locked | 2025-11-06 |
| STATE_TRANSITIONS.md | 1.0.0 | Locked | 2025-11-06 |
| CLIENT_FEATURES.md | 1.0.0 | Accepted | 2025-11-07 |
| TRANSPORT_SPECIFICATIONS.md | 1.0.0 | Accepted | 2025-11-07 |
| PROTOCOL_DETAILS.md | 1.0.0 | Accepted | 2025-11-07 |
| CODE_EXECUTION_PATTERN.md | 1.0.0 | Accepted | 2025-11-07 |
| **Implementation Prompts** | | | |
| PROMPT_01 through PROMPT_09 | - | Ready | 2025-11-06 |
| PROMPT_10 through PROMPT_15 | - | Ready | 2025-11-07 |
| **Architecture Decisions** | | | |
| ADR-0001 through ADR-0010 | - | Accepted | 2025-11-06 |
| ADR-0011 | - | Accepted | 2025-11-07 |
| **User Guides** | | | |
| GETTING_STARTED.md | 1.0.0 | Complete | 2025-11-07 |
| CONFIGURATION.md | 1.0.0 | Complete | 2025-11-07 |
| ERROR_HANDLING.md | 1.0.0 | Complete | 2025-11-07 |
| ADVANCED_PATTERNS.md | 1.0.0 | Complete | 2025-11-07 |
| FAQ.md | 1.0.0 | Complete | 2025-11-07 |
| **Roadmap** | | | |
| ROADMAP.md | 1.0.0 | Complete | 2025-11-07 |

**"Locked" means**: No changes without new ADR and team approval.
**"Ready" means**: Implementation prompts are complete and ready to execute.
**"Complete" means**: Documentation is finished and ready for users.

---

**Questions?** Start with MVP_SPEC.md, then consult relevant ADRs. For historical context, see design process documents in `20251106/`.
