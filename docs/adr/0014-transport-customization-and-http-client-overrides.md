# 14. Transport Customization and HTTP Client Overrides

**Status:** Accepted  
**Date:** 2025-11-10  
**Deciders:** Engineering Team  
**Context:** Follow-up to ADR-0002 (supervision) and ADR-0004 (transport contract)

## Context and Problem Statement

The MVP ships three first-party transports (`Stdio`, `SSE`, `StreamableHTTP`) that implement `McpClient.Transport`. Users
asked for:

- Supplying their own transport modules (e.g., company-specific WebSocket/SSE stacks).
- Overriding HTTP clients / Finch pools to integrate with existing telemetry, connection reuse, or proxies.
- Extending transport options (TLS pinning, custom headers) without patching the library.

While the behaviour already exists, the spec never codified how custom transports or HTTP pools plug in, leaving gaps in
documentation and prompting “should we fork?” questions.

## Decision

1. **Documented transport plug-in point**
   - `transport:` option in `McpClient.start_link/1` is formally defined as `{module(), keyword()}` where `module`
     implements `McpClient.Transport`. This is now part of the spec (Section 1.1 + Transport appendix).
   - The connection supervisor never instantiates transports directly; it relies on that module/opts tuple exclusively.

2. **HTTP client override hooks**
   - `McpClient.Transports.StreamableHTTP` will accept `:finch` (pool name or `{module, opts}`) and `:http_client`
     (module implementing a documented behaviour) once implemented post-MVP.
   - ADR references clarify that the default remains `Finch` via `Req`, but users can inject their own HTTP stack
     without reimplementing the transport.

3. **Transport behaviour guidance**
   - `docs/design/TRANSPORT_SPECIFICATIONS.md` now references this ADR and explicitly lists the required callbacks +
     message protocol so community transports can be tested independently.
   - Implementation prompts remind contributors not to bake Finch/Req specifics into the core connection.

## Consequences

- ✅ Third-party transports can be published as independent Hex packages without library forks.
- ✅ Enterprises can reuse hardened Finch pools or custom TLS configs by passing opts instead of patching code.
- ✅ Documentation becomes the single source of truth for the transport boundary, reducing repeated Slack/thread
  answers.
- ⚠ Requires careful testing of injected transports (we will ship a behaviour test helper post-MVP).
- ⚠ Support surface increases; we must clearly mark which options are “best effort” vs. battle-tested.

## Alternatives Considered

1. **Expose only first-party transports**
   - Rejected: contradicts community demand and forces forks for simple tweaks like custom headers.

2. **Generic `:http_client` option on `McpClient.start_link/1`**
   - Rejected: mixes transport decisions with connection configuration; behaviour per transport is clearer.

3. **Document nothing and rely on source diving**
   - Rejected: too much tribal knowledge, leads to inconsistent third-party modules.

## References

- ADR-0002: rest_for_one Supervision Strategy
- ADR-0004: Active-Once Backpressure Model
- ADR-0010: MVP Scope (transport list)
- Transport feedback from community thread (Finch overrides, 2025-08-01)
