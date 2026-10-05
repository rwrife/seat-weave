# Issue #15 — ready-to-share selected-plan review

This is a host-only review of the **selected variant**. It separately lists unseated guests, empty seats (informational), conflicting pair preferences and unresolved pair preferences. Each item offers a route to the guest, table or preference. A conflict can be explicitly acknowledged as intentional; the rule evaluation stays **conflict**, and unseated/unresolved items stay outstanding. Acknowledgements are session-only and keyed by event, variant, preference, contradiction flag and both guest seat assignments. The app drops stale acknowledgements after successful saved commands and undo, even if seats later return to their old state; relaunch starts with a fresh review.

The review never enters `PublicSeatingExport`. After reviewing, the host can still choose **Preview shared list** for a deliberate draft and save text or PDF; the existing export preview shows public content and warns separately. Full JSON backups remain private and include pair preferences (never shared through this flow). This is not an optimizer or a completeness certification.

## Verification

- Linux Swift 6.0 Docker `swift test` on initial domain changes: 56 tests passed, including 3 new review tests for incomplete, complete-with-empty-seats, conflicting/acknowledged/invalidated states. This is package-only evidence, not an iOS build.
- Native app compiled on macOS run 37305242324 at ddf837a; 66 package tests passed, and Launch, compact Seating and WorkspaceTransition journeys passed. The Share journey failed at line 117 because the newly added review section pushed the bottom Delete-all row out of SwiftUI List's lazy realized window. It did not exercise that deletion step, and the regular-width suite was not reached. Fix below needs a fresh exact-head CI run.
- Full native/UI gate: **PENDING fresh exact-head pinned macOS CI**. Do not claim simulator, physical-device or human accessibility evidence until the job and provenance are checked.
- Physical VoiceOver, Switch Control, on-device network and signed release: **UNVERIFIED**; tracked by #6/#22/#7. No device evidence is inferred from this review.

## CI repairs

- Run 37305242324 (head ddf837a): Share journey failed before Delete-all because the new top review section pushed the bottom action out of the lazily realized List window. Added a bounded frontmost-collection scroll-until-hittable loop before tapping; next head must pass the actual simulator journey. This is an XCUITest reachability repair, not proof that the original failing deletion ran.
