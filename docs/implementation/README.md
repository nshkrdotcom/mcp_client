# Implementation Prompts - Index

This directory contains a series of self-contained implementation prompts for building the MCP Client library from scratch. Each prompt can be executed independently with zero prior context.

**Status:** Ready for implementation ✅
**Date:** 2025-11-06
**Approach:** Test-Driven Development (TDD) with rgr

---

## Implementation Order

Execute prompts in numerical order. Each prompt builds on previous work but includes all necessary context.

### Core State Machine (Prompts 01-05)

**PROMPT_01: Connection Scaffold**
- File: `PROMPT_01_connection_scaffold.md`
- Creates: `lib/mcp_client/connection.ex` skeleton
- Duration: ~30 minutes
- Tests: Basic initialization and configuration
- Dependencies: None

**PROMPT_02: Starting and Initializing States**
- File: `PROMPT_02_starting_and_initializing.md`
- Implements: `:starting` and `:initializing` state logic
- Duration: ~45 minutes
- Tests: Transport spawn, init handshake, capability validation
- Dependencies: PROMPT_01

**PROMPT_03: Ready State - Request/Response**
- File: `PROMPT_03_ready_state_requests.md`
- Implements: `:ready` state request handling, response routing, timeouts
- Duration: ~60 minutes
- Tests: Request lifecycle, tombstones, notifications
- Dependencies: PROMPT_01, PROMPT_02

**PROMPT_04: Ready State - Failures and Retry**
- File: `PROMPT_04_ready_failures_and_retry.md`
- Implements: Busy retry logic, failure paths, transport down handling
- Duration: ~60 minutes
- Tests: Concurrent retries, failure recovery, stop during retry
- Dependencies: PROMPT_01, PROMPT_02, PROMPT_03

**PROMPT_05: Backoff and Closing States**
- File: `PROMPT_05_backoff_and_closing.md`
- Implements: `:backoff` reconnection, `:closing` shutdown, tombstone sweep
- Duration: ~30 minutes
- Tests: Backoff progression, sweep, graceful shutdown
- Dependencies: PROMPT_01-04

---

### Transport Layer (Prompt 06)

**PROMPT_06: Transport Behavior and Stdio**
- File: `PROMPT_06_transport_behavior.md`
- Creates: `lib/mcp_client/transport.ex`, `lib/mcp_client/transports/stdio.ex`
- Duration: ~60 minutes
- Tests: Port I/O, active-once flow control, subprocess lifecycle
- Dependencies: None (can be done in parallel with 01-05)

---

### Public API and Integration (Prompts 07-08)

**PROMPT_07: Public API Module**
- File: `PROMPT_07_public_api.md`
- Creates: `lib/mcp_client.ex`, `lib/mcp_client/error.ex`
- Duration: ~45 minutes
- Tests: High-level API, synchronous requests, error normalization
- Dependencies: PROMPT_01-06

**PROMPT_08: Integration Tests**
- File: `PROMPT_08_integration_tests.md`
- Creates: `test/mcp_client/integration_test.exs`
- Duration: ~60 minutes
- Tests: All critical scenarios from PRE_IMPLEMENTATION_CHECKLIST.md
- Dependencies: PROMPT_01-07

---

### Documentation (Prompt 09)

**PROMPT_09: Documentation and README**
- File: `PROMPT_09_documentation.md`
- Creates: `README.md`, `examples/usage.exs`, `guides/configuration.md`
- Duration: ~30 minutes
- Tests: Documentation accuracy (manual review)
- Dependencies: PROMPT_01-08 (all features complete)

---

## Total Implementation Time

**Estimated:** 6-8 hours for experienced Elixir developer
**Actual may vary based on:** Testing thoroughness, debugging, iteration

---

## Success Criteria (All Prompts)

After completing all prompts, verify:

### 1. All Tests Pass

```bash
mix test
```

Expected output:
- ✅ All tests green
- ✅ No warnings
- ✅ No compilation errors
- ✅ Coverage > 90% (optional but recommended)

### 2. Critical Scenarios Pass

From PRE_IMPLEMENTATION_CHECKLIST.md:

- ✅ Concurrent busy retries don't interfere
- ✅ Transport down clears both requests and retries
- ✅ Oversized frames close without set_active
- ✅ Stop during retry prevents double replies
- ✅ Invalid caps trigger backoff, success resets delay
- ✅ Decode errors handled gracefully

### 3. Documentation Complete

- ✅ README.md renders correctly
- ✅ All API functions documented
- ✅ Examples are runnable
- ✅ Configuration guide complete

