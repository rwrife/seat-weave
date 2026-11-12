import Testing
@testable import SeatingDomain

struct PDFPaginationTests {
    @Test("Wrapped guest rows stay intact at the page boundary")
    func intactRows() {
        let rows = (1...40).map { ["guest\($0)", "name\($0)", "seat\($0)"] }
        let pages = PublicPDFLayout.paginateLines(rows, capacity: 35)
        #expect(pages.map(\.count) == [33, 33, 33, 21])
        #expect(pages.flatMap { $0 } == rows.flatMap { $0 })
        for row in rows {
            #expect(pages.filter { $0.contains(row[0]) && $0.contains(row[2]) }.count == 1)
        }
    }

    @Test("Exact fills, empty input and oversized rows preserve all lines")
    func boundaries() {
        #expect(PublicPDFLayout.paginateLines([], capacity: 3) == [[]])
        #expect(PublicPDFLayout.paginateLines([[], ["a", "b", "c"], ["d"]], capacity: 3)
                == [["a", "b", "c"], ["d"]])
        #expect(PublicPDFLayout.paginateLines([["a"], ["b", "c", "d", "e"], ["f"]], capacity: 3)
                == [["a"], ["b", "c", "d"], ["e", "f"]])
    }
}
