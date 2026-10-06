import Foundation
import Testing
@testable import SeatingDomain

/// Issue #17 — guest editing support at the domain level: rename that
/// preserves identity, whitespace/Unicode validation shared with add,
/// duplicate-name detection, and search/filter roster queries.
/// Synthetic fixtures only.

private func makeEvent(names: [String]) -> (SeatingEvent, UUID) {
    let variantID = UUID()
    let event = SeatingEvent(
        title: "Editing test",
        guests: names.map { GuestIdentity(displayName: $0) },
        variants: [PlanVariant(id: variantID, name: "Plan A",
                               tables: [SeatingTable(label: "T1", seatCount: 4)])]
    )
    return (event, variantID)
}

@Suite("Issue 17 guest rename")
struct GuestRenameTests {
    @Test("Rename changes only the display name and survives undo")
    func renameAndUndo() throws {
        let (event, _) = makeEvent(names: ["Aster"])
        var commands = SeatingCommands(event: event)
        let guestID = event.guests[0].id
        let renamed = try commands.renameGuest(id: guestID, newName: "Star")
        #expect(renamed.guests[0].displayName == "Star")
        #expect(renamed.guests[0].id == guestID)
        try commands.undo()
        #expect(commands.currentEvent.guests[0].displayName == "Aster")
    }

    @Test("Rename preserves assignments across variants and pair preferences")
    func renamePreservesReferences() throws {
        let base = Fixture()
        var commands = SeatingCommands(event: base.event)
        let variantA = commands.currentEvent.variants[0].id
        let copy = try commands.duplicateVariant(id: variantA, newName: "Plan B")
        let variantB = copy.id
        let tableID = commands.currentEvent.variant(variantA)!.tables[0].id
        try commands.assign(variantID: variantA, guestID: base.alice, tableID: tableID, seatNumber: 1)
        let alice = base.alice
        let bob = base.bob
        _ = try commands.addPreference(firstGuestID: alice, secondGuestID: bob, kind: .sameTable)
        let tableB = commands.currentEvent.variant(variantB)!.tables[0].id
        try commands.assign(variantID: variantB, guestID: alice, tableID: tableB, seatNumber: 2)

        let renamed = try commands.renameGuest(id: alice, newName: "Alice Ⅱ ✦")
        let aliceNow = renamed.guests[0]
        #expect(aliceNow.id == alice)
        #expect(aliceNow.displayName == "Alice Ⅱ ✦")
        // Assignments in BOTH variants still resolve through the same UUID.
        #expect(renamed.variant(variantA)?.seat(for: alice)?.seatNumber == 1)
        #expect(renamed.variant(variantB)?.seat(for: alice)?.seatNumber == 2)
        // The pair preference is untouched and still explains normally.
        let prefs = renamed.preferences.filter { $0.references(alice) }
        #expect(prefs.count == 1)
        let evaluations = RuleEngine.evaluate(event: renamed, variant: renamed.variant(variantA)!)
        #expect(evaluations.contains { $0.guestIDs.contains(alice) })
    }

    @Test("Rename trims whitespace, rejects empty and unknown guests without mutation")
    func renameValidation() throws {
        let (event, _) = makeEvent(names: ["Aster", "Basil"])
        var commands = SeatingCommands(event: event)
        let aster = event.guests[0].id
        let trimmed = try commands.renameGuest(id: aster, newName: "  Astrid  ")
        #expect(trimmed.guests[0].displayName == "Astrid")

        let before = commands.currentEvent
        #expect(throws: CommandError.self) { try commands.renameGuest(id: aster, newName: "   \n ") }
        #expect(throws: CommandError.self) { try commands.renameGuest(id: UUID(), newName: "Ghost") }
        #expect(commands.currentEvent == before)
    }

    @Test("Renaming to another guest's name is allowed; identities stay distinct")
    func intentionalDuplicateRename() throws {
        let (event, _) = makeEvent(names: ["Aster", "Basil"])
        var commands = SeatingCommands(event: event)
        let basil = event.guests[1].id
        let renamed = try commands.renameGuest(id: basil, newName: "aster") // folds equal to Aster
        #expect(renamed.guests[0].displayName == "Aster")
        #expect(renamed.guests[1].displayName == "aster")
        #expect(renamed.guests[0].id != renamed.guests[1].id)
        #expect(GuestRosterQuery.isDuplicate(basil, in: renamed))
    }

    @Test("No-op rename does not touch the undo stack")
    func noOpRenameSkipsUndo() throws {
        let (event, _) = makeEvent(names: ["Aster"])
        var commands = SeatingCommands(event: event)
        let aster = event.guests[0].id
        #expect(!commands.canUndo)
        _ = try commands.renameGuest(id: aster, newName: "Aster")
        #expect(!commands.canUndo)
        _ = try commands.renameGuest(id: aster, newName: " Aster ") // trims to same name
        #expect(!commands.canUndo)
    }
}

