import Foundation
import Testing
@testable import SeatingDomain

/// Issue #5: full private backup, validated restore into a new event and
/// the leak-free public export. All fixtures are synthetic.
@Suite("Issue 5 backup, export and deletion contracts")
struct BackupExportTests {

    // Synthetic roster; one hostile-looking name exercises the rule that
    // content is data, never structure or a path.
    private func makeEvent(id: UUID = UUID()) -> SeatingEvent {
        let aster = GuestIdentity(displayName: "Aster")
        let basil = GuestIdentity(displayName: "Basil")
        let cleo = GuestIdentity(displayName: "Cleo")
        let hostile = GuestIdentity(displayName: "../../etc/passwd\nSeat 99: Evil \"quoted\" ünïcødé")
        let round1 = SeatingTable(label: "Round1", seatCount: 4)
        let round2 = SeatingTable(label: "Round2", seatCount: 3)
        let variant = PlanVariant(
            name: "Plan A",
            tables: [round1, round2],
            assignments: [
                SeatAssignment(guestID: aster.id, tableID: round1.id, seatNumber: 1),
                SeatAssignment(guestID: basil.id, tableID: round1.id, seatNumber: 3),
                SeatAssignment(guestID: hostile.id, tableID: round2.id, seatNumber: 1),
            ]
        )
        let preference = PairPreference(firstGuestID: aster.id, secondGuestID: basil.id, kind: .adjacent)
        return SeatingEvent(id: id, title: "Synthetic dinner",
                            guests: [aster, basil, cleo, hostile],
                            preferences: [preference],
                            variants: [variant])
    }

    // MARK: - Public export privacy

    @Test("Public export carries only title, plan name, labels and seated names")
    func publicExportPrivacy() throws {
        let event = makeEvent()
        let preview = try PublicExportBuilder.preview(event: event, variantID: event.variants[0].id)

        let text = preview.text
        #expect(!text.contains("preference"))
        #expect(!text.contains("adjacent"))
        #expect(!text.contains("Cleo"), "unseated guests must not appear")
        for guest in event.guests {
            #expect(!text.contains(guest.id.uuidString), "UUIDs must not appear")
        }
        #expect(!text.contains(event.id.uuidString))
        #expect(preview.export.rows.count == 3)
        #expect(text.contains("Synthetic dinner"))
        #expect(text.contains("Plan A"))
    }

    @Test("Export text is deterministic, seat-ordered and keeps Unicode")
    func exportDeterministic() throws {
        let event = makeEvent()
        let preview = try PublicExportBuilder.preview(event: event, variantID: event.variants[0].id)
        let lines = preview.text.split(separator: "\n").map(String.init)
        #expect(lines[1] == "Round1 — Seat 1: Aster")
        #expect(lines[2] == "Round1 — Seat 3: Basil")
        #expect(lines[3].hasPrefix("Round2 — Seat 1: "))
        #expect(lines[3].contains("ünïcødé"))
        let repeated = try PublicExportBuilder.preview(event: event, variantID: event.variants[0].id).text
        #expect(preview.text == repeated)
    }

    @Test("A hostile display name cannot forge extra seat lines")
    func hostileNameCannotForgeLines() throws {
        let event = makeEvent()
        let preview = try PublicExportBuilder.preview(event: event, variantID: event.variants[0].id)
        // 3 seats + 1 header; the "\nSeat 99: Evil" injection must not add a row.
        #expect(preview.text.split(separator: "\n").count == 4)
        #expect(preview.export.rows.count == 3)
    }

    @Test("Draft/conflict warnings exist only in the preview")
    func warningsStayOutOfSharedText() throws {
        var event = makeEvent()
        // Aster moves to the other table -> adjacent rule conflicts.
        event.variants[0].assignments[0] = SeatAssignment(
            guestID: event.guests[0].id, tableID: event.variants[0].tables[1].id, seatNumber: 2)
        // A rule touching the unseated Cleo -> unresolved.
        event.preferences.append(PairPreference(firstGuestID: event.guests[0].id,
                                                secondGuestID: event.guests[2].id, kind: .sameTable))
        let preview = try PublicExportBuilder.preview(event: event, variantID: event.variants[0].id)
        #expect(!preview.warnings.isEmpty)
        #expect(preview.warnings.contains { $0.contains("conflict") })
        #expect(preview.warnings.contains { $0.contains("unresolved") })
        #expect(preview.warnings.contains { $0.contains("not seated") })
        for warning in preview.warnings {
            let core = warning.components(separatedBy: ".").first ?? warning
            #expect(!preview.text.contains(core), "warning leaked: \(core)")
        }
    }

