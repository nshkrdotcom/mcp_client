# 12. Tool Modes and Session Flexibility

**Status:** Accepted  
**Date:** 2025-11-08  
**Deciders:** Engineering Team  
**Context:** Community feedback on Anubis/Hermes lineage

## Context and Problem Statement

Community reviewers asked for:

1. A **first-class separation between protocol plumbing and tool behavior**, with tooling able to declare whether it needs shared state.
2. **Optional session semantics** so stateless tools can execute without paying for long-lived frame processes or session IDs.
3. **Better multi-connection ergonomics**—servers often serve *N* clients, so the SDK must help register and discover per-transport processes rather than assume a singleton.

ADR-0011 covers the architectural split between core and feature modules, but it assumed all tools behaved the same. ADR-0005 deferred session identifiers entirely to post-MVP. As a result, the docs could not explain how the client honors stateful vs. stateless execution or how transports should be registered in larger deployments.

## Decision Drivers

- Tools must be able to **declare their execution requirements** explicitly.
- Stateless executions should be able to **skip session tracking** to reduce complexity during one-off interactions.
- Stateful executions must continue to **run within the connection/frame process** so they can access negotiated context, streaming notifications, and transport state.
- The **registry story must be built-in** so supervisors can discover the correct Connection/transport pair when multiple clients are active.
- Documentation must match the expectations expressed by the Elixir community (José Valim et al.) that the SDK is not limited to “single instance” processes.

## Considered Options

1. **Implicit detection:** infer statefulness by inspecting tool metadata (e.g., presence of subscriptions).  
   *Rejected* – unclear, brittle, and puts guesswork inside the client.

2. **Global toggle:** start the connection in either stateful or stateless mode.  
   *Rejected* – real deployments mix both kinds of tools; a global flag would force users to run two different clients.

3. **Per-tool mode declaration with optional sessions (chosen).**

## Decision Outcome

Each tool definition now carries a `mode: :stateful | :stateless` attribute. The client reacts as follows:

1. **Stateless tools**
   - Executed in an isolated request process (`Task.Supervisor` under the caller).  
   - Do **not** require a session identifier; requests omit `meta.session_id`.  
   - Connection skips tracking session IDs entirely if **all** advertised tools are stateless.

2. **Stateful tools**
   - Execute inside the Connection’s frame/SSE process.  
   - Always include the current `session_id` in request metadata.  
   - Require the connection to remain in `:ready` state with an active session.

3. **Mixed workloads**
   - Connection stays session-aware as soon as a single stateful tool is advertised or invoked.  
   - Stateless invocations still run in isolated processes but inherit the current session metadata for tracing consistency.

4. **Registries and multi-connection support**
   - All transports and connections must be started via a provided `McpClient.ConnectionRegistry` helper (see GUIDES) or an equivalent `{:via, Registry, ...}` tuple.  
   - Supervisor templates and prompts were updated to show registry-backed startup by default, ensuring N:1 servers are supported without manual wiring.

## Implementation Details

- **Schema** – `McpClient.Tools.Tool` gains a `field :mode, :stateful | :stateless, default: :stateful`.  
- **Capability checks** – `Tools.ensure_capability/2` now cross-checks the requested execution mode (errors if a server claims stateless-only but receives stateful calls).  
- **Connection state** – `session_mode` tracks `:required | :optional`, and the state machine toggles session tracking accordingly.  
- **Request metadata** – new helper `Connection.inject_session_meta/2` includes session IDs only when `session_mode == :required`.  
- **Documentation** – MVP spec, feature docs, prompts, and guides now document the two execution modes and the registry requirement.

## Consequences

**Positive**
- Clearer mental model for library users; tool authors can reason about where their code runs.
- Stateless-only deployments (e.g., HTTP request/response tools) can avoid session churn.
- Supervisors can run multiple connections per server without bespoke registry code.

**Negative**
- Slightly more complex tool schema and Connection state machine.
- Mixed workloads must account for both execution paths in tests.

**Neutral**
- Session ID gating remains on the roadmap for v0.3, but the groundwork (mode-aware metadata) is now laid.

## References

- Community recap provided by user (`<ctx>` in conversation).  
- ADR-0011 (updated) – adds per-tool mode semantics.  
- MVP_SPEC v1.1 – documents `session_mode` and registry-backed startup.  
- GUIDES/ADVANCED_PATTERNS – new `ConnectionRegistry` helper.
