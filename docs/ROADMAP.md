# MCP Client Roadmap

Post-MVP features and enhancement timeline for the Elixir MCP Client library.

**Current Version:** 0.1.x (MVP)
**Last Updated:** 2025-11-10

---

## Overview

The MCP Client MVP (v0.1.x) provides a **complete, production-ready** foundation:
- ✅ All core MCP features (Tools, Resources, Prompts, Sampling, Roots, Logging)
- ✅ Three transport options (stdio, SSE, HTTP+SSE)
- ✅ Automatic reconnection with exponential backoff
- ✅ Request/response correlation with timeouts
- ✅ Flow control and reliability guarantees
- ✅ Comprehensive error handling

This roadmap outlines **post-MVP enhancements** prioritized by:
1. **User demand** - Features users request most frequently
2. **Impact** - Token reduction, performance, developer experience
3. **Complexity** - Faster to ship = higher priority

---

## Release Timeline

| Version | Focus | Features | ETA |
|---------|-------|----------|-----|
| **0.1.x** | MVP | Core protocol, 3 transports, all MCP features | ✅ Shipped |
| **0.2.x** | Code Execution | Code generation tool, progressive discovery | Q1 2026 |
| **0.3.x** | Performance | Async handlers, connection pooling, caching | Q2 2026 |
| **0.4.x** | Advanced Reliability | Session IDs, request replay, ETS tracking | Q3 2026 |
| **1.0.x** | Stability | WebSocket transport, compression, polish | Q4 2026 |

**Note:** Timeline subject to change based on user feedback and community contributions.

---

## Tier 1: High Priority (v0.2.x - v0.3.x)

### 1. Code Generation Tool (`mix mcp.gen.client`)

**Priority:** ⭐⭐⭐⭐⭐ (HIGHEST)
**Impact:** **98.7% token reduction** for large tool sets
**Status:** Design complete ([CODE_EXECUTION_PATTERN.md](design/CODE_EXECUTION_PATTERN.md))
**ETA:** v0.2.0 (Q1 2026)

Generate Elixir modules from MCP server tools to enable code execution pattern:

```bash
# Generate client modules
mix mcp.gen.client --server salesforce --output lib/mcp_servers/

# Agent writes code instead of calling tools directly
alias MCPServers.Salesforce
{:ok, leads} = Salesforce.query(conn, "SELECT * FROM Lead")
```

**Benefits:**
- Connects to 100+ tools without context overflow
- Agents write code (3 tokens) instead of tool calls (150K tokens)
- Data stays in memory, not in model context
- 75× cheaper for large tool sets (Anthropic case study)

**Why Tier 1:** Unlocks MCP for enterprise applications with hundreds of tools (Salesforce, Google Workspace, ServiceNow).

### 2. Progressive Tool Discovery

**Priority:** ⭐⭐⭐⭐
**Impact:** Context efficiency for large tool sets
**Status:** Proposed in CODE_EXECUTION_PATTERN.md
**ETA:** v0.2.0 (Q1 2026)

Load tools on-demand instead of all upfront:

**Option A: Filesystem-style discovery**
```elixir
# List tool categories
{:ok, categories} = McpClient.Tools.list_categories(conn)
# => ["google_drive", "salesforce", "slack"]

# List tools in category (detail levels: name-only, minimal, full)
{:ok, tools} = McpClient.Tools.list(conn, category: "salesforce", detail: :minimal)
```

**Option B: Search API**
```elixir
# Search for specific tools
{:ok, tools} = McpClient.Tools.search(conn, "update customer")
# => [%Tool{name: "salesforce__update_account", ...}]
```

**Why Tier 1:** Complements code generation tool for context efficiency.

### 3. Async Notification Dispatch

**Priority:** ⭐⭐⭐⭐
**Impact:** Prevents slow handlers from blocking connection
**Status:** Captured in [ADR-0015](adr/0015-async-notification-dispatch-roadmap.md) (deferred implementation)
**ETA:** v0.3.0 (Q2 2026)

