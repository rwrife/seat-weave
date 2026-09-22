# Issue #4 evidence — adaptive and accessible workspace

Scope: `SeatingWorkspaceLayout` as the sole compact/regular region
adapter, selection/focus continuity across transitions, non-drag
controls, and the CI two-destination test strategy. Physical-device,
VoiceOver-human, Switch-Control-human and iPhone Duo validation remain
explicitly NOT performed — see Pending evidence at the bottom.

## Design (contract-compliant)

- `App/SeatingWorkspaceLayout.swift` introduces `WorkspaceLayoutOverride`
  (`.auto` follows the environment `horizontalSizeClass`; `.compact` /
  `.regular` exist only for deterministic UI testing and a future
  *public* dual-screen API) and `SeatingWorkspaceLayout`, the only place
  a region decision is made. Exactly ONE region renders at a time, so
  the run-35420470196 single-identifier rule (SessionControlBar outside
  any List, one instance) holds in both regions.
- Regular width renders the roster/preferences sidebar
  (`RegularWorkspaceSidebar`, reusing the exact `GuestsSectionContent`
  and `PairPreferencesContent` the compact tabs use) beside the chart
  column (`Tables`/`Plans`/`Share`). Compact parity is unchanged.
- No fold, hinge or dual-screen API is imported or claimed anywhere;
  iPhone Duo remains a future migration target through this adapter.
- Selection continuity: `selectedGuestID`/`selectedVariantID` already
  lived in `AppModel`; issue #4 adds `focusedTableID` (set on seat
  interaction, cleared only on close) to app state per PLAN.md
  ("Resize cannot mutate assignments or reset focus"). Region swaps
  never touch event data.
- All actions remain plain taps on list rows, sections, tabs and
  toolbar menus — nothing requires dragging; accessibility identifiers
  and combined VoiceOver labels (`name, seat`) carry over unchanged.
- Test-only region override (`layout-region-menu`) renders only under
  the `-layoutToggle YES` launch flag; its UserDefaults value is
  cleared at init so it can never leak into user launches.

## Xcode project

- New app source `SeatingWorkspaceLayout.swift` (IDs …10C/…20C) and
  UITests `SeatWeaveWorkspaceTransitionTests.swift` (…10D/…20D),
  `SeatWeaveRegularWidthTests.swift` (…10E/…20E) registered with
  brace/ID verification.
- `TARGETED_DEVICE_FAMILY = "1,2"` on all four target configurations
  (app + UI-test bundle) so a regular-width simulator genuinely receives
  both the app and its UI-test runner (PLAN.md's *optional* tablet
  adaptive view). NOTE: this is the first change that lets the app
  install on iPad-family simulators — the whole regular path depends on
  it; the compact journeys still run on the pinned iPhone destination.

## CI strategy (Scripts/ci.sh, Scripts/select_simulator.py)

- `select_regular_destination()` picks a deterministic available
  iPad-family simulator (exact runtime preferred, numeric runtime
  fallback, same (name, udid)-descending tie-break as the iPhone
  selector). `--family ipad` CLI flag added; 4 new unittests
  (25 helper tests total).
- ui_tests phase now runs compact suites on the pinned iPhone SE 26.0
  destination (same device class proven green for issues #3/#5):
  Launch, SeatingJourney, ShareJourney, plus the new override-driven
  WorkspaceTransitionTests. A second `xcodebuild test` runs
  SeatWeaveRegularWidthTests on the regular destination, proving the
  auto size-class path natively. `destination-regular.txt` records the
  UDID, or `no-available-ipad-simulator` as an explicit gap.

## Verification actually run (Linux host — never an iOS build)

- `python3 -m unittest discover -s Scripts/tests` → 25 tests OK.
- `bash -n Scripts/ci.sh` → syntax OK.
- `swiftc -parse` (Docker `swift:6.0`) on all touched/new Swift sources
  → clean (parse-only; SwiftUI availability needs the macOS SDK).
- `swift test` (Docker `swift:6.0`, Packages/SeatingDomain) → 53 tests
  passed (domain unchanged by this issue; regression gate).

## CI repairs

- Run 35695764761 (head a44932a, iPhone SE 26.0 + iPad mini A17 Pro
  26.0): every phase through `ui_tests` passed (helpers 25, domain 53,
  app build, full compact suite incl. the new override-driven
  WorkspaceTransitionTests). `ui_tests_regular` failed at
  `tabBars.buttons["Tables"]` (exit 65): the iOS 26 iPad TabView does
  not expose its chart-column items under a tabBars-trait container.
  Repair 8b13ae6: `chartTab()` probes `tabBars.buttons` first and falls
  back to whole-app `buttons` — the same identifier resolves either way;
  no production-code change.

## Native verification (green, this issue's merge gate)

- Run 35697569604 at head 9d2fd93: provenance artifact verified
  (expected_sha == actual_sha, phase=complete, exit_status=0) on
  Xcode 26.0.1 (17A400), iOS SDK 26.0, macOS ARM64. Compact suite on
  iPhone SE (3rd gen, iOS 26.0): 4 tests, 0 failures (Launch,
  SeatingJourney, ShareJourney, WorkspaceTransition — the override
  region flips, mid-assignment rotation, and focus-continuity gates).
  Regular suite on iPad mini (A17 Pro, iOS 26.0): 1 test, 0 failures
  (auto size-class path, sidebar+chart coexistence, rotation
  continuity). Simulator evidence only.

## Pending evidence (explicit, not performed)

- Human VoiceOver sequence review, Dynamic Type sizes AX1–AX5, contrast
  audit, 44-point hit-target audit, Switch Control and Full Keyboard
  Access sessions: the UI is tap-first and system-standard, but no
  human assistive-technology pass has been performed. 44pt: List rows,
  tabs and toolbar buttons are system-sized, not custom-verified.
- Reduce Motion: no custom animation was added; the system settings are
  honored by default, but not manually observed.
- Physical-device behavior and iPhone Duo: pending until public
  dual-screen SDK/hardware exists; no compatibility claim is made.