@Suite("Issue 17 duplicate-name detection")
struct DuplicateNameTests {
    @Test("Duplicates fold case, width, diacritics and surrounding whitespace")
    func foldedDuplicates() throws {
        let (event, _) = makeEvent(names: ["Amy", "amy ", " Ａmy", "Bob"])
        let duplicates = GuestRosterQuery.duplicateDisplayNameIDs(in: event)
        #expect(duplicates.count == 1)
        #expect(duplicates.values.first?.count == 3)
        #expect(GuestRosterQuery.hasDuplicateDisplayNames(in: event))
        let amyIDs = Set(event.guests.prefix(3).map(\.id))
        #expect(Set(duplicates.values.first!) == amyIDs)
        #expect(!GuestRosterQuery.isDuplicate(event.guests[3].id, in: event))
    }

    @Test("Distinct names produce no duplicate marks")
    func noDuplicates() throws {
        let (event, _) = makeEvent(names: ["Aster", "Basil", "Clove"])
        #expect(GuestRosterQuery.duplicateDisplayNameIDs(in: event).isEmpty)
        #expect(!GuestRosterQuery.hasDuplicateDisplayNames(in: event))
    }
}

@Suite("Issue 17 roster search and filters")
struct RosterQueryTests {
    @Test("Search folds case, diacritics and width; trims the needle")
    func foldedSearch() throws {
        let (event, _) = makeEvent(names: ["Aster", "José", "Ｚed"])
        func matches(_ name: String, _ search: String) -> Bool {
            let guest = event.guests.first { $0.displayName == name }!
            return GuestRosterQuery.name(guest, matchesSearch: search)
        }
        #expect(matches("Aster", "aster"))
        #expect(matches("Aster", "  AST  "))
        #expect(matches("José", "jose"))
        #expect(matches("José", "JOSÉ"))
        #expect(matches("Ｚed", "zed"))   // full-width Z folds to ASCII z
        #expect(matches("Aster", ""))      // empty search matches all
        #expect(matches("Aster", "   "))
        #expect(!matches("Aster", "basil"))
    }

    @Test("Seated/unseated filters partition by the selected variant")
    func seatingFilters() throws {
        let base = Fixture().event
        var commands = SeatingCommands(event: base)
        let variantID = commands.currentEvent.variants[0].id
        let tableID = commands.currentEvent.variant(variantID)!.tables[0].id
        let alice = commands.currentEvent.guests[0].id
        try commands.assign(variantID: variantID, guestID: alice, tableID: tableID, seatNumber: 1)
        let event = commands.currentEvent
        let variant = event.variant(variantID)!

        let seated = GuestRosterQuery.visibleGuests(in: event, variant: variant,
                                                    search: "", filter: .seated)
        let unseated = GuestRosterQuery.visibleGuests(in: event, variant: variant,
                                                      search: "", filter: .unseated)
        let all = GuestRosterQuery.visibleGuests(in: event, variant: variant,
                                                 search: "", filter: .all)
        #expect(seated.map(\.id) == [alice])
        #expect(unseated.count == event.guests.count - 1)
        #expect(!unseated.contains { $0.id == alice })
        #expect(all.count == event.guests.count)
    }

    @Test("Search and filter compose while preserving roster order")
    func composedQuery() throws {
        let (event, variantID) = makeEvent(names: ["Aster", "Basil", "Aspen", "Clove"])
        let variant = event.variant(variantID)!
        let visible = GuestRosterQuery.visibleGuests(in: event, variant: variant,
                                                     search: "AS", filter: .all)
        #expect(visible.map(\.displayName) == ["Aster", "Basil", "Aspen"])
        let none = GuestRosterQuery.visibleGuests(in: event, variant: variant,
                                                  search: "zzz", filter: .all)
        #expect(none.isEmpty)
    }

    @Test("Renaming a guest mid-filter keeps selection identity intact")
    func renameUnderFilterKeepsIdentity() throws {
        let (event, _) = makeEvent(names: ["Aster", "Basil"])
        var commands = SeatingCommands(event: event)
        let aster = event.guests[0].id
        _ = try commands.renameGuest(id: aster, newName: "Zoe")
        // A selection keyed on UUID still resolves after the rename even
        // though the OLD search term no longer matches anyone.
        let stillResolves = commands.currentEvent.guest(aster)
        #expect(stillResolves?.displayName == "Zoe")
        let staleMatches = GuestRosterQuery.visibleGuests(
            in: commands.currentEvent,
            variant: commands.currentEvent.variants[0],
            search: "Aster", filter: .all)
        #expect(staleMatches.isEmpty)
    }
}
