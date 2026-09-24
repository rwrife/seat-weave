import SeatingDomain
import SwiftUI

/// Inline guest creation with alias support (no contacts access).
struct AddGuestRow: View {
    @Environment(AppModel.self) private var model
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    /// Folded display names that already occur more than once or would
    /// be duplicated by this add (issue #17): the row warns while typing
    /// but never blocks — intentional duplicates stay legal.
    var duplicateNames: Set<String> = []

    private var foldedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "und"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Add guest (alias ok)", text: $name)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
                    .accessibilityIdentifier("add-guest-field")
                Button("Add") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    model.perform { controller in
                        try controller.perform { commands in
                            _ = try commands.addGuest(displayName: trimmed)
                        }
                    }
                    if model.alertMessage == nil { name = "" }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("add-guest-button")
            }
            if !foldedName.isEmpty && duplicateNames.contains(foldedName) {
                Text("This matches another guest's name. They stay separate people; tap Add to keep the duplicate intentionally.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("add-guest-duplicate-warning")
            }
        }
        .modifier(FailureAlertModifier())
    }
}

/// Renames one guest (issue #17). Only the display name changes: the
/// guest UUID keeps every assignment in every variant and every pair
/// preference attached. Warns when the new name matches another guest —
/// duplicates stay legal and intentional; the roster disambiguates by
/// seat label and per-person identifiers.
struct RenameGuestSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var nameFocused: Bool
    let guestID: UUID
    let onDone: () -> Void
    @State private var name = ""

    private var event: SeatingEvent? { model.event }

    private var foldedName: String {
        GuestRosterQuery.foldedDisplayName(name)
    }

    /// Folded names of OTHER guests, so the new name never warns about
    /// matching itself by accident (the old name is gone once renamed).
    private var otherNames: Set<String> {
        guard let event else { return [] }
        return Set(event.guests
            .filter { $0.id != guestID }
            .map { GuestRosterQuery.foldedDisplayName($0.displayName) })
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename guest")
                .font(.headline)
            Text("Current name: \(event?.guest(guestID)?.displayName ?? "?")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("rename-current-name")
            TextField("New name or alias", text: $name)
                .focused($nameFocused)
                .onSubmit { nameFocused = false }
                .accessibilityIdentifier("rename-guest-field")
            if !foldedName.isEmpty && otherNames.contains(foldedName) {
                Text("Another guest already uses this name. They stay separate people; tap Rename to keep the duplicate intentionally.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("rename-duplicate-warning")
            }
            HStack(spacing: 12) {
                Button("Keep current name", role: .cancel) { onDone() }
                    .accessibilityIdentifier("rename-cancel-button")
                Button("Rename") { confirm() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("confirm-rename-button")
            }
        }
        .padding(24)
        .presentationDetents([.medium])
        .modifier(FailureAlertModifier())
    }

    private func confirm() {
        model.perform { controller in
            try controller.perform { commands in
                try commands.renameGuest(id: guestID, newName: name)
            }
        }
        if model.alertMessage == nil { onDone() }
    }
}

/// Adds a numbered circular table with a validated seat count.
struct AddTableSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var labelFocused: Bool
    @State private var label = ""
    @State private var seatCount = 6

    var body: some View {
        NavigationStack {
            Form {
                TextField("Table label", text: $label)
                    .focused($labelFocused)
                    .onSubmit { labelFocused = false }
                    .accessibilityIdentifier("table-label-field")
                Stepper("Seats: \(seatCount)", value: $seatCount,
                        in: SeatingLimits.minimumSeatsPerTable...SeatingLimits.maximumSeatsPerTable)
                    .accessibilityIdentifier("table-seats-stepper")
            }
            .navigationTitle("Add table")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add table") { add() }
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("confirm-add-table")
                }
            }
            .modifier(FailureAlertModifier())
        }
    }

    private func add() {
        guard let variantID = model.selectedVariantID else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.perform { controller in
            try controller.perform { commands in
                _ = try commands.addTable(toVariant: variantID, label: trimmed, seatCount: seatCount)
            }
        }
        if model.alertMessage == nil { dismiss() }
    }
}

