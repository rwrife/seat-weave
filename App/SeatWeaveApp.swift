import SwiftUI

@main
struct SeatWeaveApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// Opens into the previously selected plan when one is stored; otherwise
/// shows the local event list. The one-shot guard keeps an explicit Close
/// from being undone by re-navigation.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var didAttemptRelaunch = false

    var body: some View {
        Group {
            if model.event != nil {
                NavigationStack {
                    SeatingWorkspaceView()
                }
            } else {
                NavigationStack {
                    EventListView()
                }
            }
        }
        .onAppear {
            guard !didAttemptRelaunch else { return }
            didAttemptRelaunch = true
            if !AppModel.resetStoreRequested,
               let id = model.launchEventID() {
                model.open(eventID: id)
            }
        }
    }
}
