#if canImport(SwiftData)
import Foundation
import SwiftData

/// One persisted event snapshot. The Codable document keeps command,
/// validation and import boundaries identical to the in-memory model.
@Model
public final class StoredEvent {
    public var eventID: UUID
    public var updatedAt: Date
    public var snapshot: Data

    public init(eventID: UUID, updatedAt: Date = Date(), snapshot: Data) {
        self.eventID = eventID
        self.updatedAt = updatedAt
        self.snapshot = snapshot
    }
}

/// SwiftData-backed local store with no CloudKit or network configuration.
/// Stores use isolated file URLs so tests never share state with the app.
public struct EventStore {
    public enum StoreError: Error, LocalizedError {
        case saveFailed(underlying: Error)
        case loadFailed(underlying: Error)
        case snapshotInvalid

        public var errorDescription: String? {
            switch self {
            case .saveFailed(let error): return "The event could not be saved: \(error.localizedDescription)"
            case .loadFailed(let error): return "Stored events could not be read: \(error.localizedDescription)"
            case .snapshotInvalid: return "A stored event snapshot is unreadable."
            }
        }
    }

    private let container: ModelContainer

    /// Production stores point at Application Support; callers pass the URL.
    public static func makeFileStore(directory: URL) throws -> EventStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("seatweave.sqlite")
        let configuration = ModelConfiguration(url: url)
        let container = try ModelContainer(for: StoredEvent.self, configurations: configuration)
        return EventStore(container: container)
    }

    /// Fresh isolated on-disk store in its own temporary directory.
    public static func makeTemporaryStore() throws -> EventStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seatweave-tests-\(UUID().uuidString)", isDirectory: true)
        return try makeFileStore(directory: directory)
    }

    public func save(_ event: SeatingEvent) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(event)
        }
        // Round-trip check: never persist a document that cannot be re-read.
        guard (try? JSONDecoder().decode(SeatingEvent.self, from: data)) != nil else {
            throw StoreError.snapshotInvalid
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredEvent>(predicate: #Predicate { $0.eventID == event.id })
        let records: [StoredEvent]
        do {
            records = try context.fetch(descriptor)
        } catch {
            throw StoreError.loadFailed(underlying: error)
        }
        // One record per event: saving again replaces the stored snapshot.
        if let existing = records.first {
            existing.snapshot = data
            existing.updatedAt = Date()
        } else {
            context.insert(StoredEvent(eventID: event.id, snapshot: data))
        }
        do {
            try context.save()
        } catch {
            throw StoreError.saveFailed(underlying: error)
        }
    }

    public func load(eventID: UUID) throws -> SeatingEvent? {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredEvent>(
            predicate: #Predicate { $0.eventID == eventID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let records: [StoredEvent]
        do {
            records = try context.fetch(descriptor)
        } catch {
            throw StoreError.loadFailed(underlying: error)
        }
        guard let record = records.first else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(SeatingEvent.self, from: record.snapshot)
        } catch {
            throw StoreError.snapshotInvalid
        }
    }

    public func eventCount() throws -> Int {
        let context = ModelContext(container)
        do {
            return try context.fetchCount(FetchDescriptor<StoredEvent>())
        } catch {
            throw StoreError.loadFailed(underlying: error)
        }
    }
}

extension EventStore {
    /// Test seam: writes an undecodable snapshot under the given event ID.
    func saveCorruptSnapshot(eventID: UUID) throws {
        let context = ModelContext(container)
        context.insert(StoredEvent(eventID: eventID, snapshot: Data("not-json".utf8)))
        try context.save()
    }
}
#endif
