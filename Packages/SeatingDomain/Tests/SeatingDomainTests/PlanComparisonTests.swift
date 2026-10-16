import Testing
import Foundation
@testable import SeatingDomain

@Suite("Issue 19 plan comparison and final locking")
struct PlanComparisonTests {
    private func baseEvent() -> (SeatingEvent, GuestIdentity, GuestIdentity, UUID, UUID) {
        let g1 = GuestIdentity(displayName: "Aster")
        let g2 = GuestIdentity(displayName: "Basil")
        let p = PairPreference(firstGuestID: g1.id, secondGuestID: g2.id, kind: .sameTable)
        let t1 = SeatingTable(label: "T1", seatCount: 4)
        let vA = PlanVariant(name: "A", tables: [t1], assignments: [SeatAssignment(guestID: g1.id, tableID: t1.id, seatNumber: 1)])
        let vB = PlanVariant(name: "B", tables: [t1], assignments: [
            SeatAssignment(guestID: g1.id, tableID: t1.id, seatNumber: 1),
            SeatAssignment(guestID: g2.id, tableID: t1.id, seatNumber: 2)
        ])
        let event = SeatingEvent(title: "Party", guests: [g1, g2], preferences: [p], variants: [vA, vB])
        return (event, g1, g2, vA.id, vB.id)
    }

    @Test func comparisonDetectsNewlySeatedGuestAndSatisfiedPreference() {
        let (event, _, g2, vAID, vBID) = baseEvent()
        let vA = event.variant(vAID)!
        let vB = event.variant(vBID)!
        let comp = PlanComparison.make(event: event, from: vA, to: vB)
        #expect(comp.guests.count == 1)
        #expect(comp.guests.first?.guest.id == g2.id)
        #expect(comp.guests.first?.kind == .newlySeated)
        #expect(comp.preferences.count == 1)
        #expect(comp.preferences.first?.before == .unresolved)
        #expect(comp.preferences.first?.after == .satisfied)
    }