Dispatch notifications to TaskSupervisor instead of blocking:

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  notification_handler: &MyApp.NotificationHandler.handle/1,
  notification_mode: :async  # New option
)
```

**Benefits:**
- Slow handlers don't block connection
- Parallel notification processing
- Better throughput for high-frequency notifications

**Why Tier 1:** Common pain point when handlers do I/O (write to database, call APIs).

### 4. Session ID Gating

**Priority:** ⭐⭐⭐
**Impact:** Correctness hardening (prevents stale responses)
**Status:** Deferred in [ADR-0005](adr/0005-global-tombstone-ttl-strategy.md)
**ETA:** v0.3.0 (Q2 2026)

Absolute guarantee against stale responses across session boundaries:

```elixir
# Session ID embedded in every request
%{jsonrpc: "2.0", id: 1, method: "...", meta: %{session_id: "abc123"}}

# Reject responses from old sessions
if response.meta.session_id != state.session_id do
  :discard  # Old session, ignore
end
```

**Why Tier 1:** Hardens correctness for production applications with frequent reconnections.

### 5. Offload JSON Decode Pool

**Priority:** ⭐⭐⭐
**Impact:** Performance for large payloads (> 1MB)
**Status:** Deferred in [ADR-0004](adr/0004-active-once-backpressure-model.md)
**ETA:** v0.3.0 (Q2 2026)

Decode large frames in separate tasks to avoid blocking connection:

```elixir
# If frame > 1MB, offload decode
if byte_size(frame) > 1_048_576 do
  Task.Supervisor.async_nolink(DecodePool, fn ->
    Jason.decode!(frame)
  end)
end
```

**Why Tier 1:** Profiling shows decode blocking for large resource reads (multi-MB documents).

### 6. Pluggable State Store & Registry Adapters

**Priority:** ⭐⭐⭐  
**Impact:** Unlocks ETS/Redis/Horde-backed coordination, improves observability  
**Status:** Defined in [ADR-0013](adr/0013-pluggable-state-store-and-registry-adapters.md)  
**ETA:** v0.3.0 (Q2 2026)

Ship `McpClient.StateStore` and `McpClient.RegistryAdapter` behaviours with default in-memory + `Registry` implementations, allowing applications to opt into ETS tables, Redis-backed registries, or Horde without forking the FSM.

**Why Tier 1:** Requested repeatedly by community maintainers (Valim thread) to support multi-node deployments and richer debugging.

### 7. Transport Customization Hooks

**Priority:** ⭐⭐⭐  
**Impact:** Lets teams reuse hardened Finch pools / HTTP stacks, encourages third-party transports  
**Status:** Defined in [ADR-0014](adr/0014-transport-customization-and-http-client-overrides.md)  
**ETA:** v0.3.0 (Q2 2026)

Expose configuration for Finch pool overrides (`:finch`, `:http_client`) and document the `McpClient.Transport` plug-in workflow so custom transports (WebSocket, proprietary SSE) can be published independently.

**Why Tier 1:** Reduces pressure to fork the repo just to change HTTP client details; unblocks enterprise networking requirements.

---

## Tier 2: Medium Priority (v0.3.x - v0.4.x)

### 6. Connection Pooling

**Priority:** ⭐⭐⭐
**Impact:** High-throughput applications (> 100 req/sec per server)
**Status:** Deferred in [ADR-0010](adr/0010-mvp-scope-and-deferrals.md)
**ETA:** v0.4.0 (Q3 2026)

Multiple connections to same server, round-robin dispatch:

```elixir
children = [
  {McpClient.Pool, [
    name: MyApp.MCPPool,
    size: 5,
    transport: {Stdio, cmd: "mcp-server"}
  ]}
]

