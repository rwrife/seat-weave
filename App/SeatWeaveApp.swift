import SwiftUI
import UIKit

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
                    // navigationTitle must sit on the stack's content: applied
                    // to the NavigationStack container it never reaches the bar.
                    SeatingWorkspaceView()
                        .navigationTitle(model.event?.title ?? "Seat Weave")
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
        // Test-only environment probe (launch flag -contentProbe YES):
        // surfaces the ACTUAL Dynamic Type category the environment
        // resolved so the issue #6 large-text journey can prove the
        // simctl-set content size really took effect. Never rendered
        // for user launches.
        .overlay(alignment: .topLeading) {
            if model.contentProbeEnabled {
                ContentSizeProbeView()
            }
        }
    }
}

/// Renders the environment content-size category for UI tests. Lives in
/// a bare overlay so it never affects layout or VoiceOver ordering in
/// user builds (flag-gated, and flag clears at AppModel init).
struct ContentSizeProbeView: View {
    var body: some View {
        Text("content-size:\(UIApplication.shared.preferredContentSizeCategory.rawValue)")
            .accessibilityIdentifier("content-size-probe")
    }
}
