import Foundation

/// One gathering. Guests and pair preferences are event-level; plan variants
/// live beside them. Identity is always a UUID; display names never key data.
public struct SeatingEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var guests: [GuestIdentity]
    public var preferences: [PairPreference]
    public var variants: [PlanVariant]

    public init(
        id: UUID = UUID(),
        title: String,
        guests: [GuestIdentity] = [],
        preferences: [PairPreference] = [],
        variants: [PlanVariant]
    ) {
        self.id = id
        self.title = title
        self.guests = guests
        self.preferences = preferences
        self.variants = variants
    }

    public func guest(_ id: UUID) -> GuestIdentity? {
        guests.first { $0.id == id }
    }

    public func variant(_ id: UUID) -> PlanVariant? {
        variants.first { $0.id == id }
    }
}

/// A host-entered pair preference. Symmetric in meaning, stored in one
/// direction, with a stable identity so edits and evaluation stay referential.
public struct PairPreference: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let firstGuestID: UUID
    public let secondGuestID: UUID
    public let kind: PairPreferenceKind

    public init(id: UUID = UUID(), firstGuestID: UUID, secondGuestID: UUID, kind: PairPreferenceKind) {
        self.id = id
        self.firstGuestID = firstGuestID
        self.secondGuestID = secondGuestID
        self.kind = kind
    }

    public func references(_ guestID: UUID) -> Bool {
        firstGuestID == guestID || secondGuestID == guestID
    }

    /// Unordered guest-pair key used for contradiction detection.
    public var guestPairKey: PairGuestKey {
        PairGuestKey(firstGuestID, secondGuestID)
    }
}

/// Order-insensitive identity for the two guests of a preference.
public struct PairGuestKey: Hashable, Sendable {
    public let lower: UUID
    public let higher: UUID

    public init(_ a: UUID, _ b: UUID) {
        if a.uuidString < b.uuidString {
            lower = a
            higher = b
        } else {
            lower = b
            higher = a
        }
    }
}

/// A numbered circular table. Seat numbers are always 1 through `seatCount`.
public struct SeatingTable: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var label: String
    public var seatCount: Int

    public init(id: UUID = UUID(), label: String, seatCount: Int) {
        self.id = id
        self.label = label
        self.seatCount = seatCount
    }
}

/// One guest seated at one numbered seat of one table in one variant.
public struct SeatAssignment: Codable, Hashable, Sendable {
    public let guestID: UUID
    public let tableID: UUID
    public let seatNumber: Int

    public init(guestID: UUID, tableID: UUID, seatNumber: Int) {
        self.guestID = guestID
        self.tableID = tableID
        self.seatNumber = seatNumber
    }
}

/// An independent arrangement inside an event. Tables and assignments are
/// variant-local; guests and preferences are shared through the event.
public struct PlanVariant: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var tables: [SeatingTable]
    public var assignments: [SeatAssignment]

    public init(
        id: UUID = UUID(),
        name: String,
        tables: [SeatingTable] = [],
        assignments: [SeatAssignment] = []
    ) {
        self.id = id
        self.name = name
        self.tables = tables
        self.assignments = assignments
    }

    public func table(_ id: UUID) -> SeatingTable? {
        tables.first { $0.id == id }
    }

    public func seat(for guestID: UUID) -> SeatAssignment? {
        assignments.first { $0.guestID == guestID }
    }

    public func occupant(tableID: UUID, seatNumber: Int) -> UUID? {
        assignments.first { $0.tableID == tableID && $0.seatNumber == seatNumber }?.guestID
    }

    /// Invariant used after every command and by randomized tests:
    /// no guest holds two seats, no seat holds two guests, every
    /// reference is known and every seat number is in range.
    public var occupancyIsCoherent: Bool {
        var seenGuests = Set<UUID>()
        var seenSeats = Set<SeatKey>()
        for assignment in assignments {
            guard let table = table(assignment.tableID) else { return false }
            guard assignment.seatNumber >= 1, assignment.seatNumber <= table.seatCount else { return false }
            guard seenGuests.insert(assignment.guestID).inserted else { return false }
            let key = SeatKey(tableID: assignment.tableID, seatNumber: assignment.seatNumber)
            guard seenSeats.insert(key).inserted else { return false }
        }
        return true
    }

    public struct SeatKey: Hashable {
        public let tableID: UUID
        public let seatNumber: Int
    }
}

/// Circular adjacency: seats 1 and N are neighbors; a two-seat table has
/// exactly one neighbor per seat. Cross-table pairs are never adjacent.
public func areSeatsAdjacent(_ a: Int, _ b: Int, seatCount: Int) -> Bool {
    guard a != b, a >= 1, b >= 1, a <= seatCount, b <= seatCount else { return false }
    let delta = abs(a - b)
    return delta == 1 || delta == seatCount - 1
}
