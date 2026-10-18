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

@Model
public final class StoredRecoveryPoint {
    public var id: UUID
    public var eventID: UUID
    public var createdAt: Date
    public var title: String
    public var guestCount: Int
    public var preferenceCount: Int
    public var variantCount: Int
    public var document: Data

    public init(event: SeatingEvent, document: Data, date: Date) {
        id = UUID()
        eventID = event.id
        createdAt = date
        title = event.title
        guestCount = event.guests.count
        preferenceCount = event.preferences.count
        variantCount = event.variants.count
        self.document = document
    }
}

@Model
public final class StoredDeletion {
    public var eventID: UUID
    public var deletedAt: Date
    public var title: String
    public var document: Data

    public init(event: SeatingEvent, document: Data, date: Date) {
        eventID = event.id
        deletedAt = date
        title = event.title
        self.document = document
    }
}

/// SwiftData-backed local store with no CloudKit or network configuration.
/// Stores use isolated file URLs so tests never share state with the app.
public struct EventStore {
    public struct RecoveryPoint: Identifiable, Sendable {
        public let id: UUID
        public let eventID: UUID
        public let createdAt: Date
        public let title: String
        public let guestCount: Int
        public let preferenceCount: Int
        public let variantCount: Int
    }

    public struct DeletedEvent: Identifiable, Sendable {
        public var id: UUID { eventID }
        public let eventID: UUID
        public let deletedAt: Date
        public let title: String
    }

    /// Every successful save creates one private point; keep ten per event
    /// for at most fourteen days (2 MiB each, 20 MiB per event).
    public static let recoveryDays = 14
    public static let maximumPointsPerEvent = 10
    public static let maximumPointBytes = SeatingBackup.maximumDocumentBytes
    private static let recoveryAge: TimeInterval = 14 * 24 * 60 * 60
    private let clock: () -> Date

    private init(container: ModelContainer, clock: @escaping () -> Date) {
        self.container = container
        self.clock = clock
    }
    public enum StoreError: Error, LocalizedError {
        case saveFailed(underlying: Error)
        case loadFailed(underlying: Error)
        case snapshotInvalid
        case snapshotTooLarge
        case recoveryPointMissing

        public var errorDescription: String? {
            switch self {
            case .saveFailed(let error): return "The event could not be saved: \(error.localizedDescription)"
            case .loadFailed(let error): return "Stored events could not be read: \(error.localizedDescription)"
            case .snapshotInvalid: return "A recovery copy is unreadable. Other recovery points remain available."
            case .snapshotTooLarge: return "Event exceeds the 2 MiB recovery limit. Nothing was saved."
            case .recoveryPointMissing: return "That recovery point is no longer available."
            }
        }
    }

    private let container: ModelContainer

