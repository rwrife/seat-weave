# Seat Weave implementation plan

## Scope and architectural decisions

A single-device, offline seating workspace for small gatherings. Exactly three pair-rule kinds: same table, different tables and adjacent seats. Manual editing and explanation are the core product, not algorithmic optimization. Bound the initial data set to 40 guests/event, six tables/variant, 2–12 seats/table and ten variants/event. Empty and partially assigned plans are valid drafts, never presented as complete.

Native SwiftUI avoids cross-platform/plugin overhead and gives iOS accessibility and adaptive layout directly. SwiftData provides local persistence without CloudKit; a pure Swift domain module contains validation, adjacency and command/undo behavior. Foundation Codable implements portable versioned JSON. Native PDF drawing/share sheets publish seating output; a UTF-8 text alternative avoids requiring visual charts. No remote service or AI inference.

The required primary platform is iOS 26.0+. Build/CI baseline is pinned in toolchain.json to Xcode 26.0.1 (17A400), iOS 26.0 SDK, Swift 6 language mode. CI must inspect actual versions, not infer them from an application directory name. A future reviewed update can select a newer SDK, never one below 26.

### Current bootstrap source tree

- `SeatWeave.xcodeproj` and shared `SeatWeave` scheme: committed native project linking the local package, with iOS 26.0/Swift 6 and signing disabled for bootstrap CI.
- `App/`: native SwiftUI entry point and an honest bootstrap home; no event or seating flow is claimed.
- `Packages/SeatingDomain/`: dependency-free pure Swift domain module — event/guest/table/variant model with published bounds, atomic assign/move/swap/unseat/resize/undo commands, three-state explainable rule evaluation, deterministic randomized occupancy invariants, Codable event documents and a SwiftData file store (Apple platforms). The seating UI, exports and backup flows remain later milestones.
- `UITests/`: simulator launch smoke for the bootstrap home. Persistence, export and complete workflow journeys remain later milestones.
- `Scripts/`: exact toolchain/simulator selection, helper unit tests and a repeatable CI entry point.
- `.github/workflows/ci.yml`: exact pull-request-head checkout, pinned macOS toolchain validation, unsigned simulator build/test and always-uploaded result provenance.
- Release workflow is intentionally absent until milestone #7; bootstrap PR CI uses no secrets.

### Domain invariants

- Event owns UUID-based guests and symmetric pair preferences; display names are not identity keys. Duplicate names are permitted and disambiguated in editing.
- Table UUID, display label and circular seat order are variant-local. Seats are numbered 1 through N. Adjacency is `(abs(a-b) == 1) || (abs(a-b) == N-1)` only for the same table; seats 1 and N are adjacent. Two-seat tables have one unique neighbor per seat.
- Each guest occupies at most one seat in each variant; a seat has at most one guest. Reject cross-event guest references and unknown table/seat IDs. Capacity reduction requires a preview and explicit unseating of affected guests; never drop data silently.
- Rules return satisfied/conflict/unresolved plus guest IDs and a plain-language reason. Either guest unseated means unresolved for every rule. Contradictory pair rules remain visible, not auto-deleted or claimed solvable. No solver or feasibility guarantee.
- Assign/move/swap/unseat/resize commands validate atomically and support undo while editing. Persist the command result before indicating success. Undo is session-local; completed assignments survive restart. UI labels must explain this boundary.
- Duplicate variant remaps table IDs and assignments; later assignment/table edits are independent. Event guest/rule changes are shared and trigger recomputation; deleting a guest previews effects on every variant.
- Workspace selection belongs to app state (event/variant/guest IDs, table focus), not view lifetime. `SeatingWorkspaceLayout` is the sole adapter for compact vs regular content regions and future public native dual-screen APIs. Resize cannot mutate assignments or reset focus.

## Milestones and issue dependency order

