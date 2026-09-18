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

    private(set) var events: [SeatingEvent] = []
    private(set) var controller: PersistentSeatingController?
    var alertMessage: String?
    var selectedVariantID: UUID?
    /// Selected guest lives in app state (not view state) so switching
    /// between the compact Guests/Tables tabs cannot lose the selection.
    var selectedGuestID: UUID?

    private let store: EventStore?
    private let defaults: UserDefaults

    var event: SeatingEvent? { controller?.currentEvent }
    var canUndo: Bool { controller?.canUndo ?? false }

    var selectedVariant: PlanVariant? {
        guard let event, let selectedVariantID else { return nil }
        return event.variant(selectedVariantID)
    }

    /// True when UI tests request a clean store for the launch.
    static var resetStoreRequested: Bool {
        UserDefaults.standard.bool(forKey: resetStoreKey)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if AppModel.resetStoreRequested {
            AppModel.wipeStoreDirectory()
            defaults.removeObject(forKey: AppModel.lastEventKey)
            // Launch-argument values can persist in the app domain; clear
            // so a subsequent launch without the flag does not wipe again.
            defaults.removeObject(forKey: AppModel.resetStoreKey)
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
