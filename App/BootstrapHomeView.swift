import SeatingDomain
import SwiftUI

struct BootstrapHomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "tablecells")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Seat Weave")
                        .font(.largeTitle.bold())
                    Text("A local-first seating planner for small gatherings.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Native app foundation is ready", systemImage: "checkmark.circle")
                        Text("Event setup and seating tools arrive in the next milestones.")
                            .foregroundStyle(.secondary)
                        Text("Designed for up to \(SeatingLimits.maximumGuestsPerEvent) guests per event.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .navigationTitle("Home")
        }
        .accessibilityIdentifier("bootstrap.home")
    }
}
