import SeatingDomain
import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

struct SeatingPDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data {
            view.document = PDFDocument(data: data)
        }
    }  // ponytail: fixed preview snapshot; replace only when its bytes change.
}

/// Sharing and ownership screen (issue #5): the guest-facing public list,
/// the full private backup, validated restore, and confirmed deletion.
///
/// Privacy contract enforced here: the shared list is rendered from
/// `PublicSeatingExport`, which has no field for preferences, unseated
/// guests or IDs; warnings exist only in the host-facing preview section.
/// The full backup is a separate, explicitly-labelled document. Restore
/// validates first, shows a summary, and always imports as a new event.
struct ShareTab: View {
    @Environment(AppModel.self) private var model

    private struct PreviewBox: Identifiable {
        let id = UUID()
        let preview: PublicExportPreview
    }

    @State private var previewBox: PreviewBox?
    @State private var showReview = false
    @State private var showBackupSheet = false
    /// Issue #20: guest-facing lookup layout and paper size, chosen before
    /// preview so what is previewed is exactly what is saved.
    @State private var exportLayout: PublicExportLayout = .tableOrder
    @State private var exportPaperSize: PublicExportPaperSize = .letter
    /// Fully built export waiting for the system save panel. The
    /// single-document `fileExporter` overload is the only one that
    /// supports `defaultFilename` on the iOS 26 SDK, so the document,
    /// content type and filename are prepared together before presenting.
    private struct PendingExport {
        let document: SharedFileDocument
        let contentType: UTType
        let filename: String
    }
    @State private var pendingExport: PendingExport?
    @State private var showRestorePicker = false
    @State private var showConfirmDeleteEvent = false
    @State private var showConfirmDeleteAll = false

    enum ExportKind: Int, Identifiable {
        case text, pdf, backupJSON
        var id: Int { rawValue }
    }