    @Test("Export rejects an unknown variant")
    func exportRejectsUnknownVariant() {
        let event = makeEvent()
        #expect(throws: (any Error).self) {
            try PublicExportBuilder.preview(event: event, variantID: UUID())
        }
    }

    // MARK: - Full backup round trip

    @Test("Backup round trip preserves everything except identities")
    func backupRoundTrip() throws {
        let event = makeEvent()
        let data = try SeatingBackup.encodeBackup(of: event, exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let (restored, summary) = try SeatingBackup.decodeBackup(data)
        #expect(restored.title == event.title)
        #expect(restored.guests.map(\.displayName) == event.guests.map(\.displayName))
        #expect(restored.preferences.map(\.kind) == event.preferences.map(\.kind))
        #expect(restored.variants.map(\.name) == event.variants.map(\.name))
        #expect(restored.variants[0].tables.map(\.label) == event.variants[0].tables.map(\.label))
        #expect(restored.variants[0].tables.map(\.seatCount) == event.variants[0].tables.map(\.seatCount))
        for preference in restored.preferences {
            #expect(restored.guest(preference.firstGuestID) != nil)
            #expect(restored.guest(preference.secondGuestID) != nil)
        }
        for assignment in restored.variants[0].assignments {
            #expect(restored.guest(assignment.guestID) != nil)
            #expect(restored.variants[0].tables.contains { $0.id == assignment.tableID })
        }
        let asterCopy = try #require(restored.guests.first { $0.displayName == "Aster" })
        let seat = try #require(restored.variants[0].assignments.first { $0.guestID == asterCopy.id })
        let table = try #require(restored.variants[0].tables.first { $0.id == seat.tableID })
        #expect(table.label == "Round1")
        #expect(seat.seatNumber == 1)
        #expect(summary == .init(title: event.title, guestCount: 4, preferenceCount: 1, variantCount: 1))
    }

    @Test("Restore produces entirely new identities, never colliding")
    func restoreIdentityRemap() throws {
        let original = makeEvent()
        let data = try SeatingBackup.encodeBackup(of: original)
        let (restored, _) = try SeatingBackup.decodeBackup(data)
        #expect(restored.id != original.id)
        let originalGuestIDs = Set(original.guests.map(\.id))
        #expect(restored.guests.allSatisfy { !originalGuestIDs.contains($0.id) })
        let originalTableIDs = Set(original.variants[0].tables.map(\.id))
        #expect(restored.variants[0].tables.allSatisfy { !originalTableIDs.contains($0.id) })
        let originalVariantIDs = Set(original.variants.map(\.id))
        #expect(restored.variants.allSatisfy { !originalVariantIDs.contains($0.id) })
        let (again, _) = try SeatingBackup.decodeBackup(data)
        #expect(again.id != restored.id)
    }

    @Test("Backup file is versioned and intentionally includes preferences")
    func backupVersionAndPrivacyScope() throws {
        let event = makeEvent()
        let data = try SeatingBackup.encodeBackup(of: event)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == SeatingBackup.currentVersion)
        #expect(String(data: data, encoding: .utf8)!.contains("adjacent"),
                "full backup is expected to contain private preferences")
    }

    // MARK: - Rejection gates

    @Test("Oversized input is rejected without parsing")
    func oversizedRejected() {
        let big = Data(repeating: 0x7B, count: SeatingBackup.maximumDocumentBytes + 1)
        #expect(throws: SeatingBackup.ImportError.tooLarge(bytes: big.count)) {
            try SeatingBackup.decodeBackup(big)
        }
    }

    @Test("Unsupported backup version is rejected")
    func unsupportedVersionRejected() throws {
        let event = makeEvent()
        var json = try #require(try JSONSerialization.jsonObject(
            with: try SeatingBackup.encodeBackup(of: event)) as? [String: Any])
        json["version"] = 99
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: SeatingBackup.ImportError.unsupportedVersion(found: 99)) {
            try SeatingBackup.decodeBackup(data)
        }
    }

    @Test("Garbage and truncated files are rejected")
    func garbageRejected() throws {
        #expect(throws: (any Error).self) { try SeatingBackup.decodeBackup(Data("not json at all".utf8)) }
        let data = try SeatingBackup.encodeBackup(of: makeEvent())
        #expect(throws: (any Error).self) { try SeatingBackup.decodeBackup(Data(data.prefix(data.count / 2))) }
    }

    @Test("Duplicate guest identities are rejected")
    func duplicateGuestsRejected() throws {
        let event = makeEvent()
        let broken = SeatingEvent(id: event.id, title: event.title,
                                  guests: event.guests + [event.guests[0]],
                                  preferences: event.preferences, variants: event.variants)
        let data = try SeatingBackup.encodeBackup(of: broken)
        #expect(throws: SeatingBackup.ImportError.duplicateGuestIDs) {
            try SeatingBackup.decodeBackup(data)
        }
    }

    @Test("Preferences referencing unknown guests are rejected")
    func danglingPreferenceRejected() throws {
        let event = makeEvent()
        let stranger = PairPreference(firstGuestID: UUID(), secondGuestID: event.guests[0].id, kind: .sameTable)
        let broken = SeatingEvent(id: event.id, title: event.title, guests: event.guests,
                                  preferences: event.preferences + [stranger], variants: event.variants)
        let data = try SeatingBackup.encodeBackup(of: broken)
        #expect(throws: SeatingBackup.ImportError.danglingPreference(preferenceID: stranger.id)) {
            try SeatingBackup.decodeBackup(data)
        }
    }

    @Test("Assignments referencing unknown guests or tables are rejected")
    func danglingAssignmentRejected() throws {
        let event = makeEvent()
        var variant = event.variants[0]
        variant.assignments.append(SeatAssignment(guestID: UUID(), tableID: variant.tables[0].id, seatNumber: 4))
        let broken = SeatingEvent(id: event.id, title: event.title, guests: event.guests,
                                  preferences: event.preferences, variants: [variant])
        let data = try SeatingBackup.encodeBackup(of: broken)
        #expect(throws: SeatingBackup.ImportError.danglingAssignment(variantName: "Plan A")) {
            try SeatingBackup.decodeBackup(data)
        }
    }

    @Test("Invalid seat counts and out-of-range seats are rejected")
    func invalidSeatsRejected() throws {
        let event = makeEvent()
        var badTable = event.variants[0]
        badTable.tables[0] = SeatingTable(id: badTable.tables[0].id, label: "Round1", seatCount: 99)
        let brokenTable = SeatingEvent(id: event.id, title: event.title, guests: event.guests,
                                       preferences: event.preferences, variants: [badTable])
        let data1 = try SeatingBackup.encodeBackup(of: brokenTable)
        #expect(throws: (any Error).self) { try SeatingBackup.decodeBackup(data1) }

        var badSeat = event.variants[0]
        badSeat.assignments.append(SeatAssignment(guestID: event.guests[2].id, tableID: badSeat.tables[1].id, seatNumber: 8))
        let brokenSeat = SeatingEvent(id: event.id, title: event.title, guests: event.guests,
                                      preferences: event.preferences, variants: [badSeat])
        let data2 = try SeatingBackup.encodeBackup(of: brokenSeat)
        #expect(throws: (any Error).self) { try SeatingBackup.decodeBackup(data2) }
    }

    @Test("Two guests claiming one seat are rejected")
    func doubleOccupiedSeatRejected() throws {
        let event = makeEvent()
        var variant = event.variants[0]
        variant.assignments.append(SeatAssignment(guestID: event.guests[2].id, tableID: variant.tables[0].id, seatNumber: 1))
        let broken = SeatingEvent(id: event.id, title: event.title, guests: event.guests,
                                  preferences: event.preferences, variants: [variant])
        let data = try SeatingBackup.encodeBackup(of: broken)
        #expect(throws: (any Error).self) { try SeatingBackup.decodeBackup(data) }
    }

    @Test("Product-limit violations are rejected")
    func limitsRejected() throws {
        let guests = (0..<SeatingLimits.maximumGuestsPerEvent + 1).map { GuestIdentity(displayName: "G\($0)") }
        let broken = SeatingEvent(title: "Too big", guests: guests,
                                  variants: [PlanVariant(name: "Plan A", tables: [], assignments: [])])
        let data = try SeatingBackup.encodeBackup(of: broken)
        #expect(throws: (any Error).self) { try SeatingBackup.decodeBackup(data) }
    }

    // MARK: - PDF pagination

    @Test("PDF pagination covers every row in order with page headers")
    func pdfPagination() {
        let rows = (1...60).map {
            PublicSeatingExport.Row(tableLabel: "T", seatNumber: $0, displayName: "G\($0)")
        }
        let export = PublicSeatingExport(eventTitle: "Big dinner", planName: "Plan Z", rows: rows)
        let pages = PublicPDFLayout.pages(for: export)
        #expect(pages.count == 3)
        #expect(pages[0].count == PublicPDFLayout.rowsPerPage)
        #expect(pages.flatMap { $0 } == rows)
        #expect(PublicPDFLayout.header(export, page: 2, pageCount: 3)
                == "Big dinner — Plan Z · page 2 of 3")
        // Empty plan still yields one page so the renderer prints the
        // "no guests" notice instead of an empty document.
        let empty = PublicSeatingExport(eventTitle: "E", planName: "P", rows: [])
        #expect(PublicPDFLayout.pages(for: empty) == [[]])
    }
}

