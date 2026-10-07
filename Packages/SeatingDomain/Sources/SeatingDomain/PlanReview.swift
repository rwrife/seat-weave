import Foundation

/// Host-only review. This structure is never passed to the public export builder.
public struct ConflictAcknowledgement: Hashable, Sendable {
    public let eventID: UUID
    public let variantID: UUID
    public let preference: PairPreference
    public let firstSeat: SeatAssignment?
    public let secondSeat: SeatAssignment?
    public let contradictsAnotherPreference: Bool

    public init(event: SeatingEvent, variant: PlanVariant, preference: PairPreference,
                evaluation: RuleEvaluation) {
        eventID = event.id
        variantID = variant.id
        self.preference = preference
        firstSeat = variant.seat(for: preference.firstGuestID)
        secondSeat = variant.seat(for: preference.secondGuestID)
        contradictsAnotherPreference = evaluation.contradictsAnotherPreference
    }
}

public struct PlanReview: Sendable {
    public struct EmptySeat: Hashable, Sendable {
        public let tableID: UUID
        public let tableLabel: String
        public let number: Int
    }
    public let unseated: [GuestIdentity]
    public let emptySeats: [EmptySeat]
    public let conflicts: [RuleEvaluation]
    public let unresolved: [RuleEvaluation]
    public let acknowledgementKeys: [UUID: ConflictAcknowledgement]
    public let acknowledgedPreferenceIDs: Set<UUID>

    public var unacknowledgedConflicts: Int {
        conflicts.filter { !acknowledgedPreferenceIDs.contains($0.preferenceID) }.count
    }

    public static func make(event: SeatingEvent, variant: PlanVariant,
                            acknowledged: Set<ConflictAcknowledgement> = []) -> PlanReview {
        let evaluations = RuleEngine.evaluate(event: event, variant: variant)
        let conflicts = evaluations.filter { $0.status == .conflict }
        let keys = Dictionary(uniqueKeysWithValues: conflicts.compactMap { evaluation -> (UUID, ConflictAcknowledgement)? in
            guard let preference = event.preferences.first(where: { $0.id == evaluation.preferenceID }) else { return nil }
            return (preference.id, ConflictAcknowledgement(event: event, variant: variant,
                                                            preference: preference, evaluation: evaluation))
        })
        return PlanReview(
            unseated: event.guests.filter { variant.seat(for: $0.id) == nil },
            emptySeats: variant.tables.flatMap { table in
                (1...table.seatCount).compactMap { number in
                    variant.occupant(tableID: table.id, seatNumber: number) == nil
                        ? EmptySeat(tableID: table.id, tableLabel: table.label, number: number) : nil
                }
            },
            conflicts: conflicts,
            unresolved: evaluations.filter { $0.status == .unresolved },
            acknowledgementKeys: keys,
            acknowledgedPreferenceIDs: Set(keys.compactMap { acknowledged.contains($0.value) ? $0.key : nil })
        )
    }

    /// Only currently conflicting, identical preference/seat states can retain acknowledgement.
    public static func validAcknowledgements(event: SeatingEvent,
                                              acknowledged: Set<ConflictAcknowledgement>) -> Set<ConflictAcknowledgement> {
        Set(event.variants.flatMap { variant in
            make(event: event, variant: variant).acknowledgementKeys.values
        }).intersection(acknowledged)
    }
}
