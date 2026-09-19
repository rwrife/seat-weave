import SeatingDomain
import SwiftUI

/// Compact-phone seating workspace per the README: compact widths
/// *navigate* between guests and seats instead of one endless list.
/// The guest selection and plan choice live in `AppModel`, so switching
/// screens cannot lose context. Every operation is a plain tap on a list,
/// tab or toolbar control; nothing depends on dragging.
struct SeatingWorkspaceView: View {
    @Environment(AppModel.self) private var model

    struct SwapRequest: Identifiable {
        let id = UUID()
        let movingGuestID: UUID
        let occupantGuestID: UUID
        let tableID: UUID
        let targetSeat: Int
    }

    struct DeletionTarget: Identifiable {
        let id: UUID
        let preview: SeatingCommands.GuestDeletionPreview
    }

    var body: some View {
        TabView {
            GuestsTab()
                .tabItem { Label("Guests", systemImage: "person.2") }
            TablesTab()
                .tabItem { Label("Tables", systemImage: "circle.grid.circle") }
            PairsTab()
                .tabItem { Label("Pairs", systemImage: "heart.text.square") }
            PlansTab()
                .tabItem { Label("Plans", systemImage: "square.on.square.dashed") }
        }
    }
}

/// Status rows repeated on every tab so the banner, selected plan and
/// session controls read identically from any screen. Undo/Close live in
/// the first visible section instead of a toolbar: toolbar items do not
/// reliably merge through a TabView, and visible buttons work for VoiceOver,
/// Switch Control and XCUITest alike.
struct WorkspaceStatusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(model.bannerText)
            .font(.callout.weight(.semibold))
            .accessibilityIdentifier("seating.summary")
        Text("Plan: \(model.selectedVariant?.name ?? "none")")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("selected-plan")
        HStack(spacing: 12) {
            Button("Undo") { model.undo() }
                .disabled(!model.canUndo)
                .accessibilityIdentifier("undo-button")
            Button("Close event") { model.closeEvent() }
                .accessibilityIdentifier("close-event-button")
        }
    }
}

/// Roster screen: alias-capable guest list, selection controls and
/// previewed destructive deletion.
struct GuestsTab: View {
    @Environment(AppModel.self) private var model
    @State private var deletionTarget: SeatingWorkspaceView.DeletionTarget?

