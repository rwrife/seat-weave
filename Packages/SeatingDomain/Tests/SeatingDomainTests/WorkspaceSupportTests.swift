import Foundation
import Testing
@testable import SeatingDomain

/// Issue #3 domain support: rename-only variant editing and the shared
/// host-facing summary used by the workspace banner and comparison list.
/// Synthetic fixtures only.
@Suite("Issue 3 workspace domain support")
struct WorkspaceSupportTests {
    private func eventWithTwoVariants() -> (SeatingEvent, UUID, UUID, UUID, UUID) {
        let alice = UUID()
        let bob = UUID()
        let tableID = UUID()
        let variantA = UUID()
        let variantB = UUID()
        let event = SeatingEvent(
            title: "Rename fixture",
            guests: [
                GuestIdentity(id: alice, displayName: "Alice"),
                GuestIdentity(id: bob, displayName: "Bob"),
            ],
            variants: [
                PlanVariant(
                    id: variantA,
                    name: "Plan A",
                    tables: [SeatingTable(id: tableID, label: "T", seatCount: 4)],
                    assignments: [SeatAssignment(guestID: alice, tableID: tableID, seatNumber: 1)]
                ),
                PlanVariant(id: variantB, name: "Plan B"),
            ]
        )
        return (event, variantA, variantB, tableID, alice)
    }

    @Test("Renaming a variant changes only its name")
    func renameIsLabelOnly() throws {
        let (event, variantA, _, tableID, alice) = eventWithTwoVariants()
        var commands = SeatingCommands(event: event)
        let before = commands.currentEvent
        try commands.renameVariant(id: variantA, newName: "  Final plan  ")
        let after = commands.currentEvent
        let renamed = try #require(after.variant(variantA))
        #expect(renamed.name == "Final plan")
        // Tables and assignments survive untouched, including table identity.
        #expect(renamed.tables == before.variant(variantA)!.tables)
        #expect(renamed.assignments == before.variant(variantA)!.assignments)
        #expect(renamed.table(tableID) != nil)
        #expect(renamed.seat(for: alice) != nil)
        // Other variants are unaffected.
        #expect(after.variant(before.variants[1].id)?.name == "Plan B")
    }

    @Test("Empty or unknown renames reject without mutation")
    func renameRejectsBadInput() throws {
        let (event, variantA, _, _, _) = eventWithTwoVariants()
        var commands = SeatingCommands(event: event)
        let before = commands.currentEvent
        #expect(throws: CommandError.self) { try commands.renameVariant(id: variantA, newName: "   ") }
        #expect(throws: CommandError.self) { try commands.renameVariant(id: UUID(), newName: "Ghost") }
        #expect(commands.currentEvent == before)
    }

    @Test("Undo restores the previous variant name")
    func renameIsUndoable() throws {
        let (event, variantA, _, _, _) = eventWithTwoVariants()
        var commands = SeatingCommands(event: event)
        try commands.renameVariant(id: variantA, newName: "Renamed")
        try commands.undo()
        #expect(commands.currentEvent.variant(variantA)?.name == "Plan A")
    }

    @Test("Summary counts seated, unseated, conflicts and unresolved")
    func summaryCounts() throws {
        let alice = UUID()
        let bob = UUID()
        let carol = UUID()
        let tableOne = UUID()
        let tableTwo = UUID()
        let variantID = UUID()
        let event = SeatingEvent(
            title: "Summary",
            guests: [
                GuestIdentity(id: alice, displayName: "Alice"),
                GuestIdentity(id: bob, displayName: "Bob"),
                GuestIdentity(id: carol, displayName: "Carol"),
            ],
            preferences: [
                PairPreference(firstGuestID: alice, secondGuestID: bob, kind: .sameTable),
                PairPreference(firstGuestID: bob, secondGuestID: carol, kind: .adjacent),
            ],
            variants: [
                PlanVariant(
                    id: variantID,
                    name: "Plan A",
                    tables: [
                        SeatingTable(id: tableOne, label: "A", seatCount: 4),
                        SeatingTable(id: tableTwo, label: "B", seatCount: 4),
                    ],
                    assignments: [
                        SeatAssignment(guestID: alice, tableID: tableOne, seatNumber: 1),
                        SeatAssignment(guestID: bob, tableID: tableTwo, seatNumber: 1),
                    ]
                )
            ]
        )
        let variant = try #require(event.variant(variantID))
        let summary = VariantReporter.summarize(event: event, variant: variant)
        #expect(summary.seated == 2)
        #expect(summary.unseated == 1)
        // alice+bob sameTable -> conflict; bob+carol adjacent -> unresolved.
        #expect(summary.conflicts == 1)
        #expect(summary.unresolved == 1)
    }

    @Test("Summary reports an empty plan consistently")
    func emptyPlanSummary() throws {
        let event = SeatingEvent(title: "Empty", variants: [PlanVariant(name: "Solo")])
        let variant = event.variants[0]
        let summary = VariantReporter.summarize(event: event, variant: variant)
        #expect(summary.seated == 0)
        #expect(summary.unseated == 0)
        #expect(summary.conflicts == 0)
        #expect(summary.unresolved == 0)
    }
}
