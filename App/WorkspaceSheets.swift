import SeatingDomain
import SwiftUI

/// Inline guest creation with alias support (no contacts access).
struct AddGuestRow: View {
    @Environment(AppModel.self) private var model
    @FocusState private var nameFocused: Bool
    @State private var name = ""

    var body: some View {
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
        .modifier(FailureAlertModifier())
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

/// Duplicate, rename, select and compare plan variants side by side.
struct VariantsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renameTarget: UUID?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Plan variants")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("plans-done")
                }
            }
            .modifier(FailureAlertModifier())
        }
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
        if model.alertMessage == nil {
            // Select the new copy so comparison starts on it.
            if let last = model.event?.variants.last {
                model.select(variantID: last.id)
            }
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
