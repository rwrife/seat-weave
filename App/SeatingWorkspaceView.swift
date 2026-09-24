import SeatingDomain
import SwiftUI

/// Seating workspace root. The region choice (compact tabs vs regular
/// split workspace) lives entirely in `SeatingWorkspaceLayout`; session
/// selection (event/variant/guest, table focus) lives in `AppModel`, so
/// switching regions or rotating the device cannot lose context.
/// Every operation is a plain tap on a list, tab or toolbar control;
/// nothing depends on dragging, which keeps VoiceOver, Switch Control
/// and keyboard navigation complete.
struct SeatingWorkspaceView: View {
    var body: some View {
        SeatingWorkspaceLayout()
    }
}

extension SeatingWorkspaceView {
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
}

/// Banner, selected plan and session controls, rendered exactly ONCE
/// above whichever region `SeatingWorkspaceLayout` picks. They used to be
/// a List section on every tab; that put four same-identifier copies of
/// Undo/Close under the TabView, and the UI journey's undo tap resolved
/// against a hidden tab's copy while the synthesized event landed on the
/// front tab's Close event button (run 35420470196: the app popped to the
/// Events list mid-journey). A single instance outside any List also
/// cannot shift under sheet dismissal or per-tab scrolling, so a resolved
/// frame stays true at synthesis time. Visible buttons still work for
/// VoiceOver, Switch Control and XCUITest alike.
struct SessionControlBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.bannerText)
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("seating.summary")
            HStack {
                Text("Plan: \(model.selectedVariant?.name ?? "none")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("selected-plan")
                Spacer()
                if model.layoutToggleEnabled {
                    // Test-build-only region override (launch flag
                    // -layoutToggle YES). A plain menu, so the same
                    // transition a future public dual-screen API would
                    // drive is exercisable by Switch Control and XCUITest.
                    // Icon-only to survive 320pt phone widths alongside
                    // Undo/Close controls.
                    Menu {
                        ForEach(WorkspaceLayoutOverride.allCases) { option in
                            Button(option.rawValue) { model.layoutOverride = option }
                                .accessibilityIdentifier("layout-region-\(option.rawValue)")
                        }
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .accessibilityIdentifier("layout-region-menu")
                    .accessibilityLabel("Workspace region")
                }
                Button("Undo") { model.undo() }
                    .disabled(!model.canUndo)
                    .accessibilityIdentifier("undo-button")
                Button("Close event", role: .destructive) { model.closeEvent() }
                    .accessibilityIdentifier("close-event-button")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Roster screen (compact region): alias-capable guest list, selection
/// controls and previewed destructive deletion. Shares its building blocks
/// with the regular-width sidebar so both regions behave identically.
struct GuestsTab: View {
    @Environment(AppModel.self) private var model
    @State private var deletionTarget: SeatingWorkspaceView.DeletionTarget?
    @State private var renameTarget: RenameGuestBox?

    var body: some View {
        List {
            GuestsSectionContent(deletionTarget: $deletionTarget, renameTarget: $renameTarget)
        }
        .sheet(item: $deletionTarget) { target in
            DeleteGuestSheet(target: target) {
                if model.selectedGuestID == target.id { model.selectedGuestID = nil }
                deletionTarget = nil
            }
        }
        .sheet(item: $renameTarget) { box in
            RenameGuestSheet(guestID: box.id) { renameTarget = nil }
        }
        .modifier(FailureAlertModifier())
    }
}

/// The three roster sections, shared by the compact Guests tab and the
/// regular-width sidebar. Selection and deletion state belong to the
/// content, the sheet host belongs to each region container.
struct GuestsSectionContent: View {
    @Environment(AppModel.self) private var model
    @Binding var deletionTarget: SeatingWorkspaceView.DeletionTarget?
    @Binding var renameTarget: RenameGuestBox?

    var body: some View {
        if let event = model.event, let variant = model.selectedVariant {
            let visible = GuestRosterQuery.visibleGuests(
                in: event, variant: variant,
                search: model.rosterSearch, filter: model.rosterFilter)
            let duplicates = GuestRosterQuery.duplicateDisplayNameIDs(in: event)
            Section("Selected guest") {
                if let guestID = model.selectedGuestID, let guest = event.guest(guestID) {
                    Text("\(guest.displayName) — \(model.seatLabel(for: guestID))")
                        .accessibilityIdentifier("selection.current")
                    // Explain (issue #17) when the current filter or
                    // search hides the selected guest from the roster.
                    if !GuestRosterQuery.passes(guest, filter: model.rosterFilter, in: variant)
                        || !GuestRosterQuery.name(guest, matchesSearch: model.rosterSearch) {
                        Text("Selected guest is hidden by the current filter or search.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("selection.hidden-by-filter")
                        Button("Show selected guest") {
                            model.rosterSearch = ""
                            model.rosterFilter = .all
                        }
                        .accessibilityIdentifier("reveal-selected-button")
                    }
                    Button("Unseat") { unseat(guestID: guestID) }
                        .accessibilityIdentifier("unseat-button")
                    Button("Rename guest") { renameTarget = RenameGuestBox(id: guestID) }
                        .accessibilityIdentifier("rename-guest-button")
                    Button("Delete guest") { showDeletionSheet(guestID: guestID) }
                        .accessibilityIdentifier("delete-guest-button")
                    Button("Clear selection") { model.selectedGuestID = nil }
                        .accessibilityIdentifier("clear-selection-button")
                } else {
                    Text("Tap a guest to select, then choose a seat on Tables.")
                        .foregroundStyle(.secondary)
                }
            }
            if !duplicates.isEmpty {
                Section {
                    Text("Some guests share a display name. They stay separate people; seats and preferences follow each person, never the name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("duplicate-names-banner")
                }
            }
            Section {
                HStack(spacing: 8) {
                    ForEach(GuestRosterQuery.Filter.allCases, id: \.self) { filter in
                        Button {
                            model.rosterFilter = filter
                        } label: {
                            // Plain button + checkmark: the repo's
                            // established selection idiom (roster/seat
                            // rows); a ternary of two different
                            // ButtonStyle types does not typecheck.
                            HStack(spacing: 4) {
                                Text(filter.label)
                                if filter == model.rosterFilter {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("filter-\(filter.rawValue)")
                        .accessibilityLabel("\(filter.label) filter\(filter == model.rosterFilter ? ", selected" : "")")
                    }
                }
                .listRowSeparator(.hidden)
            } header: {
                Text("Filter")
            }
            // In-list search field, not `.searchable`: the repo's CI
            // evidence shows plain in-list text fields bridge to the
            // accessibility hierarchy reliably while toolbar-adjacent
            // search chrome is flaky (issue #4 journey notes). Search
            // state lives in AppModel so tab switches keep it.
            Section {
                HStack {
                    TextField("Search by name", text: Binding(
                        get: { model.rosterSearch },
                        set: { model.rosterSearch = $0 }
                    ))
                    .accessibilityIdentifier("guest-search-field")
                    if !model.rosterSearch.isEmpty {
                        Button("Clear search") { model.rosterSearch = "" }
                            .accessibilityIdentifier("clear-search-button")
                    }
                }
            } header: {
                Text("Search")
            }
            Section("Guests (\(visible.count) of \(event.guests.count))") {
                ForEach(visible, id: \.self) { guest in
                    rosterRow(guest: guest, isDuplicate: duplicates.values.contains { $0.contains(guest.id) })
                }
                if visible.isEmpty {
                    Text(event.guests.isEmpty
                         ? "No guests yet. Add the first one below."
                         : "No guests match the current search and filter.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("roster-empty")
                }
                AddGuestRow(duplicateNames: GuestRosterQuery.foldedNameSet(in: event))
            }
        }
    }

    @ViewBuilder
    private func rosterRow(guest: GuestIdentity, isDuplicate: Bool) -> some View {
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
                    if isDuplicate {
                        Text("shares this name")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("duplicate-mark-\(guest.id.uuidString)")
                    }
                }
                Spacer()
                if model.selectedGuestID == guest.id {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Identity is the UUID, not the name (issue #17): two guests may
        // share a display name and must never share a control identifier.
        .accessibilityIdentifier("roster-\(guest.id.uuidString)")
        // One element, one clear phrase: name first, then current seat,
        // then the duplicate-name warning. VoiceOver reads this row as a
        // single item in roster order.
        .accessibilityLabel(isDuplicate
                            ? "\(guest.displayName), \(seatLabel), shares this name with another guest"
                            : "\(guest.displayName), \(seatLabel)")
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

            if let event = model.event, let variant = model.selectedVariant {
                if model.selectedGuestID != nil {
                    Section {
                        Text("Selected: \(event.guest(model.selectedGuestID!)?.displayName ?? "?") — \(model.seatLabel(for: model.selectedGuestID!)). Tap a seat below.")
                            .font(.subheadline)
                            .accessibilityIdentifier("tables.selection-hint")
                    }
                }
                ForEach(variant.tables) { table in
                    Section {
                        ForEach(1...table.seatCount, id: \.self) { seatNumber in
                            seatRow(table: table, seatNumber: seatNumber, variant: variant, event: event)
                        }
                        Button("Resize \(table.label)") {
                            pendingResizeTableID = table.id
                        }
                        .accessibilityIdentifier("resize-\(table.label)")
                    } header: {
                        HStack {
                            Text(table.label)
                            if model.focusedTableID == table.id {
                                Image(systemName: "target")
                                    .accessibilityLabel("Focused table")
                                    .accessibilityIdentifier("focus-\(table.label)")
                            }
                        }
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
        // Table focus is app state (PLAN.md): interacting with a table
        // focuses it, and no width/orientation/region switch resets it.
        model.focusedTableID = table.id
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
            if let event = model.event, let variant = model.selectedVariant {
                Section("Pair preferences") {
                    PairPreferencesContent(event: event, variant: variant)
                }
            }
        }
        .modifier(FailureAlertModifier())
    }
}
/// Preference review shared by the compact Pairs tab and the regular
/// sidebar. Status is conveyed by text (reason strings), never color or
/// icon alone, so contrast and VoiceOver need no special accommodation.
struct PairPreferencesContent: View {
    @Environment(AppModel.self) private var model
    let event: SeatingEvent
    let variant: PlanVariant

    var body: some View {
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
