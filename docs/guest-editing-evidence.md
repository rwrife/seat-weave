# Guest editing evidence (issue #17)

Rename, search, filters and duplicate-name warnings for the guest roster.
Synthetic fixtures only; no real names or preferences appear here.

## What ships

- `SeatingCommands.renameGuest(id:newName:)` — trims whitespace, rejects
  empty/unknown targets, is undoable, and by construction touches only
  `GuestIdentity.displayName`: the guest UUID keeps assignments in every
  variant and every pair preference attached (domain tests prove
  rename-under-two-variants and rename-then-rule-evaluation).
- `GuestRosterQuery` — pure roster queries: folded search (case-,
  width- and diacritic-insensitive, whitespace-trimmed needle),
  All/Seated/Unseated filters relative to the selected variant, and
  folded duplicate-name buckets (`"Amy "`, `"amy"`, `"Ａmy"` fold equal
  while remaining distinct identities).
- Guests UI: in-list search field + Clear, filter chips, roster count
  header, a roster-wide duplicate banner, per-row "shares this name"
  mark (text, not color-only), add/rename duplicate warnings that
  inform but never block, rename sheet showing the current name, and
  selection that survives filter/search/tab changes with an explicit
  "hidden by filter" explanation plus a reveal action.
- Roster row identifiers are now per-guest UUIDs, so identical display
  names never share a control identifier; journeys locate rows by the
  leading name in the combined accessibility label.

## Verification actually performed

| Check | Where | Result |
| --- | --- | --- |
| Domain `swift test` (rename identity, undo, cross-variant, preferences, validation, duplicates, folded search, filters) | Linux Swift 6.2 container, `Packages/SeatingDomain` | 64 tests in 11 suites passed (2026-09-24) |
| `bash -n Scripts/ci.sh`, pbxproj brace balance + all referenced object IDs defined | Linux host | clean |
| New compact journey `SeatWeaveGuestEditingJourneyTests` registered in the Xcode project and `Scripts/ci.sh` | pinned macOS CI | see CI run linked on the PR |

The pinned macOS CI (Xcode 26.0.1/17A400, iOS SDK 26.0, actual versions
verified by the CI script) is the merge gate for the App-target SwiftUI
code and the simulator journey; Linux cannot build iOS, so nothing here
claims otherwise. Simulator evidence is not physical-device evidence.

## Explicit limits

- VoiceOver audio-order at accessibility sizes for the new filter/search
  chrome remains human verification on issue #6's evidence matrix — the
  rows carry labels and text-based marks, but no human VoiceOver pass is
  claimed.
- Regular-width (iPad) run of the new journey follows the existing
  two-destination policy: exercised only when an iPad runtime exists on
  the runner; the compact journey gates the merge.
