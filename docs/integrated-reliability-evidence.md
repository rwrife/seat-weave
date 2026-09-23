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
   project and in `Scripts/ci.sh` compact-destination runs. The test
   sets the destination content size to `accessibility-extra-extra-large`
   via `xcrun simctl ui booted content_size` (scripted equivalent of
   Settings ▸ Accessibility ▸ Display & Text ▸ Larger Text; the test
   tries the documented and legacy token spellings in order), then walks
   create → guests → table → assign → swap → undo → **resize (via the
   sheet stepper, first automated coverage of this control)** →
   duplicate → relaunch → public export preview, locating controls by
   scrolling. If the simulator rejects every size spelling the failure
   is asserted, not swallowed. The content size is restored in teardown.
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
