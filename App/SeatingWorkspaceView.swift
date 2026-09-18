import SeatingDomain
import SwiftUI

/// Compact-phone seating workspace: roster list, table seat lists,
/// selection-driven assign/move/swap/unseat/undo, conflict explanations,
/// destructive-edit previews and variant comparison. Every operation is a
/// plain tap on a list or toolbar control; nothing depends on dragging.
struct SeatingWorkspaceView: View {
    @Environment(AppModel.self) private var model

    @State private var selectedGuestID: UUID?
    @State private var pendingSwap: SwapRequest?
    @State private var deletionTarget: DeletionTarget?
    @State private var pendingResizeTableID: UUID?
    @State private var showAddTable = false
    @State private var showVariants = false

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
        List {
            Section {
                Text(model.bannerText)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("seating.summary")
                Text("Plan: \(model.selectedVariant?.name ?? "none")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("selected-plan")
            }

            if let event = model.event, let variant = model.selectedVariant {
                Section("Selected guest") {
                    if let guestID = selectedGuestID, let guest = event.guest(guestID) {
                        Text("\(guest.displayName) — \(model.seatLabel(for: guestID))")
                            .accessibilityIdentifier("selection.current")
                        Button("Unseat") { unseat(guestID: guestID) }
                            .accessibilityIdentifier("unseat-button")
                        Button("Delete guest") {
                            showDeletionSheet(guestID: guestID)
                        }
                        .accessibilityIdentifier("delete-guest-button")
                        Button("Clear selection") { selectedGuestID = nil }
                            .accessibilityIdentifier("clear-selection-button")
                    } else {
                        Text("Tap a guest to select, then tap a seat.")
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

                Section("Tables") {
                    ForEach(variant.tables) { table in
                        ForEach(1...table.seatCount, id: \.self) { seatNumber in
                            seatRow(table: table, seatNumber: seatNumber, variant: variant, event: event)
                        }
                        Button("Resize \(table.label)") {
                            pendingResizeTableID = table.id
                        }
                        .accessibilityIdentifier("resize-\(table.label)")
                    }
                    Button("Add table") { showAddTable = true }
                        .accessibilityIdentifier("add-table-button")
                }

                Section("Pair preferences") {
                    preferenceSection(event: event, variant: variant)
                }
            }
        }
        .navigationTitle(model.event?.title ?? "Seat Weave")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Undo") { model.undo() }
                    .disabled(!model.canUndo)
                    .accessibilityIdentifier("undo-button")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Plans") { showVariants = true }
                    .accessibilityIdentifier("plans-button")
                Button("Close") {
                    selectedGuestID = nil
                    model.closeEvent()
                }
                .accessibilityIdentifier("close-event-button")
            }
        }
        .sheet(isPresented: $showVariants) { VariantsSheet() }
        .sheet(isPresented: $showAddTable) { AddTableSheet() }
        .sheet(item: $pendingSwap) { request in
            SwapConfirmationSheet(request: request) { pendingSwap = nil }
        }
        .sheet(item: $deletionTarget) { target in
            DeleteGuestSheet(target: target) {
                if selectedGuestID == target.id { selectedGuestID = nil }
                deletionTarget = nil
            }
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

    // MARK: - Roster

    @ViewBuilder
    private func rosterRow(guest: GuestIdentity) -> some View {
        let seatLabel = model.seatLabel(for: guest.id)
        Button {
            selectedGuestID = guest.id
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(guest.displayName)
                    Text(seatLabel)
                        .font(.caption)
                        .foregroundStyle(seatLabel == "Unseated" ? .secondary : .primary)
                }
                Spacer()
                if selectedGuestID == guest.id {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("roster-\(guest.displayName)")
        .accessibilityLabel("\(guest.displayName), \(seatLabel)")
    }

    // MARK: - Seats

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
                if let selectedGuestID,
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

    // MARK: - Preferences and warnings

    /// Host-entered pair preferences with explicit kinds plus this
    /// variant's live conflict/unresolved explanations. Unseated pairs are
    /// shown as unresolved, never silently satisfied.
    @ViewBuilder
    private func preferenceSection(event: SeatingEvent, variant: PlanVariant) -> some View {
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
                    remove(preference)
                }
                .accessibilityIdentifier("remove-preference")
            }
        }
        // Contradictions on the same guest pair stay visible, never auto-deleted.
        let contradictionNames = contradictionExplanations(event: event)
        ForEach(Array(contradictionNames.enumerated()), id: \.offset) { _, text in
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

    private func remove(_ preference: PairPreference) {
        model.perform { controller in
            try controller.perform { commands in
                _ = try commands.removePreference(id: preference.id)
            }
        }
    }

    // MARK: - Seat tap routing

    private func seatTapped(table: SeatingTable, seatNumber: Int, variant: PlanVariant) {
        guard let variantID = model.selectedVariantID else { return }
        let occupantID = variant.occupant(tableID: table.id, seatNumber: seatNumber)
        guard let guestID = selectedGuestID else {
            // No selection: tapping an occupied seat picks up its guest.
            selectedGuestID = occupantID
            return
        }
        if let occupantID, occupantID == guestID {
            selectedGuestID = nil
            return
        }
        let moverIsSeated = variant.seat(for: guestID) != nil
        if let occupantID, moverIsSeated {
            pendingSwap = SwapRequest(
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
        if model.alertMessage == nil { selectedGuestID = nil }
    }

    private func unseat(guestID: UUID) {
        guard let variantID = model.selectedVariantID else { return }
        model.perform { controller in
            try controller.perform { commands in
                try commands.unseat(variantID: variantID, guestID: guestID)
            }
        }
        if model.alertMessage == nil { selectedGuestID = nil }
    }

    private func showDeletionSheet(guestID: UUID) {
        do {
            guard let preview = try model.controller?.guestDeletionPreview(guestID: guestID) else { return }
            deletionTarget = DeletionTarget(id: guestID, preview: preview)
        } catch {
            model.alertMessage = error.localizedDescription
        }
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
