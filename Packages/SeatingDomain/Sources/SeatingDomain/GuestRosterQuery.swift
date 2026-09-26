import Foundation

/// Read-only roster queries for guest editing (issue #17): name search,
/// seating filters and duplicate-display-name detection.
///
/// These are pure views over the model — they never mutate anything and
/// hold no state, so filters can be re-applied after any command while
/// selection (a guest UUID) is preserved by the caller independently.
/// Matching is identity-based: `matches` compares UUIDs, so renaming or
/// re-seating a guest can never silently move a selection to someone
/// else.
public enum GuestRosterQuery {
    /// Canonical folded form used for duplicate detection and
    /// duplicate-warning comparisons: trimmed, case-, width- and
    /// diacritic-insensitive. One place so the add row, the rename sheet
    /// and the roster banner can never disagree about what "the same
    /// name" means.
    public static func foldedDisplayName(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "und"))
    }

    /// Folded display names of every guest in the event. The add/rename
    /// rows warn when a typed name lands in this set (the command is
    /// about to create a visible duplicate), never when it does not.
    public static func foldedNameSet(in event: SeatingEvent) -> Set<String> {
        Set(event.guests.map { foldedDisplayName($0.displayName) })
    }
    /// Roster filter relative to the selected plan variant. `all` keeps
    /// the host's roster; `seated`/`unseated` partition by whether the
    /// guest occupies a seat in the given variant.
    public enum Filter: String, CaseIterable, Codable, Sendable {
        case all
        case seated
        case unseated

        /// Stable VoiceOver-friendly label for UI chips.
        public var label: String {
            switch self {
            case .all: return "All"
            case .seated: return "Seated"
            case .unseated: return "Unseated"
            }
        }
    }

    /// True when the display name contains the search text, compared
    /// case- and width-insensitively and diacritic-insensitively so
    /// "aster" finds "Aster" and "José" finds "JOSE". Empty or
    /// whitespace-only search text matches every guest; search text is
    /// trimmed before matching.
    public static func name(_ guest: GuestIdentity, matchesSearch text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = guest.displayName
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "und"))
        let foldedNeedle = needle
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "und"))
        return haystack.contains(foldedNeedle)
    }

    /// True when the guest occupies a seat in `variant`.
    public static func isSeated(_ guest: GuestIdentity, in variant: PlanVariant) -> Bool {
        variant.seat(for: guest.id) != nil
    }

    /// Applies the seating filter to one guest (search is applied by
    /// callers through `name(_:matchesSearch:)` so both predicates stay
    /// independently testable).
    public static func passes(_ guest: GuestIdentity, filter: Filter, in variant: PlanVariant) -> Bool {
        switch filter {
        case .all:
            return true
        case .seated:
            return isSeated(guest, in: variant)
        case .unseated:
            return !isSeated(guest, in: variant)
        }
    }

    /// The roster as visible under a search string and seating filter,
    /// preserving roster order.
    public static func visibleGuests(
        in event: SeatingEvent,
        variant: PlanVariant,
        search: String,
        filter: Filter
    ) -> [GuestIdentity] {
        event.guests.filter { guest in
            name(guest, matchesSearch: search) && passes(guest, filter: filter, in: variant)
        }
    }

    /// Guest IDs whose display name (after trimming) occurs more than
    /// once in the event, keyed by folded display name so "Amy " and
    /// "amy" count as the same visible label while the guests remain
    /// distinct identities. Hosts may keep intentional duplicates; this
    /// exists to *warn* and to *disambiguate*, never to block.
    public static func duplicateDisplayNameIDs(in event: SeatingEvent) -> [String: [UUID]] {
        var foldedOrder: [String] = []
        var buckets: [String: [UUID]] = [:]
        for guest in event.guests {
            let folded = guest.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                         locale: Locale(identifier: "und"))
            if buckets[folded] == nil { foldedOrder.append(folded) }
            buckets[folded, default: []].append(guest.id)
        }
        var duplicates: [String: [UUID]] = [:]
        for key in foldedOrder where (buckets[key]?.count ?? 0) > 1 {
            duplicates[key] = buckets[key]
        }
        return duplicates
    }

    /// True when ANY roster name is a duplicate — UI shows the banner
    /// from this without recomputing per row.
    public static func hasDuplicateDisplayNames(in event: SeatingEvent) -> Bool {
        !duplicateDisplayNameIDs(in: event).isEmpty
    }

    /// True when `guestID` shares its display name with another guest.
    public static func isDuplicate(_ guestID: UUID, in event: SeatingEvent) -> Bool {
        duplicateDisplayNameIDs(in: event).values.contains { $0.contains(guestID) }
    }
}