    var body: some View {
        List {
            Section("Ready-to-share review") {
                Button("Review selected plan") { showReview = true }
                    .disabled(model.selectedReview == nil)
                    .accessibilityIdentifier("review-plan-button")
                if let review = model.selectedReview {
                    Text("\(review.unseated.count) unseated · \(review.emptySeats.count) empty seats (informational) · \(review.conflicts.count) conflicts · \(review.unresolved.count) unresolved")
                        .font(.caption)
                        .accessibilityIdentifier("review-summary")
                }
                Text("Review before sharing. You may deliberately share a draft; acknowledgement never changes a preference or the guest-facing file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Public seating list") {
                Picker("Guest-facing layout", selection: $exportLayout) {
                    Text("Table-by-table").tag(PublicExportLayout.tableOrder)
                    Text("Alphabetical guest lookup").tag(PublicExportLayout.alphabeticalLookup)
                }
                .accessibilityIdentifier("export-layout-picker")
                Picker("Paper size", selection: $exportPaperSize) {
                    Text("US Letter").tag(PublicExportPaperSize.letter)
                    Text("A4").tag(PublicExportPaperSize.a4)
                }
                .accessibilityIdentifier("export-paper-size-picker")
                Button("Preview shared list") {
                    if let preview = model.exportSelectedPlan(layout: exportLayout, paperSize: exportPaperSize) {
                        previewBox = PreviewBox(preview: preview)
                    }
                }
                .disabled(model.event == nil || model.selectedVariant == nil)
                .accessibilityIdentifier("export-preview-button")
                Text("Shows only the event title, table and seat labels and seated guest names. Draft and conflict warnings stay on this screen and never enter the shared document.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Private backup") {
                Button("Export full backup…") { showBackupSheet = true }
                    .disabled(model.event == nil)
                    .accessibilityIdentifier("backup-export-button")
                Button("Restore from backup…") { showRestorePicker = true }
                    .accessibilityIdentifier("restore-import-button")
            }
            if let pending = model.pendingRestore {
                Section("Restore ready to import") {
                    Text("Importing '\(pending.summary.title)' — \(pending.summary.guestCount) guest(s), \(pending.summary.preferenceCount) private preference(s), \(pending.summary.variantCount) plan(s).")
                        .accessibilityIdentifier("restore-summary")
                    Text("It becomes a NEW event with fresh identities. Existing events are never merged into or overwritten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Import as new event") { model.commitRestore() }
                        .accessibilityIdentifier("restore-confirm")
                    Button("Discard", role: .cancel) { model.pendingRestore = nil }
                        .accessibilityIdentifier("restore-discard")
                }
            }
            Section("Delete") {
                Button("Delete this event", role: .destructive) { showConfirmDeleteEvent = true }
                    .disabled(model.event == nil)
                    .accessibilityIdentifier("delete-event-button")
                Button("Delete ALL events", role: .destructive) { showConfirmDeleteAll = true }
                    .disabled(model.events.isEmpty)
                    .accessibilityIdentifier("delete-all-button")
                Text("Copies you exported or shared earlier, and any device/OS backup of this data, stay outside the app's control after deletion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showReview) {
            PlanReviewSheet(onNavigate: { showReview = false })
        }
        .sheet(item: $previewBox) { box in
            ExportPreviewSheet(preview: box.preview) { kind in
                // Build the export while the preview still exists, then let
                // the preview sheet go away so the system panel can present.
                startExport(kind)
                previewBox = nil
            }
        }
        .sheet(isPresented: $showBackupSheet) {
            BackupSheet {
                startExport(.backupJSON)
                showBackupSheet = false
            }
        }
        .fileExporter(
            isPresented: Binding(get: { pendingExport != nil },
                                 set: { if !$0 { pendingExport = nil } }),
            document: pendingExport?.document,
            contentType: pendingExport?.contentType ?? .data,
            defaultFilename: pendingExport?.filename ?? "seat-weave",
            onCompletion: { result in
                switch result {
                case .success:
                    model.alertMessage = "Saved. Treat the file with the same care as the app data; the app cannot recall copies outside it."
                case .failure(let error):
                    model.alertMessage = "Export failed: \(error.localizedDescription)"
                }
                pendingExport = nil
            }
        )
        .fileImporter(isPresented: $showRestorePicker,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleRestorePick(result)
        }
        .confirmationDialog("Delete this event? Every plan variant and preference is removed from this device.",
                            isPresented: $showConfirmDeleteEvent, titleVisibility: .visible) {
            Button("Delete event", role: .destructive) {
                if let id = model.event?.id { model.deleteEvent(id: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Exported files and device/OS backups outside the app are not affected and cannot be recalled from here.")
        }
        .confirmationDialog("Delete ALL events? Gatherings, plans and preferences on this device are removed.",
                            isPresented: $showConfirmDeleteAll, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { model.deleteAllEvents() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies already exported or held in device/OS backups remain outside the app's control.")
        }
        .modifier(FailureAlertModifier())
    }

    // MARK: - Exporter plumbing

    /// Builds the requested export NOW (preview/backup data still on hand)
    /// and stages it for the system save panel.
    private func startExport(_ kind: ExportKind) {
        let filename = suggestedFilename(for: kind)
        switch kind {
        case .text:
            guard let text = previewBox?.preview.text.data(using: .utf8) else { return }
            pendingExport = PendingExport(document: SharedFileDocument(data: text),
                                          contentType: .plainText, filename: filename)
        case .pdf:
            guard let preview = previewBox?.preview else { return }
            pendingExport = PendingExport(document: SharedFileDocument(data: SeatingPDFRenderer.render(preview.export)),
                                          contentType: .pdf, filename: filename)
        case .backupJSON:
            guard let data = model.fullBackupData() else { return }
            pendingExport = PendingExport(document: SharedFileDocument(data: data),
                                          contentType: .json, filename: filename)
        }
    }

    private func suggestedFilename(for kind: ExportKind) -> String {
        let base = model.event?.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "seat-weave"
        switch kind {
        case .pdf: return "\(base)-seating.pdf"
        case .backupJSON: return "\(base)-backup.json"
        case .text: return "\(base)-seating.txt"
        }
    }

    private func handleRestorePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result {
                model.alertMessage = "Could not open that file: \(error.localizedDescription)"
            }
            return
        }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        // The size bound is checked on the file attributes BEFORE any bytes
        // are read; the domain layer enforces the same bound again before
        // decoding, so an oversized file is refused twice over.
        guard let data = Self.readCapped(url, maxBytes: SeatingBackup.maximumDocumentBytes) else {
            model.alertMessage = "That file is unreadable or larger than the 2 MiB restore limit."
            return
        }
        model.validateRestore(data)
    }

    /// Reads at most `maxBytes` from the URL. Returns nil when the file is
    /// larger than the cap (without reading it) or unreadable.
    private static func readCapped(_ url: URL, maxBytes: Int) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// A host-only, actionable review. No review detail or acknowledgement is
/// embedded in the public PDF/text; the export builder takes only the event
/// and selected variant and has no acknowledgement parameter.
struct PlanReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onNavigate: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let review = model.selectedReview {
                    Section("Unseated guests (\(review.unseated.count))") {
                        if review.unseated.isEmpty { Text("All guests seated.") }
                        ForEach(review.unseated, id: \.id) { guest in
                            Button("Seat \(guest.displayName) — open guest") {
                                model.showGuestFromReview(guest.id)
                                onNavigate()
                            }
                            .accessibilityIdentifier("review-unseated-\(guest.id.uuidString)")
                        }
                    }
                    Section("Empty seats (\(review.emptySeats.count)) — informational") {
                        if review.emptySeats.isEmpty { Text("No empty seats.") }
                        ForEach(review.emptySeats, id: \.self) { seat in
                            Button("\(seat.tableLabel), seat \(seat.number) — open table") {
                                model.showTableFromReview(seat.tableID)
                                onNavigate()
                            }
                            .accessibilityIdentifier("review-empty-\(seat.tableID.uuidString)-\(seat.number)")
                        }
                    }
                    Section("Conflicting preferences (\(review.conflicts.count))") {
                        if review.conflicts.isEmpty { Text("No conflicts.") }
                        ForEach(review.conflicts, id: \.preferenceID) { evaluation in
                            Button("Inspect conflict: \(evaluation.reason)") {
                                model.showPreferenceFromReview(evaluation.preferenceID)
                                onNavigate()
                            }
                            .accessibilityIdentifier("review-conflict-\(evaluation.preferenceID.uuidString)")
                            if review.acknowledgedPreferenceIDs.contains(evaluation.preferenceID) {
                                Text("Intentional conflict acknowledged; the preference is still conflicting.")
                                    .font(.caption)
                                Button("Revisit this conflict") {
                                    model.revisitConflict(preferenceID: evaluation.preferenceID)
                                }
                                .accessibilityIdentifier("review-revisit-\(evaluation.preferenceID.uuidString)")
                            } else {
                                Button("Acknowledge intentional conflict") {
                                    model.acknowledgeConflict(preferenceID: evaluation.preferenceID)
                                }
                                .accessibilityIdentifier("review-ack-\(evaluation.preferenceID.uuidString)")
                            }
                        }
                    }
                    Section("Unresolved preferences (\(review.unresolved.count))") {
                        if review.unresolved.isEmpty { Text("None unresolved.") }
                        ForEach(review.unresolved, id: \.preferenceID) { evaluation in
                            Button("Inspect unresolved: \(evaluation.reason)") {
                                model.showPreferenceFromReview(evaluation.preferenceID)
                                onNavigate()
                            }
                            .accessibilityIdentifier("review-unresolved-\(evaluation.preferenceID.uuidString)")
                        }
                    }
                    Section("Sharing decision") {
                        Text("\(review.unacknowledgedConflicts) conflict(s) not acknowledged. Unseated guests and unresolved preferences stay outstanding even if a conflict is acknowledged. Empty seats alone do not block sharing.")
                            .accessibilityIdentifier("review-decision")
                        Text("You may share this intentional draft. Close this review and choose Preview shared list to inspect exactly what guests will see; private notes remain here.")
                            .font(.caption)
                        Button("Return to sharing") { dismiss() }
                            .accessibilityIdentifier("review-return-to-share")
                    }
                }
            }
            .navigationTitle("Plan review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// What the host reviews before sharing: the exact shared text, plus the
/// warnings that stay on this screen.
struct ExportPreviewSheet: View {
    let preview: PublicExportPreview
    let onExport: (ShareTab.ExportKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showPDF = false

    var body: some View {
        NavigationStack {
            List {
                Section("Shared list (what others will see)") {
                    Text(preview.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("export-text")
                }
                if !preview.warnings.isEmpty {
                    Section("Before you share") {
                        ForEach(preview.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .accessibilityIdentifier("export-warning")
                        }
                    }
                }
                Section {
                    Button("Preview PDF") { showPDF = true }
                        .accessibilityIdentifier("export-preview-pdf")
                    Button("Save as text…") { onExport(.text) }
                        .accessibilityIdentifier("export-save-text")
                    Button("Save as PDF…") { onExport(.pdf) }
                        .accessibilityIdentifier("export-save-pdf")
                }
            }
            .navigationTitle("Shared list")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("close-export-preview")
                }
            }
            .sheet(isPresented: $showPDF) {
                NavigationStack {
                    SeatingPDFPreview(data: SeatingPDFRenderer.render(preview.export))
                        .navigationTitle("PDF preview")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showPDF = false }
                                    .accessibilityIdentifier("close-pdf-preview")
                            }
                        }
                }
            }
        }
    }
}

/// The full backup carries private preferences; the sheet says so before
/// the system save panel ever appears.
struct BackupSheet: View {
    let onExport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Label("Private backup", systemImage: "lock.doc")
                .font(.headline)
            Text("The backup file is the complete event: guests, all plan variants AND private pair preferences. Only save or share it where you would keep the original notes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("backup-privacy-warning")
            Button("Choose where to save…", action: onExport)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("backup-choose-location")
            Button("Cancel", role: .cancel) { dismiss() }
        }
        .padding(24)
    }
}

// MARK: - FileDocument wrapper for the system export panel

/// One concrete document type carries every export flavor (text, PDF,
/// backup JSON); the caller passes the matching content type to the
/// exporter. Existential `[FileDocument]` arrays cannot satisfy the
/// generic `fileExporter` constraint, hence the single concrete type.
struct SharedFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .pdf, .json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// UIKit measures grapheme-wrapped rows in points, then paginates the same
/// lines it draws. Domain row ordering/formatting is tested separately;
/// actual PDF geometry and content require the native simulator gate.
enum SeatingPDFRenderer {
    #if DEBUG
    /// Synthetic-only native fixture producer; never reads the host's event.
    static func writeTestFixtures() throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("export-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for paper in PublicExportPaperSize.allCases {
            for layout in PublicExportLayout.allCases {
                let rows = (1...40).map {
                    PublicSeatingExport.Row(tableLabel: "Round \(($0 - 1) % 6 + 1)",
                        seatNumber: ($0 - 1) / 6 + 1,
                        displayName: String(format: "SYNTHETIC%02d", $0) + " " +
                            String(repeating: "Long Unicode Zoë Nguyễn 李 👩🏽‍💻 ", count: 5))
                }
                let export = PublicSeatingExport(eventTitle: "Synthetic print verification",
                    planName: "Selected plan", layout: layout, paperSize: paper, rows: rows)
                try render(export).write(to: folder.appendingPathComponent("\(layout.rawValue)-\(paper.rawValue).pdf"),
                                         options: .atomic)
            }
        }
        try render(PublicSeatingExport(eventTitle: "Empty synthetic event", planName: "Empty", rows: []))
            .write(to: folder.appendingPathComponent("empty.pdf"), options: .atomic)
    }
    #endif

    static func render(_ export: PublicSeatingExport) -> Data {
        let size = export.paperSize.dimensionsInPoints
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let margin: CGFloat = 48
        let width = bounds.width - 2 * margin
        let lineHeight: CGFloat = 19
        let rowFont = UIFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: rowFont]
        // Break by grapheme, not UTF-16 index: no clipped long names or
        // split combining marks. The same measured lines drive pagination.
        func lines(_ text: String) -> [String] {
            var result: [String] = []
            var line = ""
            for character in text {
                let candidate = line + String(character)
                if !line.isEmpty && (candidate as NSString).size(withAttributes: attributes).width > width {
                    result.append(line)
                    line = String(character)
                } else {
                    line = candidate
                }
            }
            result.append(line)
            return result
        }
        // Reserve identical header/title space on every page. Titles are
        // truncated in the heading only; every guest row remains complete.
        let available = bounds.height - 2 * margin - 70
        let capacity = max(1, Int(available / lineHeight))
        let allLines = (export.rows.isEmpty ? ["No guests seated yet."] :
            export.rows.flatMap { lines(PublicPDFLayout.line(for: $0, layout: export.layout)) })
        let pages = stride(from: 0, to: allLines.count, by: capacity).map {
            Array(allLines[$0..<min($0 + capacity, allLines.count)])
        }
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            for (index, page) in pages.enumerated() {
                context.beginPage()
                let heading = PublicPDFLayout.header(export, page: index + 1, pageCount: pages.count)
                (heading as NSString).draw(in: CGRect(x: margin, y: margin, width: width, height: 20),
                                           withAttributes: [.font: UIFont.systemFont(ofSize: 11),
                                                            .foregroundColor: UIColor.darkGray])
                ((export.eventTitle + " — " + export.planName) as NSString)
                    .draw(in: CGRect(x: margin, y: margin + 25, width: width, height: 29),
                          withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .semibold)])
                for (offset, line) in page.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: margin, y: margin + 70 + CGFloat(offset) * lineHeight),
                                            withAttributes: attributes)
                }
            }
        }
    }
}
