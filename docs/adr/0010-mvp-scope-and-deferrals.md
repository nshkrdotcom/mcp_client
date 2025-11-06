# 10. MVP Scope and Explicit Deferrals

**Status:** Accepted
**Date:** 2025-11-06
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

The Model Context Protocol specification is comprehensive, supporting resources, prompts, tools, sampling, roots, logging, and various transport mechanisms. A production-grade client could include connection pooling, advanced telemetry, session persistence, streaming support, and sophisticated retry strategies.

The MVP must balance **completeness** (usable for real applications) with **simplicity** (shippable in reasonable time). We must explicitly define what's in scope vs. deferred to prevent scope creep and maintain mechanical correctness.

## Decision Drivers

- Deliver working client library in 2-3 weeks
- Support core MCP use cases (resources, prompts, tools)
- Maintain mechanical correctness (no hidden complexity)
- Enable post-MVP enhancements without breaking changes
- Focus on single-connection, single-server scenarios
- Prioritize correctness over performance optimizations

## MVP Scope (IN)

### Core Protocol Support

**Included in MVP:**
- ✅ JSON-RPC 2.0 encoding/decoding
- ✅ Initialize/initialized handshake with capability negotiation
- ✅ Request/response correlation by ID
- ✅ Server notifications (resource updates, logging, progress)
- ✅ Ping/pong health checks
- ✅ Error handling (JSON-RPC error codes)

### MCP Features

**Included in MVP:**
- ✅ **Resources**: list, read, subscribe, unsubscribe, list templates
- ✅ **Prompts**: list, get (with arguments)
- ✅ **Tools**: list, call (with arguments)
- ✅ **Sampling**: create_message (LLM completions)
- ✅ **Roots**: list roots, handle roots list requests
- ✅ **Logging**: set log level, receive log notifications

### Transport Layers

**Included in MVP:**
- ✅ **stdio**: Process communication via standard input/output
- ✅ **SSE**: Server-Sent Events for unidirectional updates
- ✅ **HTTP+SSE**: Bidirectional communication (POST for messages, SSE for notifications)

### OTP Integration

**Included in MVP:**
- ✅ gen_statem-based connection lifecycle (see ADR-0001)
- ✅ Supervision tree with rest_for_one strategy (see ADR-0002)
- ✅ Graceful shutdown under supervisor (see ADR-0009)
- ✅ Named processes (`:name` option)
- ✅ Standard child_spec for supervision trees

### Reliability Features

**Included in MVP:**
- ✅ Exponential backoff with jitter on connection failure
- ✅ Per-request timeouts with cancellation
- ✅ Active-once backpressure (see ADR-0004)
- ✅ Tombstone-based late response filtering (see ADR-0005)
- ✅ Bounded send retry for transport busy (see ADR-0007)
- ✅ 16MB frame size limit (see ADR-0008)
- ✅ Request/response correlation with monotonic IDs
- ✅ Automatic reconnection after transport failure

### Observability

**Included in MVP:**
- ✅ Telemetry events for requests, responses, state transitions
- ✅ Structured logging for errors and warnings
- ✅ Connection state inspection (`McpClient.state/1`)
- ✅ Server capability inspection (`McpClient.server_capabilities/1`)

### Testing

**Included in MVP:**
- ✅ Unit tests for all public API functions
- ✅ Property tests for core guarantees (correlation, timeouts, cancellation)
- ✅ Mock transport for testing
- ✅ Integration tests with real stdio servers

---

## Deferred to Post-MVP

### Advanced Reliability

**Deferred:**
- ❌ **Session ID gating**: Absolute guarantee against stale responses across session boundaries
  - **Why deferred**: Tombstone TTL formula (ADR-0005) covers normal cases; session IDs add complexity
  - **Post-MVP trigger**: User reports of stale responses in production

- ❌ **Request replay after reconnect**: Automatically retry in-flight requests after backoff
  - **Why deferred**: Adds state persistence complexity; most operations are idempotent
  - **Post-MVP trigger**: User demand for transparent reconnection

- ❌ **Configurable retry policies**: Per-method or per-call retry strategies
  - **Why deferred**: Fixed retry policy (ADR-0007) works for MVP
  - **Post-MVP trigger**: Evidence that different methods need different strategies

### Performance Optimizations

**Deferred:**
- ❌ **Async notification dispatch**: TaskSupervisor for notification handlers
  - **Why deferred**: Synchronous dispatch (ADR-0006) is simpler; users should keep handlers fast
  - **Post-MVP trigger**: User reports of notification-induced latency

- ❌ **Offload JSON decode pool**: Large frame decoding in separate tasks
  - **Why deferred**: Inline decode (ADR-0004) is adequate for typical payloads
  - **Post-MVP trigger**: Profiling shows decode blocking is real bottleneck

- ❌ **ETS-based request tracking**: Concurrent reads from multiple processes
  - **Why deferred**: Map in state (ADR-0003) sufficient for < 1000 concurrent requests
  - **Post-MVP trigger**: Benchmarks show contention at scale

- ❌ **Connection pooling**: Multiple connections to same server, round-robin dispatch
  - **Why deferred**: Single connection per server is MVP scope
  - **Post-MVP trigger**: High-throughput applications need parallelism

### Protocol Extensions

**Deferred:**
- ❌ **Negotiated frame size limit**: Exchange max_frame_bytes during initialize
  - **Why deferred**: Fixed 16MB limit (ADR-0008) works for MVP; requires spec change
  - **Post-MVP trigger**: MCP spec adds capability negotiation for limits

- ❌ **Streaming support**: Chunked transfer for large resources
  - **Why deferred**: Not in current MCP spec; large frames covered by 16MB limit
  - **Post-MVP trigger**: MCP spec adds streaming extension

