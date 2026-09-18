import SeatingDomain
import SwiftUI

struct EventListView: View {
    @Environment(AppModel.self) private var model
    @State private var newTitle = ""

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
            Section("Create a gathering") {
                TextField("Event title", text: $newTitle)
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
