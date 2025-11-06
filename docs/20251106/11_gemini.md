This is an outstanding series of documents. The evolution from a comprehensive, feature-rich design to a surgically-refined, mechanically-precise MVP specification is a textbook example of mature engineering discipline. The process of critical feedback and iterative refinement has produced a final spec (`10_gpt5.md`) that is robust, unambiguous, and ready for implementation.

The final locked MVP spec is excellent. The choices made are pragmatic, prioritizing stability, simplicity, and predictability. The following comments are not criticisms of flaws but rather final confirmations and minor clarifications to ensure the implementation is as smooth as the design process.

### Overall Assessment: Mechanically Sound and Ready to Ship

The final design (`10_gpt5.md`) is green-lit for implementation. The decisions made regarding tombstones, backpressure, supervision, and state transitions are all sound and well-justified. You have successfully navigated the trade-offs between correctness, simplicity, and features for an initial release.

### Minor Refinements and Implementation Notes

These are not blockers but subtle points to keep in mind during implementation that will further harden the design.

**1. Backoff Reset Mechanism**
The state transition table is comprehensive. One action should be made explicit to complete the backoff lifecycle:
*   **Concern**: The exponential backoff delay needs to be reset after a successful connection.
*   **Suggestion**: Add an explicit action to the `:initializing` -> `:ready` transition.
    ```
    | :initializing  | init_response(ok,caps) | valid caps | store caps; reset_backoff_delay; ... | :ready |
    ```
    This ensures that after a successful reconnect, the next potential failure starts the backoff cycle from `backoff_min`, not from where it left off.

**2. Transport Failure vs. Link Semantics in MVP**
The decision to rely solely on the `rest_for_one` supervision strategy without explicit process links is an excellent simplification for the MVP.
*   **Clarification**: The earlier design (`06_gpt5.md`) correctly described a choreography where `Connection` would trap exits from a linked `Transport`. In the final MVP spec, this is no longer the case.
*   **Implementation Note**: The `Connection` process no longer needs to `Process.flag(:trap_exit, true)`. If the `Transport` process dies, the `ConnectionSupervisor` will simply terminate the `Connection` process and then restart both in the correct order. This is simpler and relies entirely on standard OTP supervision, which is a strength. Ensure this simplification is reflected in the code.

**3. Observability of Request `params`**
The decision to exclude `params` from the request map in the `Connection` state is a good one for bounding memory.
*   **Concern**: This has a minor downstream effect on telemetry.
*   **Implementation Note**: If you want to log request parameters on a timeout or failure, the telemetry event must be emitted *at the time of the call* with the parameters included in the metadata. It will not be possible for a telemetry handler to ask the `Connection` process for the parameters of a timed-out request, as they will have already been discarded. This is an acceptable trade-off, but the team responsible for observability should be aware of it.

**4. Tombstone Cleanup and Lookup**
The periodic sweep is the right choice.
*   **Clarification**: The design correctly states "Lookup still checks TTL to avoid false positives between sweeps." This is a critical detail. A response for a timed-out request could arrive moments before the sweeper runs. The lookup logic must always validate the timestamp, ensuring the "belt and suspenders" approach is fully implemented.

### Post-MVP Considerations (For the Roadmap)

The choices made for what to *exclude* from the MVP are just as important as what was included. The following are natural next steps for hardening the client post-MVP, and the current design provides a solid foundation for them.

*   **Session ID Gating**: This remains the single most impactful feature for guaranteeing correctness over long-lived network partitions. The current tombstone TTL formula is a very strong heuristic, but session IDs provide a mathematical guarantee.
*   **Async Notification Handling**: As soon as users have notification handlers that perform any I/O (e.g., writing to a database, calling another service), the need for a `Task.Supervisor` will become apparent. The current synchronous model is a reasonable starting point, but this will likely be one of the first features requested by advanced users.
*   **Dynamic Capability Negotiation**: Making the `reset_notification_method` and `max_frame_bytes` part of the `initialize` handshake would make the client more adaptive to different server implementations.

### Final Verdict

The design process has been exemplary, culminating in a specification that is clear, concise, and mechanically sound. The document provides an unambiguous blueprint for developers to follow, minimizing implementation risk and ensuring the final product will be stable and predictable. You are ready to write the code.
