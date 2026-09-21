import Foundation

/// Issue #5 contracts: a full versioned JSON backup, its validated restore
/// into a brand-new event, and the guest-facing public export of one plan.
///
/// Privacy contract (README/PLAN):
/// - The public export contains ONLY the event title, table labels, seat
///   numbers and the display names of seated guests. Pair preferences,
///   unseated guests, UUIDs and other variants can never appear in it —
///   they are not merely filtered out; the document is a separate
///   structure that has no field capable of carrying them.
/// - Draft/conflict warnings exist only as a preview summary for the host
///   and are never serialized into the shared document.
/// - The backup is explicitly the full, private document and must be
///   presented with a privacy warning. Restore validates everything
///   BEFORE producing anything and always imports as a new event with
///   fresh IDs; it never merges into or overwrites a stored event.
public enum SeatingBackup {
    public static let currentVersion = 1
    /// Imports larger than this are rejected without parsing (PLAN bound).
    public static let maximumDocumentBytes = 2 * 1024 * 1024

    public enum ImportError: Error, Hashable, Sendable, LocalizedError {
        case tooLarge(bytes: Int)
        case unsupportedVersion(found: Int)
        case undecodable(underlying: String)
        case duplicateGuestIDs
        case duplicateVariantIDs
        case duplicateTableIDs(variantName: String)
        case danglingPreference(preferenceID: UUID)
        case danglingAssignment(variantName: String)
        case invalidSeatCount(variantName: String, tableLabel: String)
        case limitsExceeded(detail: String)
        case seatOccupiedTwice(variantName: String, tableLabel: String, seatNumber: Int)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return "The backup is \(bytes) bytes, above the \(SeatingBackup.maximumDocumentBytes)-byte limit."
            case .unsupportedVersion(let found):
                return "This file uses backup version \(found); this app reads version \(SeatingBackup.currentVersion) only."
            case .undecodable(let underlying):
                return "The backup could not be read: \(underlying)"
            case .duplicateGuestIDs:
                return "The backup lists the same guest identity twice."
            case .duplicateVariantIDs:
                return "The backup lists the same plan identity twice."
            case .duplicateTableIDs(let variant):
                return "Plan \(variant) lists the same table identity twice."
            case .danglingPreference(let id):
                return "A preference (id \(id)) references a guest that is not in the backup."
            case .danglingAssignment(let variant):
                return "Plan \(variant) assigns a seat to a guest or table that is not in the backup."
            case .invalidSeatCount(let variant, let table):
                return "Table \(table) in plan \(variant) has a seat count outside the allowed range."
            case .limitsExceeded(let detail):
                return "The backup exceeds product limits: \(detail)"
            case .seatOccupiedTwice(let variant, let table, let seat):
                return "Seat \(seat) of \(table) in plan \(variant) is assigned to more than one guest."
            }
        }
    }

    /// Envelope written to disk. `version` gates forward compatibility.
    public struct Document: Codable, Hashable, Sendable {
        public let version: Int
        public let exportedAt: Date
        public let event: SeatingEvent

        public init(version: Int = SeatingBackup.currentVersion, exportedAt: Date = Date(), event: SeatingEvent) {
            self.version = version
            self.exportedAt = exportedAt
            self.event = event
        }
    }

    // MARK: - Full private backup

    /// Deterministic full-backup JSON (sorted keys, ISO-8601 dates).
    public static func encodeBackup(of event: SeatingEvent, exportedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(exportedAt: exportedAt, event: event))
    }

    /// Summary shown before importing so the host sees exactly what will
    /// be created. Carries no private rule vocabulary beyond counts.
    public struct RestoreSummary: Hashable, Sendable {
        public let title: String
        public let guestCount: Int
        public let preferenceCount: Int
        public let variantCount: Int
    }

    /// Validate + import as a NEW event with fresh identities. Throws
    /// `ImportError` for any malformed input and produces nothing, so a
    /// failed restore cannot mutate existing stored events.
    public static func decodeBackup(_ data: Data, now: Date = Date()) throws -> (event: SeatingEvent, summary: RestoreSummary) {
        guard data.count <= maximumDocumentBytes else {
            throw ImportError.tooLarge(bytes: data.count)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.undecodable(underlying: String(describing: error))
        }
        guard document.version == currentVersion else {
            throw ImportError.unsupportedVersion(found: document.version)
        }
        let source = document.event
        try validate(source)
        return (try remap(source), summary(of: source))
    }

    static func validate(_ event: SeatingEvent) throws {
        if Set(event.guests.map(\.id)).count != event.guests.count {
            throw ImportError.duplicateGuestIDs
        }
        if Set(event.variants.map(\.id)).count != event.variants.count {
            throw ImportError.duplicateVariantIDs
        }
        if event.guests.count > SeatingLimits.maximumGuestsPerEvent {
            throw ImportError.limitsExceeded(detail: "\(event.guests.count) guests")
        }
        if event.variants.count > SeatingLimits.maximumVariantsPerEvent {
            throw ImportError.limitsExceeded(detail: "\(event.variants.count) plans")
        }
        let guestIDs = Set(event.guests.map(\.id))
        for preference in event.preferences where !guestIDs.contains(preference.firstGuestID) || !guestIDs.contains(preference.secondGuestID) {
            throw ImportError.danglingPreference(preferenceID: preference.id)
        }
        for variant in event.variants {
            if Set(variant.tables.map(\.id)).count != variant.tables.count {
                throw ImportError.duplicateTableIDs(variantName: variant.name)
            }
            if variant.tables.count > SeatingLimits.maximumTablesPerVariant {
                throw ImportError.limitsExceeded(detail: "\(variant.tables.count) tables in plan \(variant.name)")
            }
            let tableIDs = Set(variant.tables.map(\.id))
            for table in variant.tables
            where table.seatCount < SeatingLimits.minimumSeatsPerTable || table.seatCount > SeatingLimits.maximumSeatsPerTable {
                throw ImportError.invalidSeatCount(variantName: variant.name, tableLabel: table.label)
            }
            var occupied = Set<String>()
            for assignment in variant.assignments {
                guard guestIDs.contains(assignment.guestID), tableIDs.contains(assignment.tableID) else {
                    throw ImportError.danglingAssignment(variantName: variant.name)
                }
                let seatCount = variant.tables.first { $0.id == assignment.tableID }?.seatCount ?? 0
                guard assignment.seatNumber >= 1, assignment.seatNumber <= seatCount else {
                    let label = variant.tables.first { $0.id == assignment.tableID }?.label ?? "?"
                    throw ImportError.invalidSeatCount(variantName: variant.name, tableLabel: label)
                }
                let key = "\(assignment.tableID.uuidString)#\(assignment.seatNumber)"
                guard !occupied.contains(key) else {
                    let label = variant.tables.first { $0.id == assignment.tableID }?.label ?? "?"
                    throw ImportError.seatOccupiedTwice(variantName: variant.name, tableLabel: label, seatNumber: assignment.seatNumber)
                }
                occupied.insert(key)
            }
        }
    }

    /// Fresh UUIDs for event, guests, preferences, variants and tables,
    /// with assignments rewritten through the guest/table maps. Identities
    /// inside the backup can therefore never collide with stored events.
    static func remap(_ event: SeatingEvent) throws -> SeatingEvent {
        let guestMap = Dictionary(uniqueKeysWithValues: event.guests.map { ($0.id, UUID()) })
        let preferenceMap = Dictionary(uniqueKeysWithValues: event.preferences.map { ($0.id, UUID()) })
        let variantMap = Dictionary(uniqueKeysWithValues: event.variants.map { ($0.id, UUID()) })
        var tableMaps: [UUID: [UUID: UUID]] = [:]
        for variant in event.variants {
            tableMaps[variant.id] = Dictionary(uniqueKeysWithValues: variant.tables.map { ($0.id, UUID()) })
        }
        let guests = event.guests.map { GuestIdentity(id: guestMap[$0.id]!, displayName: $0.displayName) }
        let preferences = event.preferences.map {
            PairPreference(
                id: preferenceMap[$0.id]!,
                firstGuestID: guestMap[$0.firstGuestID]!,
                secondGuestID: guestMap[$0.secondGuestID]!,
                kind: $0.kind
            )
        }
        let variants = event.variants.map { variant -> PlanVariant in
            let tableMap = tableMaps[variant.id]!
            let assignments = variant.assignments.map {
                SeatAssignment(guestID: guestMap[$0.guestID]!, tableID: tableMap[$0.tableID]!, seatNumber: $0.seatNumber)
            }
            return PlanVariant(id: variantMap[variant.id]!, name: variant.name,
                               tables: variant.tables.map { SeatingTable(id: tableMap[$0.id]!, label: $0.label, seatCount: $0.seatCount) },
                               assignments: assignments)
        }
        return SeatingEvent(id: UUID(), title: event.title, guests: guests, preferences: preferences, variants: variants)
    }

    static func summary(of event: SeatingEvent) -> RestoreSummary {
        RestoreSummary(title: event.title, guestCount: event.guests.count,
                       preferenceCount: event.preferences.count, variantCount: event.variants.count)
    }
}