# Automatically load-balances across pool
McpClient.Pool.call(MyApp.MCPPool, "tools/call", params)
```

**Why Tier 2:** Single connection sufficient for most applications; needed for high-throughput use cases.

### 7. ETS-Based Request Tracking

**Priority:** ⭐⭐⭐
**Impact:** Scale beyond 1000 concurrent requests
**Status:** Deferred in [ADR-0003](adr/0003-inline-request-tracking-in-connection.md)
**ETA:** v0.4.0 (Q3 2026)

Store pending requests in ETS instead of map in gen_statem state:

```elixir
:ets.new(:mcp_requests, [:set, :public, read_concurrency: true])

# Multiple processes can read concurrently
:ets.lookup(:mcp_requests, request_id)
```

**Why Tier 2:** Map in state works for < 1000 concurrent; ETS needed for extreme scale.

### 8. Resource Caching

**Priority:** ⭐⭐⭐
**Impact:** Reduces redundant reads, improves performance
**Status:** Application-level in MVP, library helper proposed
**ETA:** v0.4.0 (Q3 2026)

Built-in caching with automatic invalidation:

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  cache: McpClient.Cache.ETS  # Or :none (default)
)

# First call: reads from server
{:ok, contents} = McpClient.Resources.read(conn, uri)

# Second call: returns from cache
{:ok, contents} = McpClient.Resources.read(conn, uri)  # Cached

# Automatically invalidated on resources/updated notification
```

**Why Tier 2:** Common pattern; users can build their own for MVP.

### 9. Request Replay After Reconnect

**Priority:** ⭐⭐
**Impact:** Transparent reconnection (retry in-flight requests)
**Status:** Deferred in [ADR-0010](adr/0010-mvp-scope-and-deferrals.md)
**ETA:** v0.4.0 (Q3 2026)

Automatically retry in-flight requests after reconnection:

```elixir
# Request in-flight when connection drops
McpClient.Tools.call(conn, "tool", %{})

# Connection reconnects, request automatically retried
# → Returns {:ok, result} or {:error, reason}
```

**Configuration:**
```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  replay_requests: true  # Default: false (fail fast)
)
```

**Why Tier 2:** Most operations are idempotent; fail-fast is acceptable default.

---

## Tier 3: Niche/Future (v1.0.x+)

### 10. WebSocket Transport

**Priority:** ⭐⭐
**Impact:** Browser/WebAssembly use cases
**Status:** Deferred in [ADR-0010](adr/0010-mvp-scope-and-deferrals.md)
**ETA:** v1.0.0 (Q4 2026)

Two-way communication over WebSocket:

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.WebSocket, url: "wss://..."}
)
```

**Why Tier 3:** stdio/SSE/HTTP cover server use cases; WebSocket for browser clients.

### 11. Compression (gzip/deflate)

**Priority:** ⭐⭐
**Impact:** Bandwidth optimization for large payloads
**Status:** Deferred in [ADR-0010](adr/0010-mvp-scope-and-deferrals.md)
**ETA:** v1.0.0 (Q4 2026)

Automatic compression for frames > 10KB:

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  compression: :gzip  # or :deflate, :none (default)
)
```

**Why Tier 3:** Most payloads < 10KB; 16MB limit sufficient for MVP.

### 12. Multiplexing

**Priority:** ⭐
**Impact:** Protocol optimization (multiple logical channels over one transport)
**Status:** Deferred in [ADR-0010](adr/0010-mvp-scope-and-deferrals.md)
**ETA:** Future

Requires protocol extension; deferred until MCP spec supports it.

### 13. Skills Pattern

**Priority:** ⭐⭐
**Impact:** Reusable agent code libraries
**Status:** Proposed in CODE_EXECUTION_PATTERN.md
**ETA:** Post-v0.2.0

Filesystem-based reusable agent functions:

```elixir
# .skills/salesforce/find_leads.ex
defmodule Skills.Salesforce.FindLeads do
  def call(conn, criteria) do
    # ... reusable code ...
  end
end

# Agent loads and uses skills
import Skills.Salesforce.FindLeads
{:ok, leads} = call(conn, %{status: "New"})
```

