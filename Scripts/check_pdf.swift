import AppKit
import PDFKit

// Run by pinned macOS CI only. Synthetic fixtures come from the actual app renderer.
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for layout in ["tableOrder", "alphabeticalLookup"] {
    for paper in ["letter", "a4"] {
        let name = "\(layout)-\(paper)"
        let url = folder.appendingPathComponent(name + ".pdf")
        guard let doc = PDFDocument(url: url), doc.pageCount > 1 else {
            fatalError("Missing or single-page PDF: \(name)")
        }
        var contents = ""
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { fatalError("Missing page: \(name)") }
            let bounds = page.bounds(for: .mediaBox)
            let expected = paper == "letter" ? CGSize(width: 612, height: 792) :
                CGSize(width: 595.275590551181, height: 841.8897637795276)
            precondition(abs(bounds.width - expected.width) < 1 && abs(bounds.height - expected.height) < 1,
                         "Wrong paper size: \(name) page \(index + 1)")
            let text = page.string ?? ""
            precondition(text.contains("page \(index + 1) of \(doc.pageCount)"),
                         "Missing repeated page heading: \(name) page \(index + 1)")
            contents += text
            if index == 0 || index == doc.pageCount - 1 {
                let image = page.thumbnail(of: CGSize(width: 1200, height: 1600), for: .mediaBox)
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    fatalError("Cannot render preview: \(name)")
                }
                try png.write(to: folder.appendingPathComponent("\(name)-page\(index + 1).png"), options: .atomic)
            }
        }
        for number in 1...40 {
            let marker = String(format: "SYNTHETIC%02d", number)
            let endMarker = String(format: "END%02d", number)
            precondition(contents.components(separatedBy: marker).count == 2,
                         "Missing/duplicated guest \(marker) in \(name)")
            let pageContainingMarker = (0..<doc.pageCount).first {
                (doc.page(at: $0)?.string ?? "").contains(marker)
            }
            let pageContainingEnd = (0..<doc.pageCount).first {
                (doc.page(at: $0)?.string ?? "").contains(endMarker)
            }
            precondition(contents.components(separatedBy: endMarker).count == 2 &&
                         pageContainingMarker == pageContainingEnd,
                         "Guest \(marker) split across page boundaries in \(name)")
            if layout == "alphabeticalLookup", let index = pageContainingEnd {
                let text = doc.page(at: index)?.string ?? ""
                let suffix = text.components(separatedBy: endMarker)[1]
                    .components(separatedBy: "SYNTHETIC")[0]
                let compact = suffix.filter { !$0.isWhitespace }
                precondition(compact.contains("Round\((number - 1) % 6 + 1),Seat\((number - 1) / 6 + 1)"),
                             "Guest \(marker) table/seat suffix split across pages in \(name)")
            }
        }
        precondition(!contents.localizedCaseInsensitiveContains("preference") &&
                     !contents.localizedCaseInsensitiveContains("unseated") &&
                     !contents.localizedCaseInsensitiveContains("warning"), "Private data in \(name)")
        print("PASS \(name): \(doc.pageCount) pages, 40 unique synthetic guests, page sizes/headings; PNG first/last")
    }
}
let empty = folder.appendingPathComponent("empty.pdf")
precondition(PDFDocument(url: empty)?.page(at: 0)?.string?.contains("No guests seated yet.") == true,
             "Empty plan notice missing")
print("PASS empty plan PDF")