// MARK: - Public seating export (selected plan only)

/// The guest-facing document. There is deliberately no field for
/// preferences, unseated guests, IDs or other variants.
public struct PublicSeatingExport: Codable, Hashable, Sendable {
    public struct Row: Codable, Hashable, Sendable {
        public let tableLabel: String
        public let seatNumber: Int
        public let displayName: String
    }

    public let eventTitle: String
    public let planName: String
    public let rows: [Row]
}

/// Host-facing preview: the exact public text plus warnings that live ONLY
/// in the preview. The shared text/document never contains them.
public struct PublicExportPreview: Hashable, Sendable {
    public let export: PublicSeatingExport
    public let text: String
    public let warnings: [String]
}

public enum PublicExportBuilder {
    /// Deterministic text export: `Table — Seat N: Name` lines, tables in
    /// declaration order, seats ascending. Display names are single-lined
    /// so one line always means one seat row; all other Unicode is kept.
    public static func preview(event: SeatingEvent, variantID: UUID) throws -> PublicExportPreview {
        guard let variant = event.variant(variantID) else {
            throw CommandError("Unknown plan for export.")
        }
        var rows: [PublicSeatingExport.Row] = []
        for table in variant.tables {
            let seated = variant.assignments
                .filter { $0.tableID == table.id }
                .sorted { $0.seatNumber < $1.seatNumber }
            for assignment in seated {
                let name = event.guest(assignment.guestID)?.displayName ?? "Guest"
                rows.append(.init(tableLabel: table.label, seatNumber: assignment.seatNumber,
                                  displayName: singleLine(name)))
            }
        }
        let export = PublicSeatingExport(eventTitle: event.title, planName: variant.name, rows: rows)
        var text = "\(event.title) — \(variant.name)\n"
        for row in export.rows {
            text += "\(row.tableLabel) — Seat \(row.seatNumber): \(row.displayName)\n"
        }
        if export.rows.isEmpty {
            text += "No guests seated yet.\n"
        }

        var warnings: [String] = []
        let seatedIDs = Set(variant.assignments.map(\.guestID))
        let unseated = event.guests.filter { !seatedIDs.contains($0.id) }
        if !unseated.isEmpty {
            warnings.append("\(unseated.count) guest(s) are not seated in this plan. They will not appear in the shared list.")
        }
        let evaluations = RuleEngine.evaluate(event: event, variant: variant)
        let conflicts = evaluations.filter { $0.status == .conflict }.count
        let unresolved = evaluations.filter { $0.status == .unresolved }.count
        if conflicts > 0 {
            warnings.append("This plan has \(conflicts) conflicting preference(s). The reasons are not included in the shared list.")
        }
        if unresolved > 0 {
            warnings.append("This plan has \(unresolved) unresolved preference(s). The reasons are not included in the shared list.")
        }
        return PublicExportPreview(export: export, text: text, warnings: warnings)
    }

