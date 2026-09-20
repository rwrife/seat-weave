import Foundation

/// Host-facing counts for one variant, shared by the workspace banner and
/// the variant comparison list so both always agree.
public struct VariantSummary: Hashable, Sendable {
    public let variantID: UUID
    public let name: String
    public let seated: Int
    public let unseated: Int
    public let conflicts: Int
    public let unresolved: Int

    public init(
        variantID: UUID,
        name: String,
        seated: Int,
        unseated: Int,
        conflicts: Int,
        unresolved: Int
    ) {
        self.variantID = variantID
        self.name = name
        self.seated = seated
        self.unseated = unseated
        self.conflicts = conflicts
        self.unresolved = unresolved
    }
}

public enum VariantReporter {
    public static func summarize(event: SeatingEvent, variant: PlanVariant) -> VariantSummary {
        let evaluations = RuleEngine.evaluate(event: event, variant: variant)
        return VariantSummary(
            variantID: variant.id,
            name: variant.name,
            seated: variant.assignments.count,
            unseated: max(event.guests.count - variant.assignments.count, 0),
            conflicts: evaluations.filter { $0.status == .conflict }.count,
            unresolved: evaluations.filter { $0.status == .unresolved }.count
        )
    }
}