    @Test func finalPlanRejectsAllSeatingEditsUntilUnlocked() throws {
        let (event, g1, _, vAID, _) = baseEvent()
        var cmd = SeatingCommands(event: event)
        try cmd.setFinal(variantID: vAID, isFinal: true)
        #expect(cmd.currentEvent.variant(vAID)?.isFinal == true)

        let tID = event.variant(vAID)!.tables.first!.id
        // Seat edits rejected
        #expect(throws: CommandError.self) {
            try cmd.move(variantID: vAID, guestID: g1.id, tableID: tID, seatNumber: 3)
        }
        #expect(throws: CommandError.self) {
            try cmd.unseat(variantID: vAID, guestID: g1.id)
        }
        #expect(throws: CommandError.self) {
            try cmd.addTable(toVariant: vAID, label: "T2", seatCount: 4)
        }
        #expect(throws: CommandError.self) {
            try cmd.renameVariant(id: vAID, newName: "Renamed")
        }

        // Shared data edits rejected while ANY plan is final
        #expect(throws: CommandError.self) {
            try cmd.addGuest(displayName: "Clover")
        }
        #expect(throws: CommandError.self) {
            try cmd.renameGuest(id: g1.id, newName: "Asterix")
        }

        // Explicit unlock permits edits again
        try cmd.setFinal(variantID: vAID, isFinal: false)
        #expect(cmd.currentEvent.variant(vAID)?.isFinal == false)
        try cmd.move(variantID: vAID, guestID: g1.id, tableID: tID, seatNumber: 3)
        #expect(cmd.currentEvent.variant(vAID)?.seat(for: g1.id)?.seatNumber == 3)
    }

    @Test func duplicatingFinalPlanYieldsUnlockedEditableCopy() throws {
        let (event, g1, _, vAID, _) = baseEvent()
        var cmd = SeatingCommands(event: event)
        try cmd.setFinal(variantID: vAID, isFinal: true)

        let copy = try cmd.duplicateVariant(id: vAID, newName: "A Copy")
        #expect(copy.isFinal == false)
        let copyTID = copy.tables.first!.id
        // Copy can be moved even though source is locked
        try cmd.move(variantID: copy.id, guestID: g1.id, tableID: copyTID, seatNumber: 4)
        #expect(cmd.currentEvent.variant(copy.id)?.seat(for: g1.id)?.seatNumber == 4)
    }

    @Test func codablePreservesFinalFlag() throws {
        let (event, _, _, vAID, _) = baseEvent()
        var cmd = SeatingCommands(event: event)
        try cmd.setFinal(variantID: vAID, isFinal: true)
        let data = try JSONEncoder().encode(cmd.currentEvent)
        let decoded = try JSONDecoder().decode(SeatingEvent.self, from: data)
        #expect(decoded.variant(vAID)?.isFinal == true)
    }

    @Test func undoCannotChangeFinalPlanContentAndUnlockIsExplicit() throws {
        let (event, g1, _, vAID, _) = baseEvent()
        var cmd = SeatingCommands(event: event)
        try cmd.setFinal(variantID: vAID, isFinal: true)
        // Undoing the lock is refused: removing a final designation must be
        // an explicit unlock, never an undo side effect.
        #expect(throws: CommandError.self) { try cmd.undo() }
        #expect(cmd.currentEvent.variant(vAID)?.isFinal == true)
        // After an explicit unlock the same undo path works for seat edits.
        try cmd.setFinal(variantID: vAID, isFinal: false)
        let tID = event.variant(vAID)!.tables.first!.id
        try cmd.move(variantID: vAID, guestID: g1.id, tableID: tID, seatNumber: 2)
        try cmd.undo()
        #expect(cmd.currentEvent.variant(vAID)?.seat(for: g1.id)?.seatNumber == 1)
    }

    @Test func deletingGuestSeatedInFinalPlanIsRefused() throws {
        let (event, g1, _, vAID, _) = baseEvent()
        var cmd = SeatingCommands(event: event)
        try cmd.setFinal(variantID: vAID, isFinal: true)
        let preview = try cmd.guestDeletionPreview(guestID: g1.id)
        #expect(preview.affectedFinalPlanNames == ["A"])
        #expect(throws: CommandError.self) {
            try cmd.deleteGuest(guestID: g1.id, confirmedPreview: preview)
        }
        #expect(cmd.currentEvent.guest(g1.id) != nil)
    }

    @Test func backupRestorePreservesFinalDesignation() throws {
        let (event, _, _, vAID, _) = baseEvent()
        var cmd = SeatingCommands(event: event)
        try cmd.setFinal(variantID: vAID, isFinal: true)
        let data = try SeatingBackup.encodeBackup(of: cmd.currentEvent)
        let (restored, _) = try SeatingBackup.decodeBackup(data)
        #expect(restored.variants.count == 2)
        #expect(restored.variants.first?.isFinal == true)
        #expect(restored.variants.last?.isFinal == false)
    }

    @Test func comparisonOfIndependentVariantsExplainsSamePrintedPosition() throws {
        let (event, g1, _, vAID, _) = baseEvent()
        var cmd = SeatingCommands(event: event)
        let copy = try cmd.duplicateVariant(id: vAID, newName: "A Copy")
        // Duplicate deliberately remaps table UUIDs: same printed label and
        // seat number is NOT the same table identity.
        let original = cmd.currentEvent.variant(vAID)!
        let copyTable = copy.tables.first!
        try cmd.move(variantID: copy.id, guestID: g1.id, tableID: copyTable.id, seatNumber: 2)
        let comp = PlanComparison.make(event: cmd.currentEvent, from: original, to: cmd.currentEvent.variant(copy.id)!)
        #expect(comp.tablesAreIndependentlyIdentified)
        #expect(comp.guests.count == 1)
        #expect(comp.guests.first?.kind == .moved)
        #expect(comp.guests.first?.beforeTableLabel == "T1")
        #expect(comp.guests.first?.afterTableLabel == "T1")
        #expect(comp.guests.first?.samePrintedPosition == false)
    }

    @Test func duplicateNamedGuestsCompareByIdentityNotLabel() throws {
        let a1 = GuestIdentity(displayName: "Jordan")
        let a2 = GuestIdentity(displayName: "Jordan")
        let t1 = SeatingTable(label: "T1", seatCount: 4)
        let vA = PlanVariant(name: "A", tables: [t1], assignments: [
            SeatAssignment(guestID: a1.id, tableID: t1.id, seatNumber: 1)
        ])
        let vB = PlanVariant(name: "B", tables: [t1], assignments: [
            SeatAssignment(guestID: a2.id, tableID: t1.id, seatNumber: 1)
        ])
        let event = SeatingEvent(title: "Party", guests: [a1, a2], preferences: [], variants: [vA, vB])
        let comp = PlanComparison.make(event: event, from: vA, to: vB)
        // Two distinct identities moved even though both print "Jordan, seat 1".
        #expect(comp.guests.count == 2)
        #expect(Set(comp.guests.map(\.guest.id)) == [a1.id, a2.id])
        #expect(comp.guests.allSatisfy { $0.kind == .moved || $0.kind == .newlySeated || $0.kind == .newlyUnseated })
    }
}
