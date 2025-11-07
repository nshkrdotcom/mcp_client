# Final Corrections Applied to MVP Specification

**Date:** 2025-11-06
**Status:** All Critical Issues Resolved

This document tracks the final surgical corrections applied to the MVP specification based on detailed technical review. All corrections are implementation-ready.

---

## Critical Correctness Fixes

### 1. ✅ Retry Path Preserves Per-Call Timeouts

**Issue:** Per-call timeout overrides were lost when request hit busy path and entered retry.

**Fix Applied:**
- **ADR-0007**: Store `timeout` field in request struct
- Request struct now: `%{from, method, started_at_mono, timeout}`
- Retry success uses stored `request.timeout` instead of defaulting

**Impact:** Calls with custom timeouts (e.g., `timeout: 120_000`) now work correctly through retry path.

**Files Changed:**
- `docs/adr/0007-bounded-send-retry-for-busy-transport.md`

---

### 2. ✅ Clear/Notify Retries on All Failures

**Issue:** Retry state was only cleared on shutdown, not on transport failures or reset notifications. This leaked reply paths and could cause duplicate/late replies.

**Fix Applied:**
- **STATE_TRANSITIONS.md**: Added `fail_and_clear_retries/2` helper function
- Updated actions for:
  - `:ready` + `transport_down` → fail/clear retries
  - `:ready` + oversized frame → fail/clear retries
  - `:ready` + reset notification → fail/clear retries
- All in-retry callers now receive appropriate error before state transition

**Impact:** No leaked retry state; consistent error delivery across all failure modes.

**Files Changed:**
- `docs/design/STATE_TRANSITIONS.md`

---

### 3. ✅ Init Ordering Explicit

**Issue:** State table didn't clarify that `initialize` request must be sent **before** calling `set_active(:once)`.

**Fix Applied:**
- **STATE_TRANSITIONS.md**: Changed action to "Send `initialize` request **then** set_active(:once)"
- Emphasized "**reset backoff_delay to backoff_min**" on successful init
- Clear ordering prevents implementer confusion

**Impact:** Correct sequencing ensures Connection is ready to receive init response.

**Files Changed:**
- `docs/design/STATE_TRANSITIONS.md`

---

### 4. ✅ Explicit JSON Decode Error Rows

**Issue:** Invalid JSON handling was mentioned in prose but not in state table rows.

**Fix Applied:**
- **STATE_TRANSITIONS.md**: Added explicit rows:
  - `:initializing` + invalid JSON → log warn; set_active(:once)
  - `:ready` + invalid JSON → log warn; set_active(:once)
- Prevents implementers from attempting to parse malformed payloads twice

**Impact:** Clear error path; Connection continues after decode failures.

**Files Changed:**
- `docs/design/STATE_TRANSITIONS.md`

---

## Documentation & Consistency Improvements

### 5. ✅ Retry Memory Footprint Documented

**Issue:** Storing full frame binary per retry wasn't explicitly documented as a tradeoff.

**Fix Applied:**
- **ADR-0007**: Added to Consequences:
  - Worst case: N concurrent retries × frame size (up to 16MB)
  - Post-MVP: reconstruct from `{id, method, params}` instead

**Impact:** Operators understand memory implications of retry under heavy load.

**Files Changed:**
- `docs/adr/0007-bounded-send-retry-for-busy-transport.md`

---

### 6. ✅ Unknown ID Logging Level

**Issue:** Logging unknown response IDs at `:warn` could be noisy during reconnections.

**Fix Applied:**
- **STATE_TRANSITIONS.md**: Changed "Warn + drop" to "Log at debug; drop"
- Reduces noise while preserving diagnostic capability

**Impact:** Less log spam during disorderly reconnections.

**Files Changed:**
- `docs/design/STATE_TRANSITIONS.md`

---

### 7. ✅ Telemetry Duration Calculation Clarified

**Issue:** Examples didn't show how duration was calculated from `started_at_mono`.

**Fix Applied:**
- **STATE_TRANSITIONS.md**: Added detailed telemetry section showing:
  - Store `started_at_mono` in request struct
  - Calculate `duration = System.monotonic_time() - request.started_at_mono`
  - Document monotonic for durations, system_time for wall-clock logs

**Impact:** Clear guidance on time source consistency.

