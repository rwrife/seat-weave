import Foundation
import Observation
import SeatingDomain

/// Thread-safe save boundary wrapping the SwiftData store so the
/// controller can persist from MainActor code under Swift 6 rules.
final class StoreSaver: EventSaving, @unchecked Sendable {
    private let store: EventStore
    private let lock = NSLock()

    init(store: EventStore) { self.store = store }

    func save(_ event: SeatingEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.save(event)
    }
}

/// App-wide state: the local store, the currently open event and the
/// selected plan variant. Selection survives relaunch so the host reopens
/// into the same plan; undo stays session-local by design. Views touch
/// this class from the main actor only; no cross-thread handoff happens.
@Observable
final class AppModel {
    static let lastEventKey = "seatweave.lastEventID"
    static func lastVariantKey(eventID: UUID) -> String {
        "seatweave.lastVariantID.\(eventID.uuidString)"
    }
    /// XCTest launch flag: `-resetStore` maps to this argument-domain key.
    static let resetStoreKey = "resetStore"
    /// XCTest launch flag: `-layoutToggle` shows the workspace-region
    /// override switch. Normal launches never render it.
    static let layoutToggleKey = "layoutToggle"

    private(set) var events: [SeatingEvent] = []
    private(set) var controller: PersistentSeatingController?
    var alertMessage: String?
    var selectedVariantID: UUID?
    /// Selected guest lives in app state (not view state) so switching
    /// between the compact Guests/Tables tabs cannot lose the selection.
    var selectedGuestID: UUID?
    /// Roster search text and seating filter (issue #17) also live in app
    /// state: moving between Guests and Tables — or across width changes —
    /// must not silently reset what the host is looking for.
    var rosterSearch: String = ""
    var rosterFilter: GuestRosterQuery.Filter = .all
    /// Focused table belongs to app state too (PLAN.md): width or
    /// orientation changes and region switches must not reset it, and
    /// resizing never mutates assignments or focus.
    var focusedTableID: UUID?
    /// UI-test-only workspace-region override. `.auto` follows the
    /// environment's horizontal size class through `SeatingWorkspaceLayout`.
    var layoutOverride: WorkspaceLayoutOverride = .auto

    private let store: EventStore?
    private let defaults: UserDefaults

    var event: SeatingEvent? { controller?.currentEvent }
    var canUndo: Bool { controller?.canUndo ?? false }

    /// A validated backup waiting for the host's explicit import (issue #5).
    struct PendingRestore {
        let event: SeatingEvent
        let summary: SeatingBackup.RestoreSummary
    }
    var pendingRestore: PendingRestore?

    var selectedVariant: PlanVariant? {
        guard let event, let selectedVariantID else { return nil }
        return event.variant(selectedVariantID)
    }

    /// True when UI tests request a clean store for the launch.
    static var resetStoreRequested: Bool {
        UserDefaults.standard.bool(forKey: resetStoreKey)
    }

