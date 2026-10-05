import Foundation
import Testing
@testable import SeatingDomain

@Suite("Issue 15 private plan review")
struct PlanReviewTests {
    private func fixture() -> (SeatingEvent, UUID, UUID, UUID, UUID) {
        let a = GuestIdentity(displayName: "Aster")
        let b = GuestIdentity(displayName: "Basil")
        let c = GuestIdentity(displayName: "Cleo")
        let table = SeatingTable(label: "Round", seatCount: 3)
        let variant = PlanVariant(name: "Plan A", tables: [table])
        let rule = PairPreference(firstGuestID: a.id, secondGuestID: b.id, kind: .differentTables)
        let event = SeatingEvent(title: "Synthetic dinner", guests: [a, b, c],
                                 preferences: [rule], variants: [variant])
        return (event, variant.id, table.id, a.id, b.id)
    }

    @Test("Incomplete plans distinguish unseated guests, informative empty seats and unresolved rules")
    func incomplete() throws {
        let (event, variantID, tableID, a, _) = fixture()
        var commands = SeatingCommands(event: event)
        let empty = PlanReview.make(event: event, variant: try #require(event.variant(variantID)))
        #expect(empty.unseated.count == 3)
        #expect(empty.emptySeats.count == 3)
        #expect(empty.unresolved.count == 1)
        #expect(empty.conflicts.isEmpty)
        try commands.assign(variantID: variantID, guestID: a, tableID: tableID, seatNumber: 1)
        let partly = PlanReview.make(event: commands.currentEvent,
                                     variant: try #require(commands.currentEvent.variant(variantID)))
        #expect(partly.unseated.map(\.displayName) == ["Basil", "Cleo"])
        #expect(partly.emptySeats.map(\.number) == [2, 3])
        #expect(partly.unresolved.count == 1)
    }

    @Test("Acknowledged conflicts remain conflicts; seating or rule edits invalidate the acknowledgement")
    func acknowledgement() throws {
        let (event, variantID, tableID, a, b) = fixture()
        var commands = SeatingCommands(event: event)
        try commands.assign(variantID: variantID, guestID: a, tableID: tableID, seatNumber: 1)
        try commands.assign(variantID: variantID, guestID: b, tableID: tableID, seatNumber: 2)
        let conflicted = commands.currentEvent
        let review = PlanReview.make(event: conflicted, variant: try #require(conflicted.variant(variantID)))
        #expect(review.conflicts.count == 1)
        #expect(review.unacknowledgedConflicts == 1)
        let key = try #require(review.acknowledgementKeys[event.preferences[0].id])
        let noted = PlanReview.make(event: conflicted,
                                    variant: try #require(conflicted.variant(variantID)), acknowledged: [key])
        #expect(noted.unacknowledgedConflicts == 0)
        #expect(noted.conflicts.count == 1) // never rewrites rule evaluation
        try commands.move(variantID: variantID, guestID: b, tableID: tableID, seatNumber: 3)
        let moved = commands.currentEvent
        #expect(PlanReview.validAcknowledgements(event: moved, acknowledged: [key]).isEmpty)
        try commands.move(variantID: variantID, guestID: b, tableID: tableID, seatNumber: 2)
        #expect(PlanReview.validAcknowledgements(event: moved, acknowledged: [key]).isEmpty)
        try commands.unseat(variantID: variantID, guestID: b)
        let unresolved = PlanReview.make(event: commands.currentEvent,
                                         variant: try #require(commands.currentEvent.variant(variantID)), acknowledged: [key])
        #expect(unresolved.conflicts.isEmpty)
        #expect(unresolved.unresolved.count == 1)
        _ = try commands.removePreference(id: event.preferences[0].id)
        #expect(PlanReview.validAcknowledgements(event: commands.currentEvent, acknowledged: [key]).isEmpty)
    }

    @Test("A complete plan can keep informational empty seats without any warnings")
    func completeWithSpareSeat() throws {
        let (event, variantID, tableID, a, b) = fixture()
        var commands = SeatingCommands(event: event)
        let otherTable = try commands.addTable(toVariant: variantID, label: "Second", seatCount: 2)
        try commands.assign(variantID: variantID, guestID: a, tableID: tableID, seatNumber: 1)
        try commands.assign(variantID: variantID, guestID: b, tableID: otherTable.id, seatNumber: 1)
        let c = event.guests[2].id
        try commands.assign(variantID: variantID, guestID: c, tableID: tableID, seatNumber: 2)
        let current = commands.currentEvent
        let review = PlanReview.make(event: current, variant: try #require(current.variant(variantID)))
        #expect(review.unseated.isEmpty)
        #expect(review.emptySeats.count == 2)
        #expect(review.conflicts.isEmpty)
        #expect(review.unresolved.isEmpty)
    }
}