1. [#1 Native skeleton and pinned iOS CI](https://github.com/rwrife/seat-weave/issues/1): actual Xcode project, shared scheme, domain package, launch test and reproducible macOS checks. No stub-only closure.
2. [#2 Local model and rule engine](https://github.com/rwrife/seat-weave/issues/2), after #1: persisted events/variants and tested command invariants, adjacency and rule explanations.
3. [#3 Complete compact seating workflow](https://github.com/rwrife/seat-weave/issues/3), after #2: create event/roster/tables, seat/swap/undo, conflict review and variant comparison.
4. [#4 Adaptive and accessible workspace](https://github.com/rwrife/seat-weave/issues/4), after #3: optional tablet split view, compact parity, width-change continuity, non-drag controls and accessibility evidence.
5. [#5 Private backup and safe public export](https://github.com/rwrife/seat-weave/issues/5), after #3: versioned JSON backup/new-event restore, PDF/text export with preview, privacy controls and deletion.
6. [#6 Integrated reliability and privacy evidence](https://github.com/rwrife/seat-weave/issues/6), after #4 and #5: restart/undo/restore/error-path journeys, accessibility matrix and honest on-device/network evidence gates.
7. [#7 Signed TestFlight candidate and release handoff](https://github.com/rwrife/seat-weave/issues/7), after #6: signed build, processed TestFlight upload, distribution/backup documentation and App Store submission gate.

## Testing and acceptance evidence

- Unit tests: no double-seating, occupied-seat refusal, atomic confirmed swaps, failed commands unchanged, reversible undo, resize unseating preview, cross-event references, duplicate names, variant independence and guest deletion across variants.
- Table-driven rule tests: first/last adjacency, 2-seat wraparound, different tables, same seat rejection, unseated pairs and contradictory preferences. Randomized small command sequences check occupancy invariants after every step.
- Persistence: temporary stores, app relaunch, schema migration fixture, disk-write errors with no false success. Test data is synthetic; do not commit real guest lists or backups.
- Export/restore: public output excludes private rules even with hostile-looking names; text escaping, PDF pagination and long Unicode names; deterministic schema round trip; duplicate/dangling IDs, oversized (>2 MiB) input, unsupported versions, invalid seat counts and interrupted restore leave existing events unchanged. Preserve alias/name exactly; never execute imported text or treat it as a path.
- UI journeys: create → seat → swap → undo → duplicate → resize → relaunch → export → restore. Cover compact phone and regular-width tablet, accessibility text sizes, VoiceOver order, keyboard/Switch Control and reduced motion. Record manual checks as pending until actually performed.
- Offline/network: no networking/analytics/cloud entitlements in static review; fresh-install offline journey and observed network behavior on a real device before privacy/release claims. Static review is not network capture evidence.
- Keep CI logs, exact HEAD, Xcode/build/SDK versions, simulator destination and xcresult artifacts. CI simulator output is not physical-device testing; neither is Linux doc verification. Physical dual-screen support remains unverified until hardware/public SDK tests exist.

## Backup and sharing contract

Public export is a selected-variant seating plan, not a database dump: title, table/seat labels and seated guest display names only. Warn if unseated guests or conflicts remain before proceeding; never inject private warning details into the shared document. Full backup is separately named and explicitly includes private preferences. Restore into a newly identified event after validating complete input and showing a summary; reject malformed or unsupported files before persistence. Confirm delete-event/delete-all and explain that copies outside the app and OS backups remain outside app control.

## Distribution

Required iOS release path: protected release workflow on trusted main/tag with manual environment approval; API auth using repository `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` secrets (names only). Use `com.infinityball.seatweave`, already registered. Provision App Store app record and signing certificate/profile separately, or prove automatic signing works; use an ephemeral keychain and remove temporary keys even on failure. Never print credentials or place them in build artifacts. Signed archive/export must record the correct team/bundle/version, then upload and verify TestFlight processing, not merely uploader exit 0. Finish review-ready privacy metadata, export compliance answers and actual device screenshots; App Store submission requires explicit approval.

## Risks and non-goals

- Social preferences are private and may conflict: no inferred relationships, sensitive reasons or hidden optimizer decisions.
- A table chart can mislead about physical space: ordinal circular seats only, no geometry, fire/accessibility compliance or venue capacity claims.
- SDK/toolchain availability and Apple provisioning require real Mac/Apple evidence; unavailable infrastructure is a blocker, not grounds to downgrade the pin or close gated issues.
- iPhone Duo is the requested future design target. Standard iOS and optional tablet layouts deliver useful value now; never invent fold APIs, hinge measurements or device compatibility.
- Scope excludes cloud accounts/sync, Android, invitations, RSVP, contacts, food/medical data, payments, AI and auto-seating. Do not grow this into a wedding planner.
