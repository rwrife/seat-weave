import Foundation

/// Persistence boundary so command semantics can be tested without a
/// database and so production code can save through SwiftData.
public protocol EventSaving: Sendable {
    func save(_ event: SeatingEvent) throws
}

/// Applies commands and only adopts new state after a successful save, so a
/// failed save leaves the visible event unchanged and never reports success.
public struct PersistentSeatingController {
    public enum Failure: Error, LocalizedError {
        case command(CommandError)
        case persistence(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .command(let error): return error.message
            case .persistence(let error): return "Saving failed: \(error.localizedDescription)"
            }
        }
    }

    private var commands: SeatingCommands
    private let saver: any EventSaving

    public init(event: SeatingEvent, saver: any EventSaving) {
        self.commands = SeatingCommands(event: event)
        self.saver = saver
    }

    public var currentEvent: SeatingEvent { commands.currentEvent }
    public var canUndo: Bool { commands.canUndo }

    /// Read-through previews for destructive-edit confirmation sheets, so
    /// the UI never needs a raw `SeatingCommands` handle.
    public func guestDeletionPreview(guestID: UUID) throws -> SeatingCommands.GuestDeletionPreview {
        try commands.guestDeletionPreview(guestID: guestID)
    }

    public func resizePreview(variantID: UUID, tableID: UUID, newSeatCount: Int) throws -> TableResizePreview {
        try commands.resizePreview(variantID: variantID, tableID: tableID, newSeatCount: newSeatCount)
    }

    /// Run one mutation: validate + apply on a copy, persist, adopt. On any
    /// failure the previous state remains current.
    public mutating func perform(_ mutation: (inout SeatingCommands) throws -> Void) throws {
        var candidate = commands
        do {
            try mutation(&candidate)
        } catch let error as CommandError {
            throw Failure.command(error)
        }
        do {
            try saver.save(candidate.currentEvent)
        } catch {
            throw Failure.persistence(underlying: error)
        }
        commands = candidate
    }

    /// Undo reverses the session-local history, then persists the restored
    /// state. A failed undo-persist keeps the pre-undo state visible.
    public mutating func undo() throws {
        var candidate = commands
        do {
            try candidate.undo()
        } catch let error as CommandError {
            throw Failure.command(error)
        }
        do {
            try saver.save(candidate.currentEvent)
        } catch {
            throw Failure.persistence(underlying: error)
        }
        commands = candidate
    }
}
