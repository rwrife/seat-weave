import Foundation

func relocateAssignment(_ guestID: UUID, to assignment: SeatAssignment, in variant: inout PlanVariant) {
    variant.assignments.removeAll { $0.guestID == guestID }
    variant.assignments.append(assignment)
}

/// Every rejected command carries a host-readable reason and leaves the
/// model byte-for-byte unchanged.
public struct CommandError: Error, Hashable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Result of a capacity reduction that would unseat people: the caller must
/// confirm the preview before applying it.
public struct TableResizePreview: Hashable, Sendable {
    public let tableID: UUID
    public let newSeatCount: Int
    /// Assignments that fall outside the new seat range.
    public let guestsToUnseat: [SeatAssignment]
}

/// Atomic, validated edits over one `SeatingEvent`. Undo is session-local:
/// completed state survives persistence/restart, undo entries deliberately
/// do not.
public struct SeatingCommands {
    private var event: SeatingEvent
    private var undoStack: [SeatingEvent] = []

    public init(event: SeatingEvent) {
        self.event = event
    }

    public var currentEvent: SeatingEvent { event }
    public var canUndo: Bool { !undoStack.isEmpty }

    // MARK: - Event-level edits

    @discardableResult
    public mutating func addGuest(displayName: String, id: UUID = UUID()) throws -> GuestIdentity {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CommandError("Guest name cannot be empty.") }
        guard event.guests.count < SeatingLimits.maximumGuestsPerEvent else {
            throw CommandError("An event holds at most \(SeatingLimits.maximumGuestsPerEvent) guests.")
        }
        guard event.guest(id) == nil else { throw CommandError("A guest with this identity already exists.") }
        commit { $0.guests.append(GuestIdentity(id: id, displayName: name)) }
        return GuestIdentity(id: id, displayName: name)
    }

    /// Renaming changes ONLY the display name. The guest UUID is the
    /// identity, so assignments in every variant and every pair
    /// preference survive untouched; duplicate display names remain
    /// separate identities. Trims surrounding whitespace, rejects an
    /// empty result and is undoable like every other command.
    @discardableResult
    public mutating func renameGuest(id guestID: UUID, newName: String) throws -> SeatingEvent {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CommandError("Guest name cannot be empty.") }
        guard let index = event.guests.firstIndex(where: { $0.id == guestID }) else {
            throw CommandError("Unknown guest.")
        }
        // A no-op rename must not pollute the undo stack.
        guard event.guests[index].displayName != name else { return event }
        commit { model in
            model.guests[index].displayName = name
        }
        return event
    }

    /// Preview of what removing a guest would change across all variants.
    public func guestDeletionPreview(guestID: UUID) throws -> GuestDeletionPreview {
        guard event.guest(guestID) != nil else { throw CommandError("Unknown guest.") }
        let removedPreferences = event.preferences.filter { $0.references(guestID) }
        let removedAssignments: [VariantAssignmentLoss] = event.variants.compactMap { variant in
            guard let seat = variant.seat(for: guestID) else { return nil }
            return VariantAssignmentLoss(variantID: variant.id, variantName: variant.name, assignment: seat)
        }
        return GuestDeletionPreview(
            guestID: guestID,
            removedPreferences: removedPreferences,
            removedAssignments: removedAssignments
        )
    }

    /// Guest deletion requires an explicit preview the caller has seen; a
    /// mismatched preview is rejected without mutation.
    @discardableResult
    public mutating func deleteGuest(guestID: UUID, confirmedPreview: GuestDeletionPreview) throws -> SeatingEvent {
        guard event.guest(guestID) != nil else { throw CommandError("Unknown guest.") }
        let fresh = try guestDeletionPreview(guestID: guestID)
        guard fresh == confirmedPreview else {
            throw CommandError("The deletion plan changed after preview; nothing was deleted.")
        }
        commit { model in
            model.guests.removeAll { $0.id == guestID }
            model.preferences.removeAll { $0.references(guestID) }
            model.variants = model.variants.map { variant in
                var copy = variant
                copy.assignments.removeAll { $0.guestID == guestID }
                return copy
            }
        }
        return event
    }

    @discardableResult
    public mutating func addPreference(firstGuestID: UUID, secondGuestID: UUID, kind: PairPreferenceKind, id: UUID = UUID()) throws -> PairPreference {
        guard event.guest(firstGuestID) != nil, event.guest(secondGuestID) != nil else {
            throw CommandError("Preferences reference guests in this event only.")
        }
        guard firstGuestID != secondGuestID else {
            throw CommandError("A preference needs two different guests.")
        }
        guard event.preferences.allSatisfy({ $0.id != id }) else {
            throw CommandError("A preference with this identity already exists.")
        }
        let preference = PairPreference(id: id, firstGuestID: firstGuestID, secondGuestID: secondGuestID, kind: kind)
        commit { $0.preferences.append(preference) }
        return preference
    }

    @discardableResult
    public mutating func removePreference(id: UUID) throws -> SeatingEvent {
        guard event.preferences.contains(where: { $0.id == id }) else {
            throw CommandError("Unknown preference.")
        }
        commit { $0.preferences.removeAll { $0.id == id } }
        return event
    }

    // MARK: - Variant structure

    @discardableResult
    public mutating func addTable(toVariant variantID: UUID, label: String, seatCount: Int) throws -> SeatingTable {
        try mutateVariant(variantID) { variant in
            guard variant.tables.count < SeatingLimits.maximumTablesPerVariant else {
                throw CommandError("A variant holds at most \(SeatingLimits.maximumTablesPerVariant) tables.")
            }
            guard seatCount >= SeatingLimits.minimumSeatsPerTable,
                  seatCount <= SeatingLimits.maximumSeatsPerTable else {
                throw CommandError("Tables need \(SeatingLimits.minimumSeatsPerTable)–\(SeatingLimits.maximumSeatsPerTable) seats.")
            }
            let table = SeatingTable(label: label, seatCount: seatCount)
            variant.tables.append(table)
        }
        return try requireVariant(variantID).tables.last!
    }

    @discardableResult
    public mutating func duplicateVariant(id variantID: UUID, newName: String) throws -> PlanVariant {
        guard event.variants.count < SeatingLimits.maximumVariantsPerEvent else {
            throw CommandError("An event holds at most \(SeatingLimits.maximumVariantsPerEvent) variants.")
        }
        guard let source = event.variant(variantID), source.occupancyIsCoherent else {
            throw CommandError("Unknown or inconsistent variant.")
        }
        let duplicate = source.remappingTableIDs(newName: newName)
        commit { $0.variants.append(duplicate) }
        return duplicate
    }

    /// Renaming never touches table IDs or assignments; selection and
    /// comparison rely on this being a pure label change.
    @discardableResult
    public mutating func renameVariant(id variantID: UUID, newName: String) throws -> SeatingEvent {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CommandError("Variant name cannot be empty.") }
        guard event.variant(variantID) != nil else { throw CommandError("Unknown variant.") }
        commit { model in
            let index = model.variants.firstIndex(where: { $0.id == variantID })!
            model.variants[index].name = name
        }
        return event
    }

    /// Capacity changes need an explicit unseat preview first.
    public func resizePreview(variantID: UUID, tableID: UUID, newSeatCount: Int) throws -> TableResizePreview {
        let variant = try requireVariant(variantID)
        guard variant.table(tableID) != nil else { throw CommandError("Unknown table.") }
        guard newSeatCount >= SeatingLimits.minimumSeatsPerTable,
              newSeatCount <= SeatingLimits.maximumSeatsPerTable else {
            throw CommandError("Tables need \(SeatingLimits.minimumSeatsPerTable)–\(SeatingLimits.maximumSeatsPerTable) seats.")
        }
        let doomed = variant.assignments.filter {
            $0.tableID == tableID && $0.seatNumber > newSeatCount
        }
        return TableResizePreview(tableID: tableID, newSeatCount: newSeatCount, guestsToUnseat: doomed)
    }

    @discardableResult
    public mutating func resizeTable(variantID: UUID, preview: TableResizePreview, confirmed: Bool) throws -> SeatingEvent {
        guard confirmed else { throw CommandError("Resizing a table requires confirmation.") }
        let variant = try requireVariant(variantID)
        guard variant.table(preview.tableID) != nil else { throw CommandError("Unknown table.") }
        // Re-validate: the plan must still match the current model.
        let fresh = try resizePreview(variantID: variantID, tableID: preview.tableID, newSeatCount: preview.newSeatCount)
        guard fresh == preview else { throw CommandError("The table changed after preview; nothing was resized.") }
        try mutateVariant(variantID) { target in
            guard let index = target.tables.firstIndex(where: { $0.id == preview.tableID }) else {
                throw CommandError("Unknown table.")
            }
            target.tables[index].seatCount = preview.newSeatCount
            target.assignments.removeAll { $0.tableID == preview.tableID && $0.seatNumber > preview.newSeatCount }
        }
        return event
    }

    // MARK: - Seating commands

    @discardableResult
    public mutating func assign(variantID: UUID, guestID: UUID, tableID: UUID, seatNumber: Int) throws -> SeatingEvent {
        guard event.guest(guestID) != nil else { throw CommandError("Unknown guest.") }
        try mutateVariant(variantID) { variant in
            guard let table = variant.table(tableID) else { throw CommandError("Unknown table.") }
            guard seatNumber >= 1, seatNumber <= table.seatCount else {
                throw CommandError("Seat numbers run 1 through \(table.seatCount).")
            }
            guard variant.seat(for: guestID) == nil else {
                throw CommandError("Use move for a guest who is already seated.")
            }
            guard variant.occupant(tableID: tableID, seatNumber: seatNumber) == nil else {
                throw CommandError("That seat is taken; use swap with confirmation.")
            }
            variant.assignments.append(SeatAssignment(guestID: guestID, tableID: tableID, seatNumber: seatNumber))
        }
        return event
    }

    @discardableResult
    public mutating func move(variantID: UUID, guestID: UUID, tableID: UUID, seatNumber: Int) throws -> SeatingEvent {
        try mutateVariant(variantID) { variant in
            guard variant.seat(for: guestID) != nil else { throw CommandError("That guest is not seated; use assign.") }
            guard let table = variant.table(tableID) else { throw CommandError("Unknown table.") }
            guard seatNumber >= 1, seatNumber <= table.seatCount else {
                throw CommandError("Seat numbers run 1 through \(table.seatCount).")
            }
            guard variant.occupant(tableID: tableID, seatNumber: seatNumber) == nil else {
                throw CommandError("That seat is taken; use swap with confirmation.")
            }
            relocateAssignment(guestID, to: SeatAssignment(guestID: guestID, tableID: tableID, seatNumber: seatNumber), in: &variant)
        }
        return event
    }

    /// Swapping requires the caller's explicit confirmation of the exact pair.
    @discardableResult
    public mutating func swap(variantID: UUID, firstGuestID: UUID, secondGuestID: UUID, confirmed: Bool) throws -> SeatingEvent {
        guard confirmed else { throw CommandError("Swapping seats requires confirmation.") }
        try mutateVariant(variantID) { variant in
            guard let firstSeat = variant.seat(for: firstGuestID),
                  let secondSeat = variant.seat(for: secondGuestID) else {
                throw CommandError("Both guests must be seated to swap.")
            }
            relocateAssignment(firstGuestID, to: SeatAssignment(guestID: firstGuestID, tableID: secondSeat.tableID, seatNumber: secondSeat.seatNumber), in: &variant)
            relocateAssignment(secondGuestID, to: SeatAssignment(guestID: secondGuestID, tableID: firstSeat.tableID, seatNumber: firstSeat.seatNumber), in: &variant)
        }
        return event
    }

    @discardableResult
    public mutating func unseat(variantID: UUID, guestID: UUID) throws -> SeatingEvent {
        try mutateVariant(variantID) { variant in
            guard variant.seat(for: guestID) != nil else { throw CommandError("That guest is not seated.") }
            variant.assignments.removeAll { $0.guestID == guestID }
        }
        return event
    }

    // MARK: - Session undo

    public mutating func undo() throws {
        guard let previous = undoStack.popLast() else {
            throw CommandError("Nothing left to undo in this session.")
        }
        event = previous
    }

    // MARK: - Internals

    public struct VariantAssignmentLoss: Hashable, Sendable {
        public let variantID: UUID
        public let variantName: String
        public let assignment: SeatAssignment
    }

    public struct GuestDeletionPreview: Hashable, Sendable {
        public let guestID: UUID
        public let removedPreferences: [PairPreference]
        public let removedAssignments: [VariantAssignmentLoss]
    }

    private func requireVariant(_ id: UUID) throws -> PlanVariant {
        guard let variant = event.variant(id) else { throw CommandError("Unknown variant.") }
        return variant
    }

    /// Copy-on-write mutation: validation happens against a copy, so any
    /// thrown error leaves `event` untouched and never reports success.
    private mutating func mutateVariant(_ id: UUID, _ mutation: (inout PlanVariant) throws -> Void) throws {
        guard var variant = event.variant(id) else { throw CommandError("Unknown variant.") }
        try mutation(&variant)
        guard variant.occupancyIsCoherent else {
            throw CommandError("The change would break seating occupancy; nothing was applied.")
        }
        commit { $0.variants[$0.variants.firstIndex(where: { $0.id == id })!] = variant }
    }

    private mutating func commit(_ change: (inout SeatingEvent) -> Void) {
        undoStack.append(event)
        change(&event)
    }
}

extension PlanVariant {
    /// Duplicate remaps table UUIDs so later table edits stay independent.
    func remappingTableIDs(newName: String) -> PlanVariant {
        var idMap: [UUID: UUID] = [:]
        var newTables: [SeatingTable] = []
        for table in tables {
            let fresh = UUID()
            idMap[table.id] = fresh
            newTables.append(SeatingTable(id: fresh, label: table.label, seatCount: table.seatCount))
        }
        let newAssignments = assignments.map { assignment in
            SeatAssignment(guestID: assignment.guestID, tableID: idMap[assignment.tableID]!, seatNumber: assignment.seatNumber)
        }
        return PlanVariant(name: newName, tables: newTables, assignments: newAssignments)
    }
}