### 4. Code Quality

```bash
mix format --check-formatted
mix credo --strict
mix dialyzer
```

---

## Prompt Structure

Each prompt follows this template:

1. **Goal**: What you're building in this prompt
2. **Context**: Background and relationship to overall system
3. **Required Reading**: Exact specifications from ADRs/specs
4. **Implementation Requirements**: Detailed code to write
5. **Tests**: Comprehensive test suite
6. **Success Criteria**: How to verify completion
7. **Constraints**: What NOT to do
8. **Implementation Notes**: Tips and clarifications

---

## Testing Strategy

### Test-Driven Development (TDD)

For each prompt:

1. Read the test specifications
2. Write the tests first (they will fail)
3. Implement the code to make tests pass
4. Refactor while keeping tests green
5. Run full test suite before moving to next prompt

### rgr Workflow

If using rgr (recommended):

```bash
rgr
```

This watches files and auto-runs tests on changes.

### Manual Testing

```bash
# Run specific test file
mix test test/mcp_client/connection_test.exs

# Run with verbose output
mix test --trace

# Run specific test
mix test test/mcp_client/connection_test.exs:142
```

---

## Dependencies Between Prompts

### Can Be Done in Parallel

- PROMPT_01-05 (Connection) and PROMPT_06 (Transport) are independent
- Implement both tracks simultaneously if working in a team

### Must Be Sequential

- PROMPT_01 → PROMPT_02 → PROMPT_03 → PROMPT_04 → PROMPT_05
- PROMPT_07 requires PROMPT_01-06 complete
- PROMPT_08 requires PROMPT_01-07 complete
- PROMPT_09 requires all prompts complete

---

## Key Design Decisions

These ADRs inform all prompts:

- **ADR-0001**: gen_statem for connection lifecycle
- **ADR-0002**: rest_for_one supervision (simplified in MVP)
- **ADR-0003**: Inline request tracking in connection
- **ADR-0004**: Active-once backpressure model
- **ADR-0005**: Global tombstone TTL strategy
- **ADR-0006**: Synchronous notification handlers
- **ADR-0007**: Bounded send retry for busy transport
- **ADR-0008**: 16MB max frame size limit
- **ADR-0009**: Fail-fast graceful shutdown
- **ADR-0010**: MVP scope and deferrals

---

## Troubleshooting

### "Tests are flaky"

**Cause:** Race conditions with async processes

**Solution:**
- Use `Process.sleep/1` strategically in tests
- Seed :rand deterministically in setup
- Use `async: false` for tests with process interaction

### "Port tests failing"

**Cause:** Missing executables (cat, printf, etc.)

**Solution:**
- Ensure Unix commands available
- Use `System.find_executable/1` to check
- Skip tests if commands not found (use `@tag :unix`)

### "Timeout errors in tests"

**Cause:** Tests take longer than expected

**Solution:**
- Increase test timeouts in async tasks
- Use shorter timeouts in config for faster tests
- Check CPU load during test runs

### "Can't find module Transport"

**Cause:** Prompts depend on each other

**Solution:**
- Complete prompts in order
- Check all previous files created
- Verify compilation before running tests

---

## Post-MVP Enhancements

After completing all prompts, consider:

1. **SSE Transport** - Server-Sent Events over HTTP
2. **HTTP Transport** - Direct HTTP communication
3. **Telemetry** - Structured events for monitoring
4. **Connection Pooling** - Multiple concurrent connections
5. **Cancellation API** - Cancel in-flight requests
6. **Async Notifications** - TaskSupervisor for handlers
7. **Session Management** - Preserve state across reconnects

---

## Contributing

See `../adr/README.md` and `../design/README.md` for architecture context.

For implementation questions, refer to:
- `STATE_TRANSITIONS.md` - Complete state machine table
- `MVP_SPEC.md` - Technical specification
- Individual ADRs - Decision rationale

---

## Verification Checklist

Before considering implementation complete:

- [ ] All 9 prompts executed in order
- [ ] All tests pass (`mix test`)
- [ ] No compilation warnings
- [ ] No Credo warnings (`mix credo`)
- [ ] Dialyzer passes (`mix dialyzer`)
- [ ] README renders correctly
- [ ] Examples are runnable
- [ ] All critical scenarios pass (PROMPT_08)
- [ ] Code formatted (`mix format`)
- [ ] Documentation built (`mix docs`)

---

**Ready to implement?** Start with PROMPT_01! 🚀