    var body: some View {
        List {
            Section { WorkspaceStatusSection() }
            if let event = model.event {
                Section("Selected guest") {
                    if let guestID = model.selectedGuestID, let guest = event.guest(guestID) {
                        Text("\(guest.displayName) — \(model.seatLabel(for: guestID))")
                            .accessibilityIdentifier("selection.current")
                        Button("Unseat") { unseat(guestID: guestID) }
                            .accessibilityIdentifier("unseat-button")
                        Button("Delete guest") { showDeletionSheet(guestID: guestID) }
                            .accessibilityIdentifier("delete-guest-button")
                        Button("Clear selection") { model.selectedGuestID = nil }
                            .accessibilityIdentifier("clear-selection-button")
                    } else {
                        Text("Tap a guest to select, then choose a seat on Tables.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Guests") {
                    ForEach(event.guests, id: \.self) { guest in
                        rosterRow(guest: guest)
                    }
                    if event.guests.isEmpty {
                        Text("No guests yet. Add the first one below.")
                            .foregroundStyle(.secondary)
                    }
                    AddGuestRow()
                }
            }
        }
        .sheet(item: $deletionTarget) { target in
            DeleteGuestSheet(target: target) {
                if model.selectedGuestID == target.id { model.selectedGuestID = nil }
                deletionTarget = nil
            }
        }
        .modifier(FailureAlertModifier())
    }

    @ViewBuilder
    private func rosterRow(guest: GuestIdentity) -> some View {
        let seatLabel = model.seatLabel(for: guest.id)
        Button {
            model.selectedGuestID = guest.id
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(guest.displayName)
                    Text(seatLabel)
                        .font(.caption)
                        .foregroundStyle(seatLabel == "Unseated" ? .secondary : .primary)
                }
                Spacer()
                if model.selectedGuestID == guest.id {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("roster-\(guest.displayName)")
        .accessibilityLabel("\(guest.displayName), \(seatLabel)")
    }

    private func unseat(guestID: UUID) {
        guard let variantID = model.selectedVariantID else { return }
        model.perform { controller in
            try controller.perform { commands in
                try commands.unseat(variantID: variantID, guestID: guestID)
            }
        }
        if model.alertMessage == nil { model.selectedGuestID = nil }
    }

    private func showDeletionSheet(guestID: UUID) {
        do {
            guard let preview = try model.controller?.guestDeletionPreview(guestID: guestID) else { return }
            deletionTarget = SeatingWorkspaceView.DeletionTarget(id: guestID, preview: preview)
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }
}

/// Table screen: per-table seat lists with selection-driven assign/move,
/// confirmed occupied-seat swaps, resize-behind-preview and table adding.
struct TablesTab: View {
    @Environment(AppModel.self) private var model
    @State private var pendingSwap: SeatingWorkspaceView.SwapRequest?
    @State private var pendingResizeTableID: UUID?
    @State private var showAddTable = false

    var body: some View {
        List {
            Section { WorkspaceStatusSection() }
            if let event = model.event, let variant = model.selectedVariant {
                if model.selectedGuestID != nil {
                    Section {
                        Text("Selected: \(event.guest(model.selectedGuestID!)?.displayName ?? "?") — \(model.seatLabel(for: model.selectedGuestID!)). Tap a seat below.")
                            .font(.subheadline)
                            .accessibilityIdentifier("tables.selection-hint")
                    }
                }
                ForEach(variant.tables) { table in
                    Section(table.label) {
                        ForEach(1...table.seatCount, id: \.self) { seatNumber in
                            seatRow(table: table, seatNumber: seatNumber, variant: variant, event: event)
                        }
                        Button("Resize \(table.label)") {
                            pendingResizeTableID = table.id
                        }
                        .accessibilityIdentifier("resize-\(table.label)")
                    }
                }
                Section {
                    Button("Add table") { showAddTable = true }
                        .accessibilityIdentifier("add-table-button")
                }
            }
        }
        .sheet(isPresented: $showAddTable) { AddTableSheet() }
        .sheet(item: $pendingSwap) { request in
            SwapConfirmationSheet(request: request) { pendingSwap = nil }
        }
        .sheet(item: Binding(
            get: { pendingResizeTableID.map { ResizeBox(tableID: $0) } },
            set: { pendingResizeTableID = $0?.tableID }
        )) { box in
            ResizePlanSheet(tableID: box.tableID) { pendingResizeTableID = nil }
        }
        .modifier(FailureAlertModifier())
    }

    private struct ResizeBox: Identifiable {
        let tableID: UUID
        var id: UUID { tableID }
    }

    @ViewBuilder
    private func seatRow(table: SeatingTable, seatNumber: Int, variant: PlanVariant, event: SeatingEvent) -> some View {
        let occupantID = variant.occupant(tableID: table.id, seatNumber: seatNumber)
        let occupant = occupantID.flatMap { event.guest($0) }
        let text = "Seat \(seatNumber): \(occupant?.displayName ?? "Unseated")"
        Button {
            seatTapped(table: table, seatNumber: seatNumber, variant: variant)
        } label: {
            HStack {
                Text(text)
                Spacer()
                if let selectedGuestID = model.selectedGuestID,
                   let seat = variant.seat(for: selectedGuestID),
                   seat.tableID == table.id, seat.seatNumber == seatNumber {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("seat-\(table.label)-\(seatNumber)")
        .accessibilityLabel(text)
    }

    private func seatTapped(table: SeatingTable, seatNumber: Int, variant: PlanVariant) {
        guard let variantID = model.selectedVariantID else { return }
        let occupantID = variant.occupant(tableID: table.id, seatNumber: seatNumber)
        guard let guestID = model.selectedGuestID else {
            // No selection: tapping an occupied seat picks up its guest.
            model.selectedGuestID = occupantID
            return
        }
        if let occupantID, occupantID == guestID {
            model.selectedGuestID = nil
            return
        }
        let moverIsSeated = variant.seat(for: guestID) != nil
        if let occupantID, moverIsSeated {
            pendingSwap = SeatingWorkspaceView.SwapRequest(
                movingGuestID: guestID,
                occupantGuestID: occupantID,
                tableID: table.id,
                targetSeat: seatNumber
            )
            return
        }
        if occupantID != nil, !moverIsSeated {
            // An unseated guest never displaces a seated one silently.
            model.alertMessage = "That seat is taken; use swap with confirmation."
            return
        }
        if moverIsSeated {
            model.perform { controller in
                try controller.perform { commands in
                    try commands.move(variantID: variantID, guestID: guestID, tableID: table.id, seatNumber: seatNumber)
                }
            }
        } else {
            model.perform { controller in
                try controller.perform { commands in
                    try commands.assign(variantID: variantID, guestID: guestID, tableID: table.id, seatNumber: seatNumber)
                }
            }
        }
        if model.alertMessage == nil { model.selectedGuestID = nil }
    }
}

/// Preferences screen: host-entered pair rules with live
/// satisfied/conflict/unresolved explanations and visible contradictions.
struct PairsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section { WorkspaceStatusSection() }
            if let event = model.event, let variant = model.selectedVariant {
                Section("Pair preferences") {
                    preferencesAndWarnings(event: event, variant: variant)
                }
            }
        }
        .modifier(FailureAlertModifier())
    }

    @ViewBuilder
    private func preferencesAndWarnings(event: SeatingEvent, variant: PlanVariant) -> some View {
        let evaluations = RuleEngine.evaluate(event: event, variant: variant)
        let notable = evaluations.filter { $0.status != .satisfied }

        if event.preferences.isEmpty {
            Text("No pair preferences yet.")
                .foregroundStyle(.secondary)
        }
        ForEach(event.preferences) { preference in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(event.guest(preference.firstGuestID)?.displayName ?? "?") & \(event.guest(preference.secondGuestID)?.displayName ?? "?") — \(kindLabel(preference.kind))")
                        .font(.subheadline)
                    if let evaluation = evaluations.first(where: { $0.preferenceID == preference.id }) {
                        Text(evaluation.reason)
                            .font(.caption)
                            .foregroundStyle(evaluation.status == .conflict ? .orange
                                             : evaluation.status == .unresolved ? .secondary : .green)
                    }
                }
                Spacer()
                Button("Remove") {
                    model.perform { controller in
                        try controller.perform { commands in
                            _ = try commands.removePreference(id: preference.id)
                        }
                    }
                }
                .accessibilityIdentifier("remove-preference")
            }
        }
        ForEach(Array(contradictionExplanations(event: event).enumerated()), id: \.offset) { _, text in
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("warning-contradiction")
        }
        if notable.isEmpty, !event.preferences.isEmpty {
            Text("All recorded preferences are satisfied in this plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        AddPreferenceRow()
    }

    private func kindLabel(_ kind: PairPreferenceKind) -> String {
        switch kind {
        case .sameTable: return "Same table"
        case .differentTables: return "Different tables"
        case .adjacent: return "Next to each other"
        }
    }

    private func contradictionExplanations(event: SeatingEvent) -> [String] {
        let keys = RuleEngine.contradictoryGuestPairKeys(preferences: event.preferences)
        return keys.map { key in
            let first = event.guest(key.lower)?.displayName ?? "Guest"
            let second = event.guest(key.higher)?.displayName ?? "Guest"
            return "\(first) and \(second) have contradictory preferences; both remain listed."
        }
    }
}

/// Variant comparison screen: select/duplicate/rename plans side by side.
struct PlansTab: View {
    @Environment(AppModel.self) private var model
    @State private var renameTarget: UUID?
    @State private var renameText = ""

    var body: some View {
        List {
            Section { WorkspaceStatusSection() }
            Section("Compare plans") {
                ForEach(model.allVariantSummaries(), id: \.variantID) { summary in
                    variantRow(summary)
                }
            }
            if renameTarget != nil {
                Section("Rename selected plan") {
                    TextField("New plan name", text: $renameText)
                        .accessibilityIdentifier("rename-plan-field")
                    Button("Rename") { rename() }
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("confirm-rename-plan")
                }
            }
        }
        .modifier(FailureAlertModifier())
    }

    @ViewBuilder
    private func variantRow(_ summary: AppModel.VariantSummary) -> some View {
        let isSelected = summary.variantID == model.selectedVariantID
        Button {
            model.select(variantID: summary.variantID)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(summary.name)
                        .font(.headline)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                Text("\(summary.seated) seated · \(summary.unseated) unseated · \(summary.conflicts) conflicts · \(summary.unresolved) unresolved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("plan-\(summary.name)")
        .contextMenu {
            Button("Duplicate") { duplicate(summary) }
            Button("Rename") {
                renameTarget = summary.variantID
                renameText = summary.name
            }
        }
    }

    private func duplicate(_ summary: AppModel.VariantSummary) {
        let copyName = model.allVariantSummaries().contains { $0.name == "\(summary.name) copy" }
            ? "\(summary.name) copy \(Int.random(in: 100...999))"
            : "\(summary.name) copy"
        model.perform { controller in
            try controller.perform { commands in
                _ = try commands.duplicateVariant(id: summary.variantID, newName: copyName)
            }
        }
        if model.alertMessage == nil, let last = model.event?.variants.last {
            model.select(variantID: last.id)
        }
    }

    private func rename() {
        guard let renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.perform { controller in
            try controller.perform { commands in
                _ = try commands.renameVariant(id: renameTarget, newName: trimmed)
            }
        }
        if model.alertMessage == nil { self.renameTarget = nil }
    }
}

/// Surfaces controller/store failures as an alert and keeps state visible.
struct FailureAlertModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert("Problem", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

/// Confirmation for an occupied-seat swap between two seated guests.
struct SwapConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    let request: SeatingWorkspaceView.SwapRequest
    let onDone: () -> Void

    var body: some View {
        let event = model.event
        VStack(spacing: 16) {
            Text("Swap seats?")
                .font(.headline)
            Text(explanation(event: event))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onDone)
                Button("Swap") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("confirm-swap")
            }
        }
        .padding(24)
        .presentationDetents([.height(220)])
        .modifier(FailureAlertModifier())
    }

    private func explanation(event: SeatingEvent?) -> String {
        let mover = event?.guest(request.movingGuestID)?.displayName ?? "Selected guest"
        let occupant = event?.guest(request.occupantGuestID)?.displayName ?? "Seat occupant"
        let place: String
        if let variant = model.selectedVariant, let table = variant.table(request.tableID) {
            place = "\(table.label) seat \(request.targetSeat)"
        } else {
            place = "the chosen seat"
        }
        return "\(mover) moves to \(place) and \(occupant) takes the vacated seat."
    }

    private func confirm() {
        guard let variantID = model.selectedVariantID else { return }
        model.perform { controller in
            try controller.perform { commands in
                try commands.swap(
                    variantID: variantID,
                    firstGuestID: request.movingGuestID,
                    secondGuestID: request.occupantGuestID,
                    confirmed: true
                )
            }
        }
        if model.alertMessage == nil {
            model.selectedGuestID = nil
            onDone()
        }
    }
}

/// Destructive guest deletion behind an explicit domain preview.
struct DeleteGuestSheet: View {
    @Environment(AppModel.self) private var model
    let target: SeatingWorkspaceView.DeletionTarget
    let onDone: () -> Void

    var body: some View {
        let event = model.event
        VStack(spacing: 16) {
            Text("Delete \(event?.guest(target.id)?.displayName ?? "guest")?")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("This also removes:")
                    .font(.subheadline.weight(.semibold))
                Text(target.preview.removedPreferences.isEmpty
                     ? "• No pair preferences"
                     : "• \(target.preview.removedPreferences.count) pair preference(s)")
                if target.preview.removedAssignments.isEmpty {
                    Text("• No seats (the guest is not seated)")
                } else {
                    ForEach(target.preview.removedAssignments, id: \.self) { loss in
                        Text("• \(loss.variantName): \(seatPlace(loss, event: event))")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Keep guest", role: .cancel, action: onDone)
                Button("Delete guest", role: .destructive) { confirm() }
                    .accessibilityIdentifier("confirm-delete-guest")
            }
        }
        .padding(24)
        .presentationDetents([.medium])
        .modifier(FailureAlertModifier())
    }

    private func seatPlace(_ loss: SeatingCommands.VariantAssignmentLoss, event: SeatingEvent?) -> String {
        guard let variant = event?.variant(loss.variantID),
              let table = variant.table(loss.assignment.tableID) else {
            return "seat \(loss.assignment.seatNumber)"
        }
        return "\(table.label) seat \(loss.assignment.seatNumber)"
    }

    private func confirm() {
        model.perform { controller in
            try controller.perform { commands in
                try commands.deleteGuest(guestID: target.id, confirmedPreview: target.preview)
            }
        }
        if model.alertMessage == nil {
            onDone()
        }
    }
}
