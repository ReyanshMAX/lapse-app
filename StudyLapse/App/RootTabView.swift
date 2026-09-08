import SwiftUI

/// The four top-level destinations, each a tab with its own navigation stack.
/// Added 2026-09-08 (developer request — "make the UI nicer... add the
/// necessary screens an app has to have like homepage") replacing the old
/// single `NavigationStack` rooted at `RecordView` with cross-links to
/// Library/Stats. See STATUS.md Deviations.
enum AppTab: Hashable {
    case home, record, library, stats
}

/// App root: onboarding on first launch, then the tab bar. `RecordView` owns
/// its own `NavigationStack` internally (unchanged); `LibraryView`/`StatsView`
/// didn't need one when they were pushed from `RecordView`'s stack, so they
/// get one here now that each is a standalone tab root.
struct RootTabView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var selection: AppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                HomeView(selection: $selection)
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(AppTab.home)

            RecordView()
                .tabItem { Label("Record", systemImage: "video.fill") }
                .tag(AppTab.record)

            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "square.grid.2x2") }
            .tag(AppTab.library)

            NavigationStack {
                StatsView()
            }
            .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
            .tag(AppTab.stats)
        }
        .tint(Color.slAccent)
        .fullScreenCover(isPresented: Binding(
            get: { !hasSeenOnboarding },
            set: { hasSeenOnboarding = !$0 }
        )) {
            OnboardingView { hasSeenOnboarding = true }
        }
        .onOpenURL { url in
            // Live Activity "Resume" deep link (docs/UI.md "Live Activity").
            guard url.host == "resume", coordinator.status == .paused else { return }
            DebugLog.write("Session", "resume deep link received")
            selection = .record
            Task { try? await coordinator.resume() }
        }
    }
}
