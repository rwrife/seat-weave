import Foundation

/// Three-state rule evaluation. Unseated pairs are never silently satisfied.
public enum RuleStatus: String, Codable, Sendable {
    case satisfied
    case conflict
    case unresolved
}

/// The outcome of evaluating one preference against one variant.
public struct RuleEvaluation: Hashable, Sendable {
    public let preferenceID: UUID
    public let status: RuleStatus
    /// Guest IDs the explanation refers to, in stable order.
    public let guestIDs: [UUID]
    /// Plain-language reason written for the host.
    public let reason: String
    /// True when another preference on the same guest pair demands the
    /// opposite outcome. Contradictions remain visible, never auto-deleted.
    public let contradictsAnotherPreference: Bool

    public init(
        preferenceID: UUID,
        status: RuleStatus,
        guestIDs: [UUID],
        reason: String,
        contradictsAnotherPreference: Bool
    ) {
        self.preferenceID = preferenceID
        self.status = status
        self.guestIDs = guestIDs
        self.reason = reason
        self.contradictsAnotherPreference = contradictsAnotherPreference
    }
}

/// Pure evaluation of event preferences inside one variant.
public enum RuleEngine {
    /// Evaluate every preference of `event` against `variant`. The variant
    /// must belong to the event; callers pass the matching pair.
    public static func evaluate(event: SeatingEvent, variant: PlanVariant) -> [RuleEvaluation] {
        let contradictions = contradictoryPreferenceIDs(preferences: event.preferences)
        return event.preferences.map { preference in
            evaluate(
                preference,
                event: event,
                variant: variant,
                contradictsAnotherPreference: contradictions.contains(preference.id)
            )
        }
    }

    /// Guest-pair keys carrying more than one preference kind.
    public static func contradictoryGuestPairKeys(preferences: [PairPreference]) -> Set<PairGuestKey> {
        var kindsByPair: [PairGuestKey: Set<PairPreferenceKind>] = [:]
        for preference in preferences {
            kindsByPair[preference.guestPairKey, default: []].insert(preference.kind)
        }
        return Set(kindsByPair.compactMap { $0.value.count > 1 ? $0.key : nil })
    }

    private static func contradictoryPreferenceIDs(preferences: [PairPreference]) -> Set<UUID> {
        let contradictoryKeys = contradictoryGuestPairKeys(preferences: preferences)
        return Set(preferences.filter { contradictoryKeys.contains($0.guestPairKey) }.map(\.id))
    }

    private static func evaluate(
        _ preference: PairPreference,
        event: SeatingEvent,
        variant: PlanVariant,
        contradictsAnotherPreference: Bool
    ) -> RuleEvaluation {
        let first = preference.firstGuestID
        let second = preference.secondGuestID
        let guestIDs = [first, second]
        let names = displayNamePair(event: event, first: first, second: second)

        guard let firstSeat = variant.seat(for: first),
              let secondSeat = variant.seat(for: second) else {
            let subject: String
            if variant.seat(for: first) == nil, variant.seat(for: second) == nil {
                subject = "Both guests are"
            } else if variant.seat(for: first) == nil {
                subject = "\(names.first) is"
            } else {
                subject = "\(names.second) is"
            }
            return RuleEvaluation(
                preferenceID: preference.id,
                status: .unresolved,
                guestIDs: guestIDs,
                reason: "\(subject) not seated yet, so this preference is unresolved.",
                contradictsAnotherPreference: contradictsAnotherPreference
            )
        }

        let sameTable = firstSeat.tableID == secondSeat.tableID
        switch preference.kind {
        case .sameTable:
            if sameTable {
                return RuleEvaluation(
                    preferenceID: preference.id,
                    status: .satisfied,
                    guestIDs: guestIDs,
                    reason: "\(names.first) and \(names.second) sit at the same table.",
                    contradictsAnotherPreference: contradictsAnotherPreference
                )
            }
            return RuleEvaluation(
                preferenceID: preference.id,
                status: .conflict,
                guestIDs: guestIDs,
                reason: "\(names.first) and \(names.second) prefer the same table but sit at different tables.",
                contradictsAnotherPreference: contradictsAnotherPreference
            )
        case .differentTables:
            if !sameTable {
                return RuleEvaluation(
                    preferenceID: preference.id,
                    status: .satisfied,
                    guestIDs: guestIDs,
                    reason: "\(names.first) and \(names.second) sit at different tables.",
                    contradictsAnotherPreference: contradictsAnotherPreference
                )
            }
            return RuleEvaluation(
                preferenceID: preference.id,
                status: .conflict,
                guestIDs: guestIDs,
                reason: "\(names.first) and \(names.second) prefer different tables but share one table.",
                contradictsAnotherPreference: contradictsAnotherPreference
            )
        case .adjacent:
            guard sameTable,
                  let table = variant.table(firstSeat.tableID),
                  areSeatsAdjacent(firstSeat.seatNumber, secondSeat.seatNumber, seatCount: table.seatCount) else {
                if sameTable {
                    return RuleEvaluation(
                        preferenceID: preference.id,
                        status: .conflict,
                        guestIDs: guestIDs,
                        reason: "\(names.first) and \(names.second) prefer neighboring seats but are not neighbors at their table.",
                        contradictsAnotherPreference: contradictsAnotherPreference
                    )
                }
                return RuleEvaluation(
                    preferenceID: preference.id,
                    status: .conflict,
                    guestIDs: guestIDs,
                    reason: "\(names.first) and \(names.second) prefer neighboring seats but sit at different tables.",
                    contradictsAnotherPreference: contradictsAnotherPreference
                )
            }
            return RuleEvaluation(
                preferenceID: preference.id,
                status: .satisfied,
                guestIDs: guestIDs,
                reason: "\(names.first) and \(names.second) sit in neighboring seats.",
                contradictsAnotherPreference: contradictsAnotherPreference
            )
        }
    }

    private static func displayNamePair(event: SeatingEvent, first: UUID, second: UUID) -> (first: String, second: String) {
        let firstName = event.guest(first)?.displayName ?? "Guest \(first.uuidString.prefix(4))"
        let secondName = event.guest(second)?.displayName ?? "Guest \(second.uuidString.prefix(4))"
        return (firstName, secondName)
    }
}
