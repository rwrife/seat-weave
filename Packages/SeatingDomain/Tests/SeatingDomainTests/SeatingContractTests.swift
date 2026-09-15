import Foundation
import Testing
@testable import SeatingDomain

@Suite("Issue 1 domain contract")
struct SeatingContractTests {
    @Test("Published MVP bounds remain coherent")
    func limitsAreCoherent() {
        #expect(SeatingLimits.maximumGuestsPerEvent == 40)
        #expect(SeatingLimits.maximumTablesPerVariant == 6)
        #expect(SeatingLimits.minimumSeatsPerTable == 2)
        #expect(SeatingLimits.maximumSeatsPerTable == 12)
        #expect(SeatingLimits.maximumVariantsPerEvent == 10)
        #expect(SeatingLimits.minimumSeatsPerTable < SeatingLimits.maximumSeatsPerTable)
    }

    @Test("Duplicate display names do not collapse identity")
    func duplicateNamesRetainDistinctIdentity() {
        let first = GuestIdentity(id: UUID(), displayName: "Guest")
        let second = GuestIdentity(id: UUID(), displayName: "Guest")

        #expect(first.displayName == second.displayName)
        #expect(first.id != second.id)
        #expect(first != second)
    }

    @Test("Editing a display name does not change identity")
    func editableNameIsNotIdentity() {
        let id = UUID()
        let before = GuestIdentity(id: id, displayName: "Before")
        let after = GuestIdentity(id: id, displayName: "After")

        #expect(before == after)
        #expect(before.hashValue == after.hashValue)
    }

    @Test("The preference vocabulary has exactly the planned three kinds")
    func preferenceVocabularyIsBounded() {
        #expect(Set(PairPreferenceKind.allCases) == [.sameTable, .differentTables, .adjacent])
    }
}
