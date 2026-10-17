import Foundation

/// Host-only comparison. Names are presentation only; guest identity is UUID.
/// Table identity is UUID-first: duplicated plans deliberately receive fresh
/// table UUIDs, so an equal printed label there is NOT table identity.
public struct PlanComparison: Sendable {
    public enum SeatChange: Sendable { case newlySeated, newlyUnseated, moved }
    public struct GuestChange: Sendable {
        public let guest: GuestIdentity
        public let before: SeatAssignment?
        public let after: SeatAssignment?
        public let beforeTableLabel: String?
        public let afterTableLabel: String?
        public let samePrintedPosition: Bool
        public let kind: SeatChange
    }
    public struct PreferenceChange: Sendable {
        public let preference: PairPreference
        public let before: RuleStatus
        public let after: RuleStatus
    }
    /// A table present in one plan but not the other, judged by UUID.
    public struct TablePresence: Sendable {
        public let table: SeatingTable
        public let onlyInTarget: Bool
    }
    public let guests: [GuestChange]
    public let preferences: [PreferenceChange]
    public let tables: [TablePresence]
    /// True when the two plans share no table UUID (for example a freshly
    /// duplicated plan): every positional statement is then printed-label
    /// based and this flag tells the host so.
    public let tablesAreIndependentlyIdentified: Bool

    public static func make(event: SeatingEvent, from source: PlanVariant, to target: PlanVariant) -> PlanComparison {
        let sharedTableIDs = Set(source.tables.map(\.id)).intersection(Set(target.tables.map(\.id)))
        func position(_ assignment: SeatAssignment?, in variant: PlanVariant) -> (label: String?, seat: Int?)? {
            guard let assignment else { return nil }
            return (variant.table(assignment.tableID)?.label, assignment.seatNumber)
        }
        let guests = event.guests.compactMap { guest -> GuestChange? in
            let before = source.seat(for: guest.id)
            let after = target.seat(for: guest.id)
            guard before != after else { return nil }
            let beforePosition = position(before, in: source)
            let afterPosition = position(after, in: target)
            let kind: SeatChange = before == nil ? .newlySeated : after == nil ? .newlyUnseated : .moved
            let samePrinted = before != nil && after != nil
                && beforePosition?.label == afterPosition?.label
                && beforePosition?.seat == afterPosition?.seat
            return GuestChange(
                guest: guest,
                before: before,
                after: after,
                beforeTableLabel: beforePosition?.label,
                afterTableLabel: afterPosition?.label,
                samePrintedPosition: samePrinted,
                kind: kind
            )
        }
        let sourceRules = Dictionary(uniqueKeysWithValues: RuleEngine.evaluate(event: event, variant: source).map { ($0.preferenceID, $0.status) })
        let targetRules = Dictionary(uniqueKeysWithValues: RuleEngine.evaluate(event: event, variant: target).map { ($0.preferenceID, $0.status) })
        let preferences = event.preferences.compactMap { preference -> PreferenceChange? in
            guard let before = sourceRules[preference.id], let after = targetRules[preference.id], before != after else { return nil }
            return PreferenceChange(preference: preference, before: before, after: after)
        }
        let sourceIDs = Set(source.tables.map(\.id))
        let targetIDs = Set(target.tables.map(\.id))
        let tables = source.tables.filter { !targetIDs.contains($0.id) }.map { TablePresence(table: $0, onlyInTarget: false) }
            + target.tables.filter { !sourceIDs.contains($0.id) }.map { TablePresence(table: $0, onlyInTarget: true) }
        return PlanComparison(
            guests: guests,
            preferences: preferences,
            tables: tables,
            tablesAreIndependentlyIdentified: sharedTableIDs.isEmpty && !(source.tables.isEmpty && target.tables.isEmpty)
        )
    }
}
