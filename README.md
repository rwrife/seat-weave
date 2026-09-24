# Seat Weave

Local-first iPhone seating planner for small gatherings: arrange guests beside a live table chart, catch seating-preference conflicts, and share a clean plan without accounts.

## Why and for whom

Hosts of dinner parties, family celebrations and small hobby meetups often juggle a guest list and a sketch while moving people between tables. Seat Weave keeps both views connected, explains conflicting preferences, and preserves alternatives without turning a small gathering into wedding-management software.

**Status: native app with the complete compact-phone seating workflow, private backup and previewed public export, the adaptive `SeatingWorkspaceLayout` regular-width workspace, and guest editing with rename, search, seated/unseated filters and duplicate-name warnings.** [Bootstrap evidence](docs/bootstrap-evidence.md) records the exact tested commit, toolchain, simulator and results. [Domain evidence](docs/domain-evidence.md) records the issue #2 model, commands, three-state rules and persistence verification. [Workflow evidence](docs/workflow-evidence.md) records the issue #3 compact seating UI, its simulator journey and the honest host limits. [Backup and export evidence](docs/backup-export-evidence.md) records the issue #5 public-export privacy contract, versioned backup/restore validation and confirmed deletion. [Adaptive workspace evidence](docs/adaptive-workspace-evidence.md) records the issue #4 region adapter, selection-continuity tests, the two-destination CI strategy and the accessibility checks still pending human validation. [Guest editing evidence](docs/guest-editing-evidence.md) records the issue #17 rename identity rules, folded search/filters and duplicate-name handling. The repository contains a native SwiftUI app, the linked pure Swift domain module with tests, a SwiftData event store and launch, seating-journey, guest-editing-journey, share-journey and workspace-transition simulator coverage. Integrated reliability evidence remains a later milestone. Simulator success is not physical-device, signing, TestFlight or App Store evidence.

## Intended end-to-end workflow

1. Create an event; enter up to 40 guests using names or aliases (no address book access).
2. Add up to six numbered circular tables, each with 2–12 ordered seats.
3. Optionally mark guest pairs as **same table**, **different tables**, or **next to each other**. These are host-entered preferences, not inferred social relationships.
4. Select an unseated guest, then a seat. Move or explicitly swap occupants; undo mistakes. A list alternative is always available instead of dragging.
5. Read specific unresolved/conflicting preferences. Unseated guests are **unresolved**, never silently satisfied. Hosts can keep a conflict; the app is an aid, not an authority.
6. Duplicate the plan to compare arrangements without changing the guest roster. Resume the chosen plan after closing the app or changing layout.
7. Export a guest-facing seating PDF/text list with no private preferences; separately export a full versioned JSON backup when wanted.

Use cases: balance two dinner tables; seat a pair together at a club supper; compare a family-party alternative before printing the final table list.

## MVP and limits

- Offline events, guests, circular tables, explicit seats and independent plan variants.
- Manual assignment, confirmed swaps, undo and explainable pair-preference warnings.
- Compact iPhone workflow plus optional regular-width/tablet guest-list + chart view.
- Accessible list-based editing, previewed public seating export, full backup/restore and deletion.
- No accounts, collaboration/cloud sync, auto-seating optimizer, invitations/RSVPs, contact import, payments, venue maps, rectangular-table geometry, food/allergy or health records, AI, Android or external display support in MVP.
- Diagrams are ordinal seating plans, **not** scaled floor plans, capacity approval, accessibility certification, evacuation layouts or safety advice.

## iOS and dual-screen design target

**iOS is the required primary platform; builds require the iOS 26 SDK or newer.** Planned implementation is native SwiftUI with SwiftData and a pure Swift domain module. Initial exact toolchain pin: **Xcode 26.0.1 (17A400), iOS SDK 26.0**, Swift 6 language mode, deployment target iOS 26.0; see [toolchain.json](toolchain.json). Upgrading the pin requires a reviewed change that never lowers the SDK below 26.

Today the build shape is a **standard mobile app with an optional tablet/adaptive size-class view**. Compact widths navigate between guests and seats; regular widths keep the unseated roster/preferences beside the interactive table chart. A persistent selected guest, plan ID and focus anchor prevent losing context on width/orientation changes.