/// Capacity change behind an explicit unseat preview: shrinking a table
/// names exactly who loses seats before anything is applied.
struct ResizePlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tableID: UUID
    let onDone: () -> Void

    @State private var seatCount = 2
    @State private var preview: TableResizePreview?
    @State private var previewError: String?
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            Form {
                if let table {
                    Stepper("Seats: \(seatCount)", value: $seatCount,
                            in: SeatingLimits.minimumSeatsPerTable...SeatingLimits.maximumSeatsPerTable)
                        .onChange(of: seatCount) { _, _ in refreshPreview() }
                        .accessibilityIdentifier("resize-stepper")
                    previewSection(table: table)
                }
            }
            .navigationTitle("Resize table")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(preview == nil)
                        .accessibilityIdentifier("confirm-resize")
                }
            }
            .modifier(FailureAlertModifier())
        }
        .onAppear { initializeIfNeeded() }
    }

    private var table: SeatingTable? {
        model.selectedVariant?.table(tableID)
    }

    private func initializeIfNeeded() {
        guard !initialized, let table else { return }
        initialized = true
        seatCount = table.seatCount
        refreshPreview()
    }

    @ViewBuilder
    private func previewSection(table: SeatingTable) -> some View {
        if let preview {
            if preview.guestsToUnseat.isEmpty {
                Text("No seated guests are affected.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("resize-affected-none")
            } else {
                let event = model.event
                Section("Guests who would be unseated") {
                    ForEach(preview.guestsToUnseat, id: \.guestID) { loss in
                        Text("\(event?.guest(loss.guestID)?.displayName ?? "Unknown guest") — seat \(loss.seatNumber)")
                    }
                }
                .accessibilityIdentifier("resize-affected-list")
            }
        } else if let previewError {
            Text(previewError).foregroundStyle(.orange)
        }
    }

    private func refreshPreview() {
        guard let variantID = model.selectedVariantID else { return }
        do {
            preview = try model.controller?.resizePreview(
                variantID: variantID,
                tableID: tableID,
                newSeatCount: seatCount
            )
            previewError = nil
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
    }

    private func apply() {
        guard let preview, let variantID = model.selectedVariantID else { return }
        model.perform { controller in
            try controller.perform { commands in
                _ = try commands.resizeTable(variantID: variantID, preview: preview, confirmed: true)
            }
        }
        if model.alertMessage == nil {
            onDone()
            dismiss()
        }
    }
}

/// Inline pair-preference creation with explicit kinds, inside the
/// workspace preferences section.
struct AddPreferenceRow: View {
    @Environment(AppModel.self) private var model
    @State private var firstGuestID: UUID?
    @State private var secondGuestID: UUID?
    @State private var kind: PairPreferenceKind = .sameTable

    var body: some View {
        if let event = model.event {
            Picker("First guest", selection: $firstGuestID) {
                Text("First guest…").tag(UUID?.none)
                ForEach(event.guests, id: \.self) { guest in
                    Text(guest.displayName).tag(Optional(guest.id))
                }
            }
            .accessibilityIdentifier("preference-first-picker")
            Picker("Second guest", selection: $secondGuestID) {
                Text("Second guest…").tag(UUID?.none)
                ForEach(event.guests, id: \.self) { guest in
                    Text(guest.displayName).tag(Optional(guest.id))
                }
            }
            .accessibilityIdentifier("preference-second-picker")
            Picker("Kind", selection: $kind) {
                Text("Same table").tag(PairPreferenceKind.sameTable)
                Text("Different tables").tag(PairPreferenceKind.differentTables)
                Text("Next to each other").tag(PairPreferenceKind.adjacent)
            }
            .accessibilityIdentifier("preference-kind-picker")
            Button("Add preference") { add() }
                .disabled(firstGuestID == nil || secondGuestID == nil || firstGuestID == secondGuestID)
                .accessibilityIdentifier("add-pair-preference")
        }
    }

    private func add() {
        guard let firstGuestID, let secondGuestID, firstGuestID != secondGuestID else { return }
        model.perform { controller in
            try controller.perform { commands in
                _ = try commands.addPreference(
                    firstGuestID: firstGuestID,
                    secondGuestID: secondGuestID,
                    kind: kind
                )
            }
        }
        if model.alertMessage == nil {
            self.firstGuestID = nil
            self.secondGuestID = nil
        }
    }
}