#if canImport(SwiftData)
/// Restore must never mutate stored events: rejected files change nothing,
/// accepted files import as fully independent new events.
@Suite("Issue 5 restore against the local store")
struct BackupStoreTests {
    private func sampleEvent() -> SeatingEvent {
        let aster = GuestIdentity(displayName: "Aster")
        let basil = GuestIdentity(displayName: "Basil")
        let table = SeatingTable(label: "Round1", seatCount: 4)
        let variant = PlanVariant(name: "Plan A", tables: [table],
                                  assignments: [SeatAssignment(guestID: aster.id, tableID: table.id, seatNumber: 1)])
        let preference = PairPreference(firstGuestID: aster.id, secondGuestID: basil.id, kind: .sameTable)
        return SeatingEvent(title: "Synthetic dinner", guests: [aster, basil],
                            preferences: [preference], variants: [variant])
    }

    @Test("Rejected restores leave stored events byte-identical")
    func rejectedRestoreLeavesStoreUnchanged() throws {
        let store = try EventStore.makeTemporaryStore()
        let original = sampleEvent()
        try store.save(original)
        let before = try store.allEvents()

        let big = Data(repeating: 0x7B, count: SeatingBackup.maximumDocumentBytes + 1)
        #expect(throws: (any Error).self) { try SeatingBackup.decodeBackup(big) }
        #expect(throws: (any Error).self) { try SeatingBackup.decodeBackup(Data("{broken".utf8)) }
        let stranger = PairPreference(firstGuestID: UUID(), secondGuestID: original.guests[0].id, kind: .sameTable)
        let broken = SeatingEvent(id: original.id, title: original.title, guests: original.guests,
                                  preferences: [stranger], variants: original.variants)
        #expect(throws: (any Error).self) {
            try SeatingBackup.decodeBackup(try SeatingBackup.encodeBackup(of: broken))
        }

        #expect(try store.eventCount() == before.count)
        let after = try store.allEvents()
        #expect(after == before)
    }

    @Test("Accepted restore imports an independent new event")
    func acceptedRestoreIsIndependent() throws {
        let store = try EventStore.makeTemporaryStore()
        let original = sampleEvent()
        try store.save(original)

        let backup = try SeatingBackup.encodeBackup(of: original)
        let (restored, summary) = try SeatingBackup.decodeBackup(backup)
        #expect(summary.title == "Synthetic dinner")
        try store.save(restored)

        #expect(try store.eventCount() == 2)
        var edited = restored
        edited.variants[0].name = "Edited"
        try store.save(edited)
        #expect(try store.load(eventID: original.id)?.variants[0].name == "Plan A")
        #expect(try store.load(eventID: restored.id)?.variants[0].name == "Edited")
        #expect(try store.load(eventID: original.id) == original)
    }
}
#endif
