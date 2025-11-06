This is an excellent, professional-grade design document. It demonstrates a deep understanding of OTP principles and addresses the critical complexities of a fault-tolerant client library. The proposed architecture is robust, resilient, and sympathetic to the BEAM.

The following points are not criticisms of flaws, but rather surgical refinements to further harden the design against subtle edge cases and improve clarity.

### 1. State Machine: Handling of Transient States

The state machine is comprehensive. A minor refinement could be to introduce transient states for processes that involve internal state clearing and re-negotiation, providing more specific feedback to callers during these brief periods.

*   **Observation:** The transition for a server-wide cancellation (`notifications/cancelled`) moves from `:ready` directly to `:initializing`.
*   **Potential Edge Case:** If a user call arrives at the precise moment the state machine has decided to transition but before it has fully entered `:initializing` and cleared its request table, the call might be accepted but then immediately cancelled. The user would receive a generic `{:error, :cancelled_by_server}` without context.
*   **Suggested Refinement:** Introduce a transient `:re_syncing` state.
    *   **:ready** -> on `notifications/cancelled` -> **:re_syncing**
    *   In `:re_syncing`, immediately clear the request table and tombstone all in-flight requests. Any new user calls received in this state are replied to with `{:error, :re_syncing}`.
    *   After cleanup is complete, emit an internal event to transition to **:initializing**.
    *   This makes the lifecycle more observable and provides more precise error feedback to callers during this specific, recoverable failure mode.

### 2. Cancellation Protocol: Tombstone Robustness Under Network Partition

The tombstone mechanism is a solid pattern for handling late responses. Its primary vulnerability is a fixed TTL, which may not be sufficient during extended network partitions.

*   **Observation:** Tombstones are given a fixed TTL (e.g., 30 seconds) to guard against late responses for timed-out or cancelled requests.
*   **Potential Edge Case:** A network partition or a heavily delayed server could last longer than the tombstone's TTL. If a response arrives after the tombstone has expired, it could be delivered to a caller that has already received a timeout error, violating the "exactly one terminal outcome" guarantee.
*   **Suggested Refinement:** Augment TTL-based tombstones with a *session identifier*.
    1.  When the `Connection` `gen_statem` successfully transitions from `:initializing` to `:ready`, it generates a new, unique session identifier (e.g., using `System.unique_integer([:positive])`). This ID is stored in the `gen_statem`'s data.
    2.  Every outgoing request includes this session ID in its entry in the `requests` table: `{id, from, deadline_mono, correlation_id, session_id}`.
    3.  When a response arrives, the `Connection` checks not only for a matching `id` but also verifies that the `session_id` from the original request matches the *current* session ID.
    4.  If the session IDs do not match, it means the response is from a previous session (before a reconnect/re-init). The response is safely discarded, even if its tombstone has expired. This provides a much stronger guarantee against late, stale responses.

### 3. Supervision Hierarchy: Clarifying Process Linking Semantics

The `rest_for_one` strategy is the correct choice here, and the justification is perfect. The explanation of how `link`ing solves the "footgun" of a crashed `Connection` is a key insight. We can make the description of the fault-tolerance even more precise.

*   **Observation:** The design correctly states that the `Connection` links to the `Transport` PID.
*   **Potential for Clarification:** Explicitly describe the full signal propagation for the key failure scenarios to leave no room for ambiguity.
    *   **Scenario A: Transport Dies:**
        1.  `Transport` process terminates with `reason`.
        2.  `ConnectionSupervisor` (using `rest_for_one`) restarts the `Transport`.
        3.  Because the `Connection` was linked to the old `Transport` PID, it receives an `EXIT` signal from the dead process.
        4.  The `Connection` (which should be trapping exits) handles this signal, likely translating it into the internal `io({:transport_down, reason})` event, causing it to transition to `:backoff`.
        5.  Simultaneously, the supervisor restarts the `Connection` process itself because it is "after" the transport in the child list. The new `Connection` will then discover the new `Transport`.
    *   This detailed sequence confirms that both linking and the supervision strategy work in concert to ensure a clean recovery.

### 4. Backpressure: A Note on Fairness

The backpressure mechanism is excellent for preventing mailbox overload and bounding latency. However, it's worth noting a potential fairness issue in extreme load scenarios.

*   **Observation:** Large JSON payloads are offloaded to a `Task.Supervisor`, and the number of concurrent decoders is capped. If the cap is reached, `set_active(:once)` is deferred, pausing input from the transport.
*   **Potential Edge Case:** If a single, very large frame is being decoded, it occupies a decoder slot. If a subsequent burst of very small, fast-to-process frames arrives, they will be blocked from being read off the socket until the large frame's decode is complete. This is a form of head-of-line blocking.
*   **Suggested Refinement:** This is likely an acceptable trade-off for simplicity, and no design change is necessarily required. However, the design could be strengthened by explicitly acknowledging this trade-off in the "Things I’m intentionally leaving as options" section. Mentioning that "the current backpressure model prioritizes system stability over strict fairness for mixed small/large workloads" would demonstrate foresight. For a system requiring absolute fairness, a more complex solution like separate processing queues or a weighted concurrency limiter could be considered, but is likely out of scope.

### 5. Transport Contract: `send_frame/2` Busy-Wait Retry

The error handling matrix specifies a retry for when the transport is busy, which is a crucial detail for resilience. This can be formalized slightly.

*   **Observation:** The error matrix states that if `send_frame/2` returns `:busy`, the action is to "Retry once with small delay else fail request".
*   **Potential for Clarification:** The retry mechanism can be implemented directly within the `gen_statem` without external processes.
    *   When `send_frame/2` returns `{:error, :busy}`, the `Connection` state machine can schedule a very short, one-off `:state_timeout` with an event like `{:internal, :retry_send, id, frame}`.
    *   When this timeout fires, it re-attempts the send. If it fails a second time, it replies to the original caller with `{:error, :backpressure}`.
    *   This uses the `gen_statem`'s built-in timer facilities and avoids blocking the `Connection` process while waiting to retry.

This design is already of exceptionally high quality. These suggestions are offered as minor refinements to further enhance its robustness and clarity.
