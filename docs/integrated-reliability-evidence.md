# Issue #6 evidence — integrated reliability, accessibility and offline privacy

Scope: reproducible regression coverage for the full seating journey,
deterministic randomized invariants and persistence/failure cases, the
large-text accessibility journey, and the offline-privacy static audit.
This document ALSO records the honest evidence matrix: what CI proves,
what the simulator proves, and which checks remain blocked pending
physical hardware, Apple access or a human operator. Nothing in the
"blocked" tier is ever marked passed.

Base commit this slice builds on: `04f68a4` (issue #4 merge, main).

## What was added

1. **Domain regression suite** — `Packages/SeatingDomain/Tests/
   SeatingDomainTests/ReliabilityInvariantsTests.swift`
   - `DeterministicRNG` (fixed LCG, integer seeds — never the system
     RNG) drives mixed assign/move/unseat/swap/addGuest/addTable/
     resize/duplicate/undo sequences.
   - Every step (accepted OR refused) is followed by occupancy, seat
     range, table count, guest count and variant count assertions, for
     8 fixed seeds x 80 steps.
   - Replay equality: the same seed produces an identical UUID-free
     structural projection across runs (4 seeds).
   - Persistence through the real `PersistentSeatingController`: after
     every successful random command the LAST SAVED snapshot equals the
     visible state (3 seeds x 40 commands); refused commands and failed
     writes provably leave the visible state unchanged.
   - Deterministic write-failure case: a recording saver that refuses
     saves mid-journey keeps the last good state and recovery resumes
     persistence afterwards.
   - Fuzzed end states still produce leak-free public exports (no
     preferences, no UUIDs) for 3 seeds.
2. **Full-journey store test (macOS-compiled)** — `FullJourneyStoreTests.swift`
   runs the complete create → assign → swap → undo → resize → duplicate →
   relaunch → export → restore journey against a real file-backed
   SwiftData store: reopen-the-store relaunch analogue, export privacy
   assertions, backup → validated restore into a NEW event, original
   event byte-identical afterwards, both events independent. This
   closes the restore gap that XCUITest cannot cover (the OS file panel
   is not automatable); `EventStoreTests` already prove an equivalent
   store reopen.
3. **Large-text accessibility journey (simulator)** — `UITests/
   SeatWeaveLargeTextJourneyTests.swift`, registered in the Xcode
   project and run by `Scripts/ci.sh` as its OWN xcodebuild invocation:
   before it, CI raises the destination content size with
   `xcrun simctl ui <udid> content_size accessibility-extra-extra-large`
   (the scripted equivalent of Settings ▸ Accessibility ▸ Display & Text
   ▸ Larger Text; runner processes cannot spawn xcrun from inside an iOS
   test, so the setting is applied outside the app) and restores the
   default size afterwards, even on failure. The app exposes a
   launch-flag-gated (`-contentProbe YES`, cleared at init so it can
   never leak into user launches) content-size probe rendering
   `UIApplication.preferredContentSizeCategory`; the test asserts the
   environment ACTUALLY reached the accessibility range before walking
   the journey — a default-size launch fails the gate instead of
   silently passing. The journey covers create → guests → table →
   assign → swap → undo → **resize (via the sheet stepper's Decrement
   control — first automated coverage of this control; the public
   `decrement()` API does not exist on the pinned SDK)** → duplicate →
   relaunch → public export preview, locating controls by scrolling.
4. **Static offline-privacy audit** — `Scripts/entitlement_audit.py` +
   6 helper tests, run as a new `offline_privacy_audit` phase in
   `Scripts/ci.sh` and in this slice's Linux verification. It scans all
   app/domain sources for forbidden imports (`Network`, `CloudKit`,
   `AdSupport`, `AppTrackingTransparency`, `CoreBluetooth`,
   `MultipeerConnectivity`), networking APIs (`URLSession`,
   `NWConnection`, `WCSession`), `CODE_SIGN_ENTITLEMENTS` in the
   project file, and (macOS mode) the built bundle's Info.plist keys,
   Mach-O load commands and forbidden frameworks.

## Actual verification output (this executor, Linux host)

Host: Linux 6.17.0-1032-nvidia (aarch64), Swift 6.2-noble container,
Python 3.12. All commands run inside the isolated worktree at commit
described above; outputs below are real command output, not restated
expectations.

- `swift test` (Swift 6.2 container, Linux): **58 tests in 9 suites,
  all passed**, including the new
  "Issue 6 randomized invariants, replay and persistence" suite
  (8-seed invariant sweep, 4-seed replay equality, 3-seed persistence
  sweep, write-failure recovery, 3-seed export leak-freedom).
  The SwiftData-gated suites (`EventStoreTests`, the new
  `FullJourneyStoreTests`) COMPILE AWAY on Linux — they are native-CI
  evidence, see the matrix below.
- `swiftc -parse` of the SwiftData-gated journey file after stripping
  its `#if`/`#endif` and `@testable import`: clean (structural parse
  only — type checking for that file is CI's job, stated honestly).
- `python3 -m unittest discover -s Scripts/tests`: **31 tests, OK**
  (21 pre-existing + 6 new audit tests + existing boot/select suites).
- `python3 Scripts/entitlement_audit.py --source-only` against the
  real tree: `violations: []`, exit 0.
- `bash -n Scripts/ci.sh` and pbxproj structural review: clean; new
  UITest file registered with unique IDs …10F/…20F in build file,
  file reference, UITests group and UITests sources phase.

## Native CI (required gate)

The pinned macOS job (Xcode 26.0.1/17A400 verified by actual
`xcodebuild -version` output, iOS SDK 26.0, exact PR-head checkout)
runs the new `offline_privacy_audit` phase, compiles the SwiftData
suites including the full-journey store test, and executes
`SeatWeaveLargeTextJourneyTests` on the pinned iPhone destination
alongside the pre-existing journeys. Run results are recorded in the PR
conversation once the run completes; the merge only happens on green.

## CI repairs

- Run 37584965653 attempt 1 (head dfd6714): simulator enumeration timed out
  twice before app build or tests. Same-SHA `--failed` rerun attempt 2 built
  and reached the AX5XL journey; the seat-2 swap step passed, proving the
  upward-direction repair, but `resize-Round1` never became tappable. Its
  failure hierarchy shows Seats 4–6 with scroll value **56%**, so the resize
  button is below the viewport. The generic 3-down/1-up recovery for missing
  elements needlessly reverses progress at this tiny viewport; the resize
  search now scrolls down only because that button follows every seat row.
  Fresh exact-head native evidence is still required.
- Run 37581217242 (head 27a82b7): pinned macOS build, SwiftData suites,
  compact journeys (Launch, Seating, GuestEditing, Share, WorkspaceTransition)
  completed. Regular-width tests were not reached after the large-text failure.
  `SeatWeaveLargeTextJourneyTests` reached
  the second assignment (2 seated), but the subsequent swap tap on
  `seat-Round1-2` failed after 25 seconds.
  Root cause from the failure-path element tree: after Aster was assigned to
  seat 1 and Basil to seat 2, the six-page list retained its scroll position;
  the visible elements were Seat 6 (y=291), Resize Round1 (y=433), and Add
  table (y=555), with vertical scroll bar at **92%**. `seat-Round1-2` was
  ABOVE the fold, not below it. The generic fallback was scrolling down three
  times for every one scroll up, which could never recover when the list was
  already past the target.
  Repair: `tap()` now derives scroll direction for seat identifiers
  (`seat-<tablePrefix>-<N>`) by comparing the requested seat number against the
  currently visible seat buttons on that table, scrolling upward when the target
  precedes the visible window. This is a hypothesis pending native evidence;
  simulator journeys remain simulator evidence, not physical-device verification.
- Run 37431466002 (head ee377b6): pinned macOS build and earlier UI journeys
  completed, but AX5XL `seat-Round1-2` failed after the 25-second tap hunt.
  The one-shot failure hierarchy confirms the Tables tab remained selected,
  and the six-page list's vertical scrollbar reached **100%**: the seat was
  above the viewport, not missing from the model or obscured by a tab switch.
  A `press(forDuration: 0.25, thenDragTo:)` controls only the initial hold;
  the subsequent gesture can still fling the short unobscured content band
  to the end. The next exact-head native run uses XCTest's slow drag velocity
  with a short final hold. This is a hypothesis pending native evidence, not
  a passed large-text journey. The new main also contains selected-plan review
  (#15); it is reconciled on this branch without dropping either feature.
- Run 37421115259 (head 15b6e1a): `SeatWeaveLargeTextJourneyTests` failed at
  line 330 checking `waitAny(app, identifier: "roster-Aster")`. Root cause:
  PR #23 merged guest editing, which changed roster row identifiers from
  static `roster-<name>` to UUID-based `roster-<UUID>` with accessibility
  label `"<name>, "`. The large-text journey was written before #23 and still
  expected the old identifier. Updated `waitRoster` and `tapRoster` to
  query via `rosterButton(app, name: ...)` matching label `CONTAINS "<name>, "`,
  matching `SeatWeaveSeatingJourneyTests` and `SeatWeaveRegularWidthTests`.
- Run 37304700172 (head 29fe0c9): the same large-text seat-2 tap
  failed despite clamping window-level drags to y=388..514; its trace
  still alternated those drags with `Swipe up CollectionView` at the
  collection center near the tab overlay. The next repair removes the
  element-scoped non-sheet swipe path and requires fresh native proof;
  without a failure-path hierarchy on this run, the exact selected tab
  at failure is **not** asserted as a fact.
- Run 37302205727 (head 6cd7d3e): failure-path hierarchy proved the
  `seat-Round1-2` hunt was actually on **Pairs**, not Tables: the gesture
  began at y=580, only 4 points above the enlarged tab bar (which spans
  y=584..667), and the front list showed the Pairs section with scroll
  value 0%. This was an unintended tab switch, not a missing seat or a
  domain failure. The repair clamps both content-band drags and small
  nudges inside the active list's unobscured interior, 70 points above
  the tab bar. Await a fresh exact-head simulator run before accepting.
- Run 37044039730 (head ef8a6ba): four compact journeys passed, but the
  AX5XL seat-2 hunt failed; the one-shot diagnostic run above resolves
  its cause. The separate regular-width failure is main's phone-only
  device-family regression, addressed independently by PR #24.

- Run 36810913152 (head 132612f): `seat-Round1-2` never became tappable.
  The failing run's xcresult query dumps show the seat hunt DID move the
  real front list (scroll-bar values walked 0% → 34% → 100% → 79%…) and
  the button existed early at ~03:57:09, but the realized row sat outside
  the small CollectionView viewport (chart list frame is only ~298pt tall
  between the AX5XL-enlarged nav bar and tab bar) and the `tap()` hunt
  ended in `nudgeTowardViewport` drags — which were still element-targeted
  `CollectionView` drags. Element-targeted synthesized drags on this
  iOS 26 list are unreliable (run 36465561808 proved the same for
  `waitField`); the window-level content-band coordinate drag reaches the
  real scroll view. `scrollDownOnce`/`scrollUpOnce` now alternate element
  swipes with content-band drives (same proven cadence as `waitField`),
  so nudges actually move the row into the hittable viewport. Simulator
  evidence only; physical-device rows below stay blocked.
  (Independent second failure in the same job —
  `SeatWeaveRegularWidthTests` — is main-repo poison from the device-family
  regression fixed in PR #24, not this branch.)
- Run 36465561808 (head 875230d): `add-guest-field` never realized on
  the Guests tab even after ~20 `Swipe up CollectionView (First Match)`
  attempts. The failing run's xcresult hierarchy dumps proved the cause:
  after the event-creation push the NavigationStack keeps the event-list
  screen's CollectionView MOUNTED behind the workspace (its
  `event-title-field`/`create-event-button` appear in the failure
  snapshot), so `firstMatch` swiped the background 1-page list while the
  front 3-page Guests list reported `Vertical scroll bar ... value: 0%`
  unchanged. The scroll helpers (`scrollDownOnce`, `scrollUpOnce`,
  `nudgeTowardViewport`) now target the front-most content band
  rather than the background event list; their coordinates never begin
  in the enlarged tab bar (see the 37302205727 repair above), so the
  active list moves without switching tabs. Simulator evidence only.

## Evidence matrix (issue #6 deliverable)

| Check | Method | Status | Where recorded |
|---|---|---|---|
| Command/undo/occupancy invariants under randomized mixed operations | Deterministic-seed unit tests | **PASS** (Linux Swift 6.2, real output above) | this file + CI |
| Randomized persistence: saved snapshot == visible state; failed write keeps last good state | Seeded controller tests w/ recording saver | **PASS** (Linux) / full store variant **PENDING native CI** | this file + CI |
| Complete journey incl. relaunch + backup restore byte path | Domain store test (file-backed SwiftData) | **PENDING native CI** (Linux cannot compile SwiftData/SwiftUI) | CI xcresult |
| Journey through the real UI: compact width | XCUITest on pinned iPhone simulator (pre-existing, re-run) | **PENDING native CI** | CI xcresult |
| Journey at regular width | XCUITest on iPad-family simulator (pre-existing) | **PENDING native CI**; phone-only fallback recorded honestly when no iPad runtime exists | CI provenance |
| Journey at large text (AXXXL content size) | XCUITest w/ script-set `simctl ui content_size` | **PENDING native CI** | CI xcresult |
| VoiceOver reading order / rotor gestures | HUMAN operator, physical iPhone | **BLOCKED — not performed; no Mac, no device, no human on this host. Explicit unresolved acceptance.** | this file |
| Keyboard / Switch Control navigation | HUMAN operator, physical iPhone | **BLOCKED — not performed.** | this file |
| Reduced-motion / high-contrast behavior | HUMAN operator, physical iPhone | **BLOCKED — not performed.** | this file |
| No network/analytics/CloudKit entitlements or code paths (static) | `Scripts/entitlement_audit.py --source-only` + CI bundle review | **PASS** (source-level, Linux + CI); Mach-O/plist bundle review runs in native CI | this file + CI artifact |
| Fresh-install offline journey + observed network capture on physical iPhone | Real device + network observation (method would be: fresh install, airplane-mode journey, plus either a router-side capture or proxy — none available here) | **BLOCKED — no physical device or Apple test infrastructure on this host. Static review is NOT capture evidence and is never recorded as if it were.** | this file |
| iPhone Duo / dual-screen behavior | — | **Unverified by design; NOT a release requirement for the standard iOS app.** Migration path stays `SeatingWorkspaceLayout` with public APIs only. | README, PLAN |

## Honest limits and privacy handling

- Every fixture name in this slice is synthetic (Aster/Basil/Cleo/Alice/
  Bob/Carol/generated fuzz names); no real guest names, preferences or
  backups exist anywhere in the repo, exports or artifacts.
- Public export content asserted leak-free by tests; full backup remains
  explicitly private and is only ever produced user-initiated.
- The app adds no networking, no third-party code, no telemetry and no
  entitlements in this slice — the audit confirms zero drift, and CI
  keeps it enforced.
- A simulator run is simulator evidence only; `simctl ui content_size`
  is a scripted setting, not a human accessibility assessment.
- Physical-device, VoiceOver/Switch-Control-human and on-device network
  observation rows above stay OPEN and are carried forward as explicit
  blockers; issue #6's physical-evidence gate is therefore only closed
  as far as "recorded with method and limits" — the manual rows remain
  unresolved acceptance that no CI run can satisfy.
