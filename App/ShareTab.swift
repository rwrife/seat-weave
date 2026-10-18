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
    @State private var showReview = false
    @State private var showBackupSheet = false
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
    @State private var showRecoverySheet = false
    /// Event awaiting the permanent-delete confirmation (issue #16).
    @State private var permanentDeleteTarget: EventStore.DeletedEvent?

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
            Section("Automatic local recovery") {
                Button("Browse recovery points…") {
                    model.loadRecoveryPoints()
                    showRecoverySheet = true
                }
                .disabled(model.event == nil)
                .accessibilityIdentifier("recovery-browse-button")
                Text("Every successful edit saves a private, versioned recovery point on this device; up to 10 per event for 14 days. Recovery contains guest names and pair preferences. It is never included in public exports. If storage is unavailable, save fails visibly and prior points remain untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Delete") {
                Button("Delete this event", role: .destructive) { showConfirmDeleteEvent = true }
                    .disabled(model.event == nil)
                    .accessibilityIdentifier("delete-event-button")
                Button("Delete ALL events", role: .destructive) { showConfirmDeleteAll = true }
                    .disabled(model.events.isEmpty && model.recentlyDeleted.isEmpty)
                    .accessibilityIdentifier("delete-all-button")
                Text("Ordinary deletion moves this event into Recently Deleted for 14 days. Permanent deletion and Delete ALL remove local recovery points and recently-deleted copies. Files already exported or held in device/OS backups remain outside the app's control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.recentlyDeleted.isEmpty {
                Section("Recently Deleted — 14 days") {
                    ForEach(model.recentlyDeleted) { deleted in
                        VStack(alignment: .leading) {
                            Text(deleted.title)
                            Text("Deleted \(deleted.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Recover \(deleted.title)") { model.restoreDeleted(id: deleted.id) }
                                    .accessibilityIdentifier("recover-deleted-\(deleted.id.uuidString)")
                                Button("Delete \(deleted.title) permanently", role: .destructive) {
                                    permanentDeleteTarget = deleted
                                }
                                .accessibilityIdentifier("permanent-delete-\(deleted.id.uuidString)")
                            }
                        }
                    }
                }
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
        .sheet(isPresented: $showRecoverySheet) {
            RecoveryPointsSheet()
        }
        .confirmationDialog("Delete '\(permanentDeleteTarget?.title ?? "")' permanently?",
                            isPresented: Binding(get: { permanentDeleteTarget != nil },
                                                 set: { if !$0 { permanentDeleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                if let target = permanentDeleteTarget {
                    model.deletePermanently(id: target.id)
                    permanentDeleteTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { permanentDeleteTarget = nil }
        } message: {
            Text("Removes the event, its automatic recovery points and this recently-deleted copy from this device. Nothing local can be recovered afterwards.")
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
        .confirmationDialog("Delete this event? It moves to Recently Deleted for 14 days.",
                            isPresented: $showConfirmDeleteEvent, titleVisibility: .visible) {
            Button("Delete event", role: .destructive) {
                if let id = model.event?.id { model.deleteEvent(id: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Automatic recovery snapshots and recently-deleted copies can restore it during the 14-day recovery period. Files you exported earlier stay outside the app's control.")
        }
        .confirmationDialog("Delete ALL events and all recovery points? This is permanent.",
                            isPresented: $showConfirmDeleteAll, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { model.deleteAllEvents() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all active events, all recently-deleted events and all automatic recovery snapshots from this device. Nothing local can be recovered afterwards.")
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

// MARK: - Recovery points browser (issue #16)

/// Host-only list of the open event's automatic snapshots with timestamps
/// and counts. Preview validates the stored document WITHOUT writing;
/// restore always creates a NEW event and never overwrites the current one.
struct RecoveryPointsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Automatic recovery points") {
                    if model.recoveryPoints.isEmpty {
                        Text("No recovery points yet. They appear after the first saved edit.")
                    }
                    ForEach(model.recoveryPoints) { point in
                        VStack(alignment: .leading) {
                            Text(point.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text("\(point.guestCount) guest(s) · \(point.preferenceCount) private preference(s) · \(point.variantCount) plan(s)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Preview \(point.createdAt.formatted(date: .omitted, time: .standard))") {
                                    model.previewRecoveryPoint(point)
                                }
                                .accessibilityIdentifier("recovery-preview-\(point.id.uuidString)")
                            }
                        }
                    }
                }
                if let pending = model.pendingRecovery {
                    Section("Recovery preview") {
                        Text("Restore '\(pending.summary.title)' from \(pending.createdAt.formatted(date: .abbreviated, time: .shortened)) — \(pending.summary.guestCount) guest(s), \(pending.summary.preferenceCount) private preference(s), \(pending.summary.variantCount) plan(s).")
                            .accessibilityIdentifier("recovery-preview-summary")
                        Text("It becomes a NEW event with fresh identities. The current event is never overwritten.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Restore as new event") { model.restoreRecoveryPoint() }
                            .accessibilityIdentifier("recovery-restore-confirm")
                        Button("Discard", role: .cancel) { model.pendingRecovery = nil }
                            .accessibilityIdentifier("recovery-preview-discard")
                    }
                }
            }
            .navigationTitle("Recovery points")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("close-recovery-sheet")
                }
            }
        }
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
