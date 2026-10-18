import SeatingDomain
import SwiftUI

struct EventListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var titleFocused: Bool
    @State private var newTitle = ""
    @State private var permanentTarget: EventStore.DeletedEvent?

    var body: some View {
        List {
            Section("Open an event") {
                ForEach(model.events) { event in
                    Button("Open \(event.title)") {
                        model.open(eventID: event.id)
                    }
                    .accessibilityIdentifier("open-event-\(event.title)")
                }
            }
            if !model.recentlyDeleted.isEmpty {
                Section("Recently Deleted — kept 14 days") {
                    ForEach(model.recentlyDeleted) { deleted in
                        HStack {
                            Text(deleted.title)
                            Spacer()
                            Button("Recover") { model.restoreDeleted(id: deleted.id) }
                                .accessibilityLabel("Recover \(deleted.title)")
                                .accessibilityIdentifier("list-recover-\(deleted.title)")
                            Button("Delete permanently", role: .destructive) {
                                permanentTarget = deleted
                            }
                            .accessibilityLabel("Delete \(deleted.title) permanently")
                            .accessibilityIdentifier("list-permanent-\(deleted.title)")
                        }
                    }
                }
            }
            Section("Create a gathering") {
                TextField("Event title", text: $newTitle)
                    .focused($titleFocused)
                    .onSubmit { titleFocused = false }
                    .accessibilityIdentifier("event-title-field")
                Button("Create event") {
                    if let id = model.createEvent(title: newTitle) {
                        newTitle = ""
                        model.open(eventID: id)
                    }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("create-event-button")
            }
        }
        .navigationTitle("Events")
        .confirmationDialog("Delete '\(permanentTarget?.title ?? "")' permanently?",
                            isPresented: Binding(get: { permanentTarget != nil },
                                                 set: { if !$0 { permanentTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                if let target = permanentTarget { model.deletePermanently(id: target.id) }
                permanentTarget = nil
            }
            .accessibilityIdentifier("confirm-permanent-delete")
            Button("Cancel", role: .cancel) { permanentTarget = nil }
        } message: {
            Text("Removes the event, its automatic recovery points and this recently-deleted copy from this device. Nothing local can be recovered afterwards.")
        }
        .alert("Problem", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}