    /// Production stores point at Application Support; callers pass the URL.
    public static func makeFileStore(directory: URL, now: @escaping () -> Date = Date.init) throws -> EventStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("seatweave.sqlite")
        let configuration = ModelConfiguration(url: url)
        let container = try ModelContainer(for: StoredEvent.self, StoredRecoveryPoint.self,
                                           StoredDeletion.self, configurations: configuration)
        return EventStore(container: container, clock: now)
    }

    /// Fresh isolated on-disk store in its own temporary directory.
    public static func makeTemporaryStore(now: @escaping () -> Date = Date.init) throws -> EventStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seatweave-tests-\(UUID().uuidString)", isDirectory: true)
        return try makeFileStore(directory: directory, now: now)
    }

    /// Saves current event and recovery point in one SwiftData transaction.
    /// A failed write never adopts an unsnapshotted event or prunes known-good points.
    /// ponytail: snapshot every successful save; compact by count and age instead of a timer.
    /// If high-frequency editing becomes costly, add a durable debounce journal.
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
        // Size bound is enforced BEFORE any write, so an oversized event
        // leaves the previous known-good state completely untouched.
        guard data.count + 1024 <= Self.maximumPointBytes else {
            throw StoreError.snapshotTooLarge
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredEvent>(predicate: #Predicate { $0.eventID == event.id })
        let records: [StoredEvent]
        do {
            records = try context.fetch(descriptor)
        } catch {
            throw StoreError.loadFailed(underlying: error)
        }
        // One current record per event: saving again replaces the stored snapshot.
        if let existing = records.first {
            existing.snapshot = data
            existing.updatedAt = clock()
        } else {
            context.insert(StoredEvent(eventID: event.id, updatedAt: clock(), snapshot: data))
        }
        do {
            try appendRecoveryPoint(event: event, document: data, context: context)
            try context.save()
        } catch let error as StoreError {
            throw error
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

    /// Every stored event, most recently updated first. A snapshot that
    /// cannot be decoded fails explicitly rather than being skipped.
    public func allEvents() throws -> [SeatingEvent] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredEvent>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let records: [StoredEvent]
        do {
            records = try context.fetch(descriptor)
        } catch {
            throw StoreError.loadFailed(underlying: error)
        }
        let decoder = JSONDecoder()
        return try records.map { record in
            do {
                return try decoder.decode(SeatingEvent.self, from: record.snapshot)
            } catch {
                throw StoreError.snapshotInvalid
            }
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

    /// Moves one event into recently-deleted. The document, its automatic
    /// recovery points and every pair preference stay on this device for
    /// `recoveryDays`, then age out. Exported files and OS backups outside
    /// the app are beyond reach.
    public func delete(eventID: UUID) throws {
        let context = ModelContext(container)
        do {
            try moveEventToRecentlyDeleted(eventID: eventID, context: context)
            try context.save()
        } catch {
            throw StoreError.saveFailed(underlying: error)
        }
    }

    /// Permanently removes one event, its recovery points AND its
    /// recently-deleted copy in one transaction. No hidden copies remain.
    public func deletePermanently(eventID: UUID) throws {
        let context = ModelContext(container)
        do {
            for record in try context.fetch(FetchDescriptor<StoredEvent>(
                predicate: #Predicate { $0.eventID == eventID })) {
                context.delete(record)
            }
            for point in try context.fetch(FetchDescriptor<StoredRecoveryPoint>(
                predicate: #Predicate { $0.eventID == eventID })) {
                context.delete(point)
            }
            for deletion in try context.fetch(FetchDescriptor<StoredDeletion>(
                predicate: #Predicate { $0.eventID == eventID })) {
                context.delete(deletion)
            }
            try context.save()
        } catch {
            throw StoreError.saveFailed(underlying: error)
        }
    }

    /// Permanently removes every event, recovery point and recently-deleted
    /// copy (delete-all, UI-confirmed). Retains nothing to recover.
    public func deleteAll() throws {
        let context = ModelContext(container)
        do {
            for record in try context.fetch(FetchDescriptor<StoredEvent>()) {
                context.delete(record)
            }
            for point in try context.fetch(FetchDescriptor<StoredRecoveryPoint>()) {
                context.delete(point)
            }
            for deletion in try context.fetch(FetchDescriptor<StoredDeletion>()) {
                context.delete(deletion)
            }
            try context.save()
        } catch {
            throw StoreError.saveFailed(underlying: error)
        }
    }

    // MARK: - Recovery points (issue #16)

    /// Automatic snapshots for one event, newest first, expired ones gone.
    public func recoveryPoints(eventID: UUID) throws -> [RecoveryPoint] {
        let context = ModelContext(container)
        do {
            try purgeExpired(context: context)
            let points = try context.fetch(FetchDescriptor<StoredRecoveryPoint>(
                predicate: #Predicate { $0.eventID == eventID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
            try context.save()
            return points.map {
                RecoveryPoint(id: $0.id, eventID: $0.eventID, createdAt: $0.createdAt,
                              title: $0.title, guestCount: $0.guestCount,
                              preferenceCount: $0.preferenceCount, variantCount: $0.variantCount)
            }
        } catch {
            throw StoreError.loadFailed(underlying: error)
        }
    }

    /// Decodes and revalidates one recovery point without writing anything,
    /// so the host previews exactly what a restore would create. A point
    /// whose bytes are corrupt fails explicitly; it never replaces state.
    public func previewRecoveryPoint(id: UUID) throws -> (event: SeatingEvent,
                                                          summary: SeatingBackup.RestoreSummary) {
        let context = ModelContext(container)
        let point: StoredRecoveryPoint?
        do {
            point = try context.fetch(FetchDescriptor<StoredRecoveryPoint>(
                predicate: #Predicate { $0.id == id })).first
        } catch {
            throw StoreError.loadFailed(underlying: error)
        }
        guard let point, point.createdAt >= clock().addingTimeInterval(-Self.recoveryAge) else {
            throw StoreError.recoveryPointMissing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: SeatingBackup.Document
        do {
            document = try decoder.decode(SeatingBackup.Document.self, from: point.document)
        } catch {
            throw StoreError.snapshotInvalid
        }
        guard document.version == SeatingBackup.currentVersion else {
            throw SeatingBackup.ImportError.unsupportedVersion(found: document.version)
        }
        try SeatingBackup.validate(document.event)
        return (document.event, SeatingBackup.summary(of: document.event))
    }

    /// Restores a recovery point as a NEW event with fresh identities —
    /// never overwriting the current event — through the same validation
    /// and remap path as a backup import.
    public func restoreRecoveryPoint(id: UUID) throws -> SeatingEvent {
        let (source, _) = try previewRecoveryPoint(id: id)
        let restored = try SeatingBackup.remap(source)
        try save(restored)
        return restored
    }

    /// Recently-deleted events, newest first, expired entries gone.
    public func recentlyDeleted() throws -> [DeletedEvent] {
        let context = ModelContext(container)
        do {
            try purgeExpired(context: context)
            let deletions = try context.fetch(FetchDescriptor<StoredDeletion>(
                sortBy: [SortDescriptor(\.deletedAt, order: .reverse)]))
            try context.save()
            return deletions.map { DeletedEvent(eventID: $0.eventID, deletedAt: $0.deletedAt, title: $0.title) }
        } catch {
            throw StoreError.loadFailed(underlying: error)
        }
    }

    /// Puts a recently-deleted event back. The event document was never
    /// removed from its recovery copies, so restoring keeps every plan and
    /// preference exactly as deleted.
    public func restoreDeleted(eventID: UUID) throws {
        let context = ModelContext(container)
        do {
            guard let deletion = try context.fetch(FetchDescriptor<StoredDeletion>(
                predicate: #Predicate { $0.eventID == eventID })).first,
                deletion.deletedAt >= clock().addingTimeInterval(-Self.recoveryAge) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(SeatingBackup.Document.self, from: deletion.document)
            guard document.version == SeatingBackup.currentVersion, document.event.id == eventID else {
                throw StoreError.snapshotInvalid
            }
            try SeatingBackup.validate(document.event)
            let raw = try JSONEncoder().encode(document.event)
            context.insert(StoredEvent(eventID: eventID, updatedAt: clock(), snapshot: raw))
            context.delete(deletion)
            try context.save()
        } catch let error as SeatingBackup.ImportError {
            throw error
        } catch {
            throw StoreError.saveFailed(underlying: error)
        }
    }

    // MARK: - Internals

    /// Appends one point and compacts to the per-event count bound. The
    /// newest point always survives, even if oversized edge cases arise.
    private func appendRecoveryPoint(event: SeatingEvent, document: Data, context: ModelContext) throws {
        let envelope = SeatingBackup.Document(exportedAt: clock(), event: event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(envelope)
        guard payload.count <= Self.maximumPointBytes else { throw StoreError.snapshotTooLarge }
        let existing = try context.fetch(FetchDescriptor<StoredRecoveryPoint>(
            predicate: #Predicate { $0.eventID == event.id },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        context.insert(StoredRecoveryPoint(event: event, document: payload, date: clock()))
        for stale in existing.dropFirst(Self.maximumPointsPerEvent - 1) {
            context.delete(stale)
        }
        try purgeExpired(context: context)
    }

    /// Deletes older than the recovery window, for points and for the
    /// recently-deleted list. Runs inside ordinary read/write paths so no
    /// background task is needed and expired copies cannot linger.
    private func purgeExpired(context: ModelContext) throws {
        let deadline = clock().addingTimeInterval(-Self.recoveryAge)
        for point in try context.fetch(FetchDescriptor<StoredRecoveryPoint>(
            predicate: #Predicate { $0.createdAt < deadline })) {
            context.delete(point)
        }
        for deletion in try context.fetch(FetchDescriptor<StoredDeletion>(
            predicate: #Predicate { $0.deletedAt < deadline })) {
            context.delete(deletion)
        }
    }

    private func moveEventToRecentlyDeleted(eventID: UUID, context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<StoredEvent>(
            predicate: #Predicate { $0.eventID == eventID }))
        guard let record = records.first else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(SeatingEvent.self, from: record.snapshot)
        let envelope = SeatingBackup.Document(exportedAt: clock(), event: event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(envelope)
        // One recently-deleted copy per event; the newest delete wins.
        for old in try context.fetch(FetchDescriptor<StoredDeletion>(
            predicate: #Predicate { $0.eventID == eventID })) {
            context.delete(old)
        }
        context.insert(StoredDeletion(event: event, document: payload, date: clock()))
        for current in records {
            context.delete(current)
        }
    }
}

extension EventStore {
    /// Test seam: writes an undecodable snapshot under the given event ID.
    func saveCorruptSnapshot(eventID: UUID) throws {
        let context = ModelContext(container)
        context.insert(StoredEvent(eventID: eventID, updatedAt: clock(), snapshot: Data("not-json".utf8)))
        try context.save()
    }

    /// Test seam: undecodable recovery-point bytes for one event ID.
    @discardableResult
    func saveCorruptRecoveryPoint(eventID: UUID) throws -> UUID {
        let context = ModelContext(container)
        let point = StoredRecoveryPoint(event: SeatingEvent(id: eventID, title: "corrupt", variants: []),
                                        document: Data("not-json".utf8), date: clock())
        context.insert(point)
        try context.save()
        return point.id
    }

    /// Test seam: point IDs for one event, newest first.
    func recoveryPointIDs(eventID: UUID) throws -> [UUID] {
        try recoveryPoints(eventID: eventID).map(\.id)
    }

    /// Test seam: undecodable recently-deleted bytes for one event ID.
    func saveCorruptDeletion(eventID: UUID) throws {
        let context = ModelContext(container)
        context.insert(StoredDeletion(event: SeatingEvent(id: eventID, title: "corrupt", variants: []),
                                      document: Data("not-json".utf8), date: clock()))
        try context.save()
    }
}
#endif