    /// Strips newlines/carriage returns (which would fake extra seats in a
    /// line-oriented export) and trims; everything else, including Unicode,
    /// is preserved exactly.
    static func singleLine(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar in
            (scalar == "\n" || scalar == "\r") ? " " : String(scalar)
        }
        return String(scalars.joined()).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - PDF pagination (pure and unit-tested)

/// Row pagination for the PDF rendering of a public export. The renderer
/// in the app draws exactly what this returns; the layout rules live here
/// so pagination is testable without UIKit.
public enum PublicPDFLayout {
    /// Rows per page chosen for the fixed Letter-size layout.
    public static let rowsPerPage = 24

    /// Pages of rows in declaration order; at least one page (possibly
    /// empty, which the renderer prints as "No guests seated yet.").
    public static func pages(for export: PublicSeatingExport) -> [[PublicSeatingExport.Row]] {
        guard !export.rows.isEmpty else { return [[]] }
        return stride(from: 0, to: export.rows.count, by: rowsPerPage).map { start in
            Array(export.rows[start..<min(start + rowsPerPage, export.rows.count)])
        }
    }

    /// Header line repeated on every page (page numbers aid reassembly).
    public static func header(_ export: PublicSeatingExport, page: Int, pageCount: Int) -> String {
        "\(export.eventTitle) — \(export.planName) · page \(page) of \(pageCount)"
    }
}