**Files Changed:**
- `docs/design/STATE_TRANSITIONS.md`

---

### 8. ✅ Transport Message Contract Centralized

**Issue:** Transport message shapes (`{:transport, :up/frame/down}`) were scattered across docs.

**Fix Applied:**
- **STATE_TRANSITIONS.md**: Added "Transport Message Contract" section with exact shapes:
  ```elixir
  {:transport, :up}
  {:transport, :frame, binary()}
  {:transport, :down, reason}
  ```
- Requirements documented (`:up` once, `:frame` only after set_active, etc.)

**Impact:** Single source of truth for transport implementers.

**Files Changed:**
- `docs/design/STATE_TRANSITIONS.md`

---

### 9. ✅ Public stop/1 Returns Normalized :ok

**Issue:** Internal replies used `{:ok, :ok}` and `{:ok, :already_closing}`; public API shape was ambiguous.

**Fix Applied:**
- **ADR-0009**: Public `stop/1` normalizes both internal replies to `:ok`
- Documented idempotency: multiple calls always return `:ok`
- Matches spec: `stop(client()) :: :ok`

**Impact:** Consistent, simple public API; idempotency clearly documented.

**Files Changed:**
- `docs/adr/0009-fail-fast-graceful-shutdown.md`

---

### 10. ✅ Capability Validation Policy Noted

**Issue:** Version compatibility rule (`starts_with("2024-11")`) wasn't explicitly marked as MVP policy.

**Fix Applied:**
- **STATE_TRANSITIONS.md**: Added notes:
  - Accepts string/atom keys for test transport compatibility
  - YYYY-MM window is **MVP policy**; may require exact match post-MVP

**Impact:** Clear that version tolerance is intentional MVP choice, may tighten.

**Files Changed:**
- `docs/design/STATE_TRANSITIONS.md`

---

## Additional Invariants Added

### Time Source Consistency

Added to invariants list:
- Use `System.monotonic_time()` for durations, timeouts, TTLs
- Use `System.system_time()` only for wall-clock timestamps (logs, telemetry)

### No set_active After Close

Added explicit invariant:
- Oversized frame close or stop never calls `set_active(:once)` after `Transport.close/1`
- Actions annotated with "(no set_active)" where applicable

### Retry State Guarantees

Updated invariant:
- Every request in map has corresponding timeout
- Every retry in map will eventually complete or be cleared
- No orphaned retry state after failures

---

## Summary of Files Modified

| File | Changes |
|------|---------|
| `docs/adr/0007-bounded-send-retry-for-busy-transport.md` | Timeout storage, memory footprint, shutdown interaction |
| `docs/adr/0009-fail-fast-graceful-shutdown.md` | Normalized stop return, retry clearing |
| `docs/design/STATE_TRANSITIONS.md` | 10+ table rows, transport contract, telemetry, invariants, helpers |

---

## Verification Checklist

Before implementation starts, verify:

- [x] Per-call timeouts survive retry path
- [x] Retry state cleared on all failure transitions (transport_down, oversized, reset)
- [x] Initialize sent before set_active(:once)
- [x] Invalid JSON has explicit state table rows
- [x] Retry memory tradeoff documented
- [x] Unknown ID logging at debug level
- [x] Telemetry duration uses monotonic time correctly
- [x] Transport message shapes centralized
- [x] Public stop/1 returns :ok (normalized)
- [x] Capability validation marked as MVP policy

---

## Post-MVP Improvements Identified

**From retry memory footprint:**
- Reconstruct frames from `{id, method, params}` instead of storing full binary
- Or keep `iodata()` segments without copying

**From version compatibility:**
- Consider requiring exact version match instead of YYYY-MM window
- Add capability negotiation for version requirements

**From notification handler exceptions:**
- Emit `[:mcp_client, :notification, :handler_exception]` telemetry event
- Consider handler timeout enforcement (5s hard limit)

---

## Spec Status

**All critical correctness holes patched.**
**All documentation consistency issues resolved.**
**Specification is implementation-ready.**

Next step: Begin implementation following STATE_TRANSITIONS.md table exactly.

---

**Review Sign-Off:**
- Technical Correctness: ✅ Verified
- Documentation Completeness: ✅ Verified
- Implementation Readiness: ✅ Verified

**Frozen for MVP Implementation:** 2025-11-06
