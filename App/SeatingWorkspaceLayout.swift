import SwiftUI

/// Which workspace region the app should present. `.auto` follows the
/// environment's horizontal size class; the two explicit cases exist for
/// deterministic UI testing and for a future public dual-screen API.
/// This enum is the ONLY place a non-size-class decision enters the
/// layout adapter — no fold, hinge or dual-screen API is used anywhere.
enum WorkspaceLayoutOverride: String, CaseIterable, Identifiable {
    case auto
    case compact
    case regular
    var id: String { rawValue }
}

/// The sole adapter between the compact-phone content region and the
/// optional regular-width (tablet) workspace (PLAN.md: `SeatingWorkspaceLayout`
/// is the sole adapter for compact vs regular content regions). Exactly one
/// region is rendered at a time, so session controls and roster identifiers
/// can never be duplicated across regions — the run-35420470196 lesson.
/// A future iPhone Duo public SDK would map onto this same adapter; there
/// is no unavailable-API dependency and no compatibility claim.
struct SeatingWorkspaceLayout: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// True when the regular-width region should render: an explicit
    /// override wins over the environment; `.auto` follows the standard
    /// iPad regular horizontal size class (including XCUITest
    /// `overridesSizeClass`, which updates the environment trait).
    var resolvesRegular: Bool {
        switch model.layoutOverride {
        case .regular: return true
        case .compact: return false
        case .auto: return horizontalSizeClass == .regular
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Rendered exactly once for EITHER region, outside any List,
            // so identifiers resolve to a single instance (see the note on
            // SessionControlBar in SeatingWorkspaceView.swift).
            SessionControlBar()
            Divider()
            if resolvesRegular {
                HStack(spacing: 0) {
                    RegularWorkspaceSidebar()
                        .frame(minWidth: 200, idealWidth: 320, maxWidth: 420)
                    Divider()
                    RegularWorkspaceChart()
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("workspace-regular")
            } else {
                CompactWorkspaceTabs()
                    .accessibilityIdentifier("workspace-compact")
            }
        }
        // The app defines no custom animations; sheet and tab transitions
        // are system-provided and honor the user's Reduce Motion setting
        // automatically. Nothing here animates assignment data.
    }
}

/// Compact phone region: navigate between guests, seats, pairs, plans and
/// share exactly like the README's compact-phone design.
struct CompactWorkspaceTabs: View {
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
            ShareTab()
                .tabItem { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

/// Regular-width roster column: the persistent guest roster with selection
/// controls AND the pair-preference review, permanently beside the chart.
/// Switching the chart plan or tab never hides the roster.
struct RegularWorkspaceSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var deletionTarget: SeatingWorkspaceView.DeletionTarget?
    @State private var renameTarget: UUID?

    var body: some View {
        List {
            // Identical section content to the compact GuestsTab, so a
            // width change swaps regions without changing behaviour or
            // identifiers (single instance per region switch).
            GuestsSectionContent(deletionTarget: $deletionTarget, renameTarget: $renameTarget)
            if let event = model.event, let variant = model.selectedVariant {
                Section("Pair preferences") {
                    PairPreferencesContent(event: event, variant: variant)
                }
            }
        }
        .sheet(item: $deletionTarget) { target in
            DeleteGuestSheet(target: target) {
                if model.selectedGuestID == target.id { model.selectedGuestID = nil }
                deletionTarget = nil
            }
        }
        .sheet(item: $renameTarget) { guestID in
            RenameGuestSheet(guestID: guestID) { renameTarget = nil }
        }
        .modifier(FailureAlertModifier())
    }
}

/// Regular-width chart column: the selected table chart with plans and
/// sharing reachable beside the persistent roster.
struct RegularWorkspaceChart: View {
    var body: some View {
        TabView {
            TablesTab()
                .tabItem { Label("Tables", systemImage: "circle.grid.circle") }
            PlansTab()
                .tabItem { Label("Plans", systemImage: "square.on.square.dashed") }
            ShareTab()
                .tabItem { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}