    /// Captured at init: whether THIS launch may show the workspace-region
    /// override switch (launch flag `-layoutToggle YES`).
    let layoutToggleEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.layoutToggleEnabled = defaults.bool(forKey: AppModel.layoutToggleKey)
        if AppModel.resetStoreRequested {
            AppModel.wipeStoreDirectory()
            defaults.removeObject(forKey: AppModel.lastEventKey)
            // Launch-argument values can persist in the app domain; clear
            // so a subsequent launch without the flag does not wipe again.
            defaults.removeObject(forKey: AppModel.resetStoreKey)
            defaults.synchronize()
        }
        // Same persistence hazard for the region toggle: tests that want it
        // pass -layoutToggle YES on every launch; a stale value must not
        // leak into later launches (or user runs).
        if layoutToggleEnabled {
            defaults.removeObject(forKey: AppModel.layoutToggleKey)
            defaults.synchronize()
        }
        self.store = AppModel.makeStore()
        refreshEventList()
    }

    private static func storeDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeatWeaveStore", isDirectory: true)
    }

    private static func wipeStoreDirectory() {
        try? FileManager.default.removeItem(at: storeDirectory())
    }

    private static func makeStore() -> EventStore? {
        try? EventStore.makeFileStore(directory: storeDirectory())
    }

    // MARK: - Event list

    func refreshEventList() {
        do {
            events = try store.map { try $0.allEvents() } ?? []
        } catch {
            events = []
            alertMessage = "Stored events could not be read: \(error.localizedDescription)"
        }
    }

    /// Creates an event with one starter variant and returns its ID.
    func createEvent(title: String) -> UUID? {
        guard let store else {
            alertMessage = "Local storage is unavailable."
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = "Event title cannot be empty."
            return nil
        }
        let event = SeatingEvent(title: trimmed, variants: [PlanVariant(name: "Plan A")])
        do {
            try store.save(event)
        } catch {
            alertMessage = "Saving failed: \(error.localizedDescription)"
            return nil
        }
        refreshEventList()
        return event.id
    }

    // MARK: - Open event / plan selection

    /// Reopens the event saved before relaunch, if it still exists.
    func launchEventID() -> UUID? {
        guard let raw = defaults.string(forKey: AppModel.lastEventKey),
              let id = UUID(uuidString: raw),
              events.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func open(eventID: UUID) {
        guard let store else {
            alertMessage = "Local storage is unavailable."
            return
        }
        do {
            guard let event = try store.load(eventID: eventID) else {
                alertMessage = "That event is no longer stored."
                return
            }
            controller = PersistentSeatingController(event: event, saver: StoreSaver(store: store))
            let remembered = defaults.string(forKey: AppModel.lastVariantKey(eventID: eventID))
                .flatMap(UUID.init(uuidString:))
            if let remembered, event.variant(remembered) != nil {
                selectedVariantID = remembered
            } else {
                selectedVariantID = event.variants.first?.id
            }
            defaults.set(eventID.uuidString, forKey: AppModel.lastEventKey)
            defaults.synchronize()
        } catch {
            alertMessage = "Opening failed: \(error.localizedDescription)"
        }
    }

    func closeEvent() {
        controller = nil
        selectedVariantID = nil
        selectedGuestID = nil
        focusedTableID = nil
        layoutOverride = .auto
        refreshEventList()
    }

    func select(variantID: UUID) {
        guard event?.variant(variantID) != nil else { return }
        selectedVariantID = variantID
        if let eventID = event?.id {
            defaults.set(variantID.uuidString, forKey: AppModel.lastVariantKey(eventID: eventID))
            // Flush so a test terminate()/termination cannot drop the
            // selection the relaunch gate depends on.
            defaults.synchronize()
        }
    }

    // MARK: - Commands

    /// Runs one controller mutation; failures surface as an alert and the
    /// previously saved state stays visible and current.
    func perform(_ mutation: (inout PersistentSeatingController) throws -> Void) {
        guard var controller else {
            alertMessage = "No event is open."
            return
        }
        do {
            try mutation(&controller)
            self.controller = controller
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func undo() {
        guard var controller else { return }
        do {
            try controller.undo()
            self.controller = controller
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Backup, export, restore and deletion (issue #5)

    /// Preview of the guest-facing list for the currently selected plan.
    /// Nil (plus an alert) when the selection is missing or broken; the
    /// returned warnings never enter the shared text.
    func exportSelectedPlan() -> PublicExportPreview? {
        guard let event, let selectedVariantID else {
            alertMessage = "No plan selected"
            return nil
        }
        do {
            return try PublicExportBuilder.preview(event: event, variantID: selectedVariantID)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    /// Full private backup of the open event. The UI must present the
    /// privacy warning (BackupSheet) before offering this data.
    func fullBackupData() -> Data? {
        guard let event else {
            alertMessage = "No event is open."
            return nil
        }
        do {
            return try SeatingBackup.encodeBackup(of: event)
        } catch {
            alertMessage = "Backup failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Validates a picked backup WITHOUT touching the store. On success it
    /// only stages `pendingRestore`; nothing is written until commitRestore.
    func validateRestore(_ data: Data) {
        do {
            let (event, summary) = try SeatingBackup.decodeBackup(data)
            pendingRestore = PendingRestore(event: event, summary: summary)
        } catch {
            pendingRestore = nil
            alertMessage = "Import rejected: \(error.localizedDescription)"
        }
    }

    /// Writes the staged backup as a brand-new event. Never merges with or
    /// overwrites an existing event; failures leave the store untouched.
    func commitRestore() {
        guard let store, let pending = pendingRestore else { return }
        do {
            try store.save(pending.event)
            pendingRestore = nil
            refreshEventList()
            alertMessage = "Imported '\(pending.summary.title)' as a new event."
        } catch {
            alertMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Deletes one event after UI confirmation. An open controller on that
    /// event is closed first; the remembered-launch keys are cleared.
    func deleteEvent(id: UUID) {
        guard let store else {
            alertMessage = "Local storage is unavailable."
            return
        }
        if event?.id == id { closeEvent() }
        do {
            try store.delete(eventID: id)
            clearLaunchKeys(eventID: id)
            refreshEventList()
        } catch {
            alertMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Deletes every stored event after UI confirmation.
    func deleteAllEvents() {
        guard let store else {
            alertMessage = "Local storage is unavailable."
            return
        }
        closeEvent()
        do {
            try store.deleteAll()
            defaults.removeObject(forKey: AppModel.lastEventKey)
            defaults.synchronize()
            refreshEventList()
        } catch {
            alertMessage = "Delete-all failed: \(error.localizedDescription)"
        }
    }

    private func clearLaunchKeys(eventID: UUID) {
        if defaults.string(forKey: AppModel.lastEventKey) == eventID.uuidString {
            defaults.removeObject(forKey: AppModel.lastEventKey)
        }
        defaults.removeObject(forKey: AppModel.lastVariantKey(eventID: eventID))
        defaults.synchronize()
    }

    // MARK: - Derived summaries (compact workspace banner and comparison)

    typealias VariantSummary = SeatingDomain.VariantSummary

    func summary(of variant: PlanVariant, in event: SeatingEvent) -> VariantSummary {
        VariantReporter.summarize(event: event, variant: variant)
    }

    func allVariantSummaries() -> [VariantSummary] {
        guard let event else { return [] }
        return event.variants.map { summary(of: $0, in: event) }
    }

    var bannerText: String {
        guard let event, let variant = selectedVariant else { return "No plan selected" }
        let s = summary(of: variant, in: event)
        return "\(s.seated) seated of \(event.guests.count) guests · \(s.conflicts) conflicts · \(s.unresolved) unresolved"
    }

    func seatLabel(for guestID: UUID) -> String {
        guard let variant = selectedVariant, let seat = variant.seat(for: guestID),
              let table = variant.table(seat.tableID) else { return "Unseated" }
        return "\(table.label) · seat \(seat.seatNumber)"
    }
}
