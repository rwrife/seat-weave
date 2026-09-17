import Foundation

/// Stable product bounds shared by the app and the future domain implementation.
public enum SeatingLimits {
    public static let maximumGuestsPerEvent = 40
    public static let maximumTablesPerVariant = 6
    public static let minimumSeatsPerTable = 2
    public static let maximumSeatsPerTable = 12
    public static let maximumVariantsPerEvent = 10
}

/// Identity is deliberately separate from a guest's user-editable display name.
public struct GuestIdentity: Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String

    public init(id: UUID = UUID(), displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// The only preference vocabulary promised by the MVP plan.
public enum PairPreferenceKind: String, CaseIterable, Codable, Sendable {
    case sameTable
    case differentTables
    case adjacent
}
