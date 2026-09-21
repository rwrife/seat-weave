import SeatingDomain
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var showBackupSheet = false
    @State private var exporting: ExportKind?
    @State private var showRestorePicker = false
    @State private var showConfirmDeleteEvent = false
    @State private var showConfirmDeleteAll = false

    enum ExportKind: Int, Identifiable {
        case text, pdf, backupJSON
        var id: Int { rawValue }
    }

    var body: some View {
        List {
            Section("Public seating list") {
                Button("Preview shared list") {
                    if let preview = model.exportSelectedPlan() {
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
        .sheet(item: $previewBox) { box in
            ExportPreviewSheet(preview: box.preview) { kind in exporting = kind }
        }
        .sheet(isPresented: $showBackupSheet) {
            BackupSheet {
                showBackupSheet = false
                exporting = .backupJSON
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil },
                                 set: { if !$0 { exporting = nil } }),
            documents: exporterDocuments(),
            contentTypes: exporterContentTypes(),
            defaultFilename: suggestedFilename(),
            onCompletion: { result in
                switch result {
                case .success:
                    model.alertMessage = "Saved. Treat the file with the same care as the app data; the app cannot recall copies outside it."
                case .failure(let error):
                    model.alertMessage = "Export failed: \(error.localizedDescription)"
                }
                exporting = nil
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

    private func suggestedFilename() -> String {
        let base = model.event?.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "seat-weave"
        switch exporting {
        case .pdf: return "\(base)-seating.pdf"
        case .backupJSON: return "\(base)-backup.json"
        default: return "\(base)-seating.txt"
        }
    }

    private func exporterDocuments() -> [SharedFileDocument] {
        switch exporting {
        case .text:
            guard let text = previewBox?.preview.text.data(using: .utf8) else { return [] }
            return [SharedFileDocument(data: text)]
        case .pdf:
            guard let preview = previewBox?.preview else { return [] }
            return [SharedFileDocument(data: SeatingPDFRenderer.render(preview.export))]
        case .backupJSON:
            guard let data = model.fullBackupData() else { return [] }
            return [SharedFileDocument(data: data)]
        case nil:
            return []
        }
    }

    private func exporterContentTypes() -> [UTType] {
        switch exporting {
        case .text: return [.plainText]
        case .pdf: return [.pdf]
        case .backupJSON: return [.json]
        case nil: return []
        }
    }

    private func handleRestorePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls), let url = urls.first else {
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

/// What the host reviews before sharing: the exact shared text, plus the
/// warnings that stay on this screen.
struct ExportPreviewSheet: View {
    let preview: PublicExportPreview
    let onExport: (ShareTab.ExportKind) -> Void
    @Environment(\.dismiss) private var dismiss

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

/// Draws the public export into a paginated PDF. Pagination comes from the
/// domain's `PublicPDFLayout` (unit-tested); this renderer only draws the
/// rows it is given. Compiled by the pinned iOS CI.
enum SeatingPDFRenderer {
    static func render(_ export: PublicSeatingExport) -> Data {
        let pages = PublicPDFLayout.pages(for: export)
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let titleFont = UIFont.systemFont(ofSize: 18, weight: .semibold)
        let headerFont = UIFont.systemFont(ofSize: 12)
        let rowFont = UIFont.systemFont(ofSize: 13)
        return renderer.pdfData { context in
            for (index, rows) in pages.enumerated() {
                context.beginPage()
                var y: CGFloat = 56
                PublicPDFLayout.header(export, page: index + 1, pageCount: pages.count)
                    .draw(at: CGPoint(x: 48, y: y),
                          withAttributes: [.font: headerFont, .foregroundColor: UIColor.darkGray])
                y += 28
                export.eventTitle.draw(at: CGPoint(x: 48, y: y),
                                       withAttributes: [.font: titleFont])
                y += 36
                if rows.isEmpty {
                    "No guests seated yet."
                        .draw(at: CGPoint(x: 48, y: y), withAttributes: [.font: rowFont])
                }
                for row in rows {
                    "\(row.tableLabel) — Seat \(row.seatNumber): \(row.displayName)"
                        .draw(at: CGPoint(x: 48, y: y), withAttributes: [.font: rowFont])
                    y += 22
                }
            }
        }
    }
}