The requested **iPhone Duo dual-screen experience is a design target**, not a claim of tested device support. Future SDK migration goes through one `SeatingWorkspaceLayout` adapter accepting available content regions: guest controls on one region, table chart on the other. Native safe-region/hinge behavior will require documented public APIs and real-device tests before any compatibility claim. No private, unavailable fold APIs or assumed hardware dimensions are dependencies.

## Data ownership, privacy and permissions

- App-private local storage: Event, Guest, PairPreference, PlanVariant, Table, SeatAssignment. Preferences belong to the event; variants snapshot table/assignment structure. Stable UUIDs preserve identity even for identical display names.
- No app networking, analytics, ads or CloudKit. No notification, microphone, camera, location, sensor or Contacts permissions are needed. Files/share sheets are user-initiated and can use user-selected cloud-backed destinations outside the app.
- Names and pair preferences can be sensitive. Prefer aliases; do not solicit reasons for preferences. Public PDF/text exports include only event title, table/seat labels and chosen guest display names. They exclude pair rules, unseated roster, internal IDs and other variants. Preview before sharing.
- Full versioned JSON backups include private preferences and must show an explicit privacy warning. Restore validates size/version/IDs/references, previews contents and imports as a new event atomically; it never silently merges or overwrites an existing event. No arbitrary file paths or attachments are accepted.
- Whole-event deletion removes all variants and preferences; delete-all is confirmed. Exports already shared and OS-managed device backups cannot be recalled by the app. Storage is not advertised as independently encrypted; device protection and system backup settings still apply.

## Accessibility

VoiceOver labels identify guest, table, seat, assignment and warnings; reading order is logical in both layouts. Support Dynamic Type through accessibility sizes, reduced motion, high contrast, keyboard/Switch Control workflows and 44-point minimum actions. No operation may depend on drag gestures, color, spatial vision or the second pane. List assignment and explicit swap confirmation are first-class UI.

## Development quickstart

Clone the repository, then run the host-independent helper tests on macOS or Linux:

```sh
gh repo clone rwrife/seat-weave
cd seat-weave
python3 -m unittest discover -s Scripts/tests -v
```

On a Mac with an available iPhone simulator and an installed Xcode matching all pins by actual command output, run the complete unsigned check at the commit to be tested:

```sh
Scripts/ci.sh "$(git rev-parse HEAD)"
```

That command runs helper tests, `swift test` for `Packages/SeatingDomain`, a simulator build, and the `SeatWeaveUITests` launch smoke. It writes the explicit simulator destination, SHA, actual toolchain versions, logs and `.xcresult` bundles to a unique run directory beneath `build/ci-artifacts/`. The shared `SeatWeave` scheme can also be opened directly in Xcode.

CI checks out the pull request head SHA explicitly rather than a synthetic merge commit and follows the same script on macOS. It enumerates installed `Xcode*.app` bundles and selects one only when `xcodebuild -version` reports Xcode 26.0.1 build 17A400 and `xcrun` reports iOS SDK 26.0. A matching application filename alone is insufficient. Linux cannot run Swift/Xcode/iOS simulator validation; a missing pinned Xcode or simulator is an environment blocker, never permission to change a pin or invent a green result.

The bootstrap app has no external dependencies, entitlements, permissions, CloudKit, analytics or networking. CI does not read signing or App Store secrets, and signing is disabled. Release automation belongs to milestone #7 and is not present.

## Signing and distribution

Bundle identifier: **`com.infinityball.seatweave`**.
App Store Connect registration on 2026-09-15 returned:

```text
CREATED com.infinityball.seatweave
```

Repository Actions secrets were configured and listed by name: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`. Only their names belong in source or logs. `ASC_TEAM_ID` identifies the signing/provisioning team.

The release milestone must provision the App Store app record, distribution certificate/profile or validated automatic-signing path, ephemeral CI keychain, signed archive, export and API-authenticated TestFlight upload. Secrets and bundle registration alone do not create a distributable app. Preserve build/SDK/commit provenance, verify processing in App Store Connect, prepare privacy disclosure and real screenshots, then submit for App Store review via an explicit release approval gate. No store availability is claimed.

## License

MIT; see [LICENSE](LICENSE).