- ❌ **Multiplexing**: Multiple logical channels over one transport
  - **Why deferred**: One connection = one logical session for MVP
  - **Post-MVP trigger**: Protocol optimization needs

- ❌ **Compression**: gzip/deflate for large payloads
  - **Why deferred**: Adds transport complexity; most payloads small
  - **Post-MVP trigger**: Bandwidth becomes bottleneck

### Advanced Features

**Deferred:**
- ❌ **Progress tracking**: Built-in progress aggregation for long operations
  - **Why deferred**: Progress notifications are received but not aggregated
  - **Post-MVP trigger**: User request for progress helpers

- ❌ **Resource caching**: Client-side cache with invalidation on updates
  - **Why deferred**: Application-specific caching strategies vary
  - **Post-MVP trigger**: Common pattern emerges across users

- ❌ **Prompt composition**: Combine multiple prompts into workflows
  - **Why deferred**: Application-level concern, not library feature
  - **Post-MVP trigger**: Reusable patterns identified

- ❌ **Tool chaining**: Automatic tool invocation sequences
  - **Why deferred**: High-level workflow, belongs in separate library
  - **Post-MVP trigger**: Demand for MCP orchestration layer

### Transports

**Deferred:**
- ❌ **WebSocket transport**: Two-way communication over WS
  - **Why deferred**: stdio/SSE/HTTP cover MVP use cases
  - **Post-MVP trigger**: Browser/web assembly use case

- ❌ **Unix domain socket transport**: Local IPC via UDS
  - **Why deferred**: stdio works for local servers
  - **Post-MVP trigger**: Performance-critical local communication

- ❌ **Custom transport behavior**: User-defined transport plugins
  - **Why deferred**: Three built-in transports sufficient
  - **Post-MVP trigger**: Exotic transport need (gRPC, QUIC, etc.)

### Multi-Client Coordination

**Deferred:**
- ❌ **Shared subscription registry**: Coordinate resource subscriptions across multiple clients
  - **Why deferred**: One client = one connection for MVP
  - **Post-MVP trigger**: Application needs cross-client coordination

- ❌ **Client identity persistence**: Restore client identity after restart
  - **Why deferred**: Application concern, not library feature
  - **Post-MVP trigger**: Server requires stable client IDs

- ❌ **Connection sharing**: Multiple Elixir processes sharing one connection
  - **Why deferred**: Each process should have its own client for isolation
  - **Post-MVP trigger**: Resource-constrained environments

### Developer Experience

**Deferred:**
- ❌ **Mix task for server scaffolding**: `mix mcp.gen.server`
  - **Why deferred**: Client library first; server helpers are separate scope
  - **Post-MVP trigger**: Community demand for server support

- ❌ **LiveView integration helpers**: Phoenix LiveView-specific utilities
  - **Why deferred**: Example pattern in docs sufficient for MVP
  - **Post-MVP trigger**: Reusable patterns for LiveView emerge

- ❌ **Distributed tracing**: OpenTelemetry integration
  - **Why deferred**: Telemetry events allow integration; native support is overkill
  - **Post-MVP trigger**: Enterprise monitoring requirements

---

## Post-MVP Roadmap Priority

**Tier 1 (High demand expected):**
1. Async notification dispatch (TaskSupervisor) - common pain point
2. Session ID gating - correctness hardening
3. Offload JSON decode pool - performance for large payloads

**Tier 2 (Medium demand):**
4. Connection pooling - high-throughput applications
5. ETS-based request tracking - scale beyond 1K concurrent
6. Resource caching - common application pattern

**Tier 3 (Niche/future):**
7. WebSocket transport - browser/WASM use cases
8. Compression - bandwidth optimization
9. Multiplexing - protocol optimization

---

## MVP Acceptance Criteria

**A working MVP must:**
1. ✅ Complete MCP initialize handshake successfully
2. ✅ List and call tools from reference MCP servers
3. ✅ Read resources and subscribe to updates
4. ✅ Handle connection failures with automatic reconnection
5. ✅ Enforce request timeouts and deliver responses reliably
6. ✅ Run under supervision without crashes
7. ✅ Provide telemetry for monitoring
8. ✅ Pass property tests for core guarantees
9. ✅ Work with stdio, SSE, and HTTP transports
10. ✅ Ship with comprehensive documentation and examples

**MVP is NOT:**
- ❌ A high-performance, scale-to-10K-connections client (that's post-MVP)
- ❌ A server implementation (separate scope)
- ❌ A workflow orchestration layer (application concern)
- ❌ Feature-complete for all possible MCP extensions (extensible foundation)

---

## Rationale: Why This Scope?

**Completeness for real use:**
- Covers all core MCP features (resources, prompts, tools, sampling)
- Three transport options for different deployment scenarios
- Sufficient reliability for production applications

**Mechanical correctness:**
- State machine is complete and testable (ADR-0001)
- Supervision strategy is proven (ADR-0002)
- Error handling is deterministic
- No hidden complexity or "magic"

**Shippable in timeframe:**
- ~2000 lines of core code (estimated)
- ~1500 lines of tests
- ~1000 lines of documentation
- ~3 weeks full-time effort for one developer

**Enables post-MVP evolution:**
- Transport behavior is abstracted (easy to add new transports)
- State machine can be extended (new states for advanced features)
- Telemetry events are stable (instrumentation won't break)
- API surface is minimal (few breaking changes needed)

---

## References

- Design Document 02 (gpt5.md): Initial scope decisions
- Design Document 04 (v2_gpt5.md), Section 13: "Things I'm intentionally leaving as options"
- Design Document 08 (gpt5.md), Section 15: "What's NOT in MVP"
- Design Document 10 (final spec), Final section: "What's NOT in MVP"
- All other ADRs: Specific deferred alternatives per decision