**Why Tier 3:** Application-level concern; requires code generation foundation.

### 14. PII Tokenization Layer

**Priority:** ⭐⭐
**Impact:** Enterprise compliance (GDPR, HIPAA)
**Status:** Proposed in CODE_EXECUTION_PATTERN.md
**ETA:** Future (post-v0.2.0)

Automatic tokenization of sensitive data:

```elixir
# SSN flows through execution environment, not model context
{:ok, result} = Healthcare.get_patient_record(conn, patient_id)
# Model sees: "SSN: <TOKEN_abc123>"
# Code sees: "SSN: 123-45-6789"
```

**Why Tier 3:** Complex security feature; needs careful design and audit.

### 15. Execution Sandbox

**Priority:** ⭐
**Impact:** Secure code execution for production agents
**Status:** Proposed in CODE_EXECUTION_PATTERN.md
**ETA:** Future (post-v0.2.0)

Secure environment for agent-written code:

```elixir
{:ok, result} = McpClient.Sandbox.execute(code, conn, timeout: 30_000)
```

**Features:**
- OS-level isolation (containers, VMs)
- Resource limits (CPU, memory, network)
- Restricted syscalls

**Why Tier 3:** Complex infrastructure; needed only for fully autonomous agents.

---

## Feature Status Legend

- ⭐⭐⭐⭐⭐ Highest priority (Tier 1, v0.2.x-v0.3.x)
- ⭐⭐⭐ High priority (Tier 2, v0.3.x-v0.4.x)
- ⭐⭐ Medium priority (Tier 3, v1.0.x+)
- ⭐ Low priority (future, depends on demand)

---

## How to Influence Priorities

**We prioritize based on:**
1. **User feedback** - Open issues/discussions on GitHub
2. **Measurements** - Profiling data showing bottlenecks
3. **Community contributions** - PRs for features move them up

**To request a feature:**
1. Open GitHub issue with:
   - Use case (why you need it)
   - Impact (how many users affected)
   - Workarounds (what you're doing now)
2. Add 👍 reactions to existing issues
3. Contribute PRs (we'll review and merge)

**Feature requests with high demand move up in priority.**

---

## Contributing

We welcome contributions! Here's how to help:

### 1. Implement a Feature

Check roadmap for features marked "Help Wanted":
- Code generation tool (needs TypeSpec parsing, code generation)
- Progressive tool discovery (needs API design, server collaboration)
- Async notification dispatch (needs TaskSupervisor integration)

### 2. Report Feedback

Use MVP and tell us:
- What's working well
- What's painful
- What you're building

### 3. Write Guides/Examples

- Integration guides (Phoenix, Nerves, Livebook)
- Example applications
- Blog posts, tutorials

---

## FAQ

### When will feature X be available?

Check the ETA column in this roadmap. Dates are estimates and may change based on priorities.

### Can I use beta/unreleased features?

We may publish pre-release versions (0.2.0-rc1) for testing. Check GitHub releases.

### What if my needed feature is Tier 3?

- Check if there's a workaround (see user guides)
- Open an issue explaining your use case (may reprioritize)
- Contribute a PR (fastest path to inclusion)

### Will adding features break my code?

We follow semantic versioning:
- **Patch (0.1.x):** Bug fixes only (safe to upgrade)
- **Minor (0.x.0):** New features, backwards compatible (safe to upgrade)
- **Major (x.0.0):** Breaking changes (review before upgrading)

MVP → v0.2.x will be backwards compatible.

---

## Stay Updated

- **GitHub Releases:** Watch repository for release notifications
- **Changelog:** Check [CHANGELOG.md](CHANGELOG.md) for release notes
- **GitHub Issues:** Follow feature discussions
- **Community:** Join Elixir Forum discussions

---

**Questions?** Open an issue or check the [FAQ](guides/FAQ.md).
