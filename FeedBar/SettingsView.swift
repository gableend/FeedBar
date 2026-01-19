import SwiftUI

struct SettingsView: View {
    @ObservedObject var feedManager: FeedManager
    @ObservedObject var coordinator: AppCoordinator
    @State private var selectedTab: SettingsTab = .home

    enum SettingsTab: String, CaseIterable {
        case home = "Home", preferences = "Preferences", sources = "Sources", about = "About"
    }

    var body: some View {
        HStack(spacing: 0) {
            // SIDEBAR
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("FEEDS").font(.system(size: 14, weight: .heavy, design: .monospaced))
                }.foregroundColor(FeedsTheme.primaryText).padding(20)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SidebarButton(title: tab.rawValue, icon: icon(for: tab), isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
                Spacer()
            }
            .frame(width: 200).background(FeedsTheme.background)

            // CONTENT - Swapping the new Tab files in here
            ZStack {
                FeedsTheme.surface.ignoresSafeArea()
                switch selectedTab {
                case .home: HomeTab(coordinator: coordinator, feedManager: feedManager)
                case .preferences: PreferencesTab(coordinator: coordinator, feedManager: feedManager)
                case .sources: SourcesTab(feedManager: feedManager)
                case .about: AboutView()
                }
            }
        }
        .frame(width: 800, height: 650)
        .preferredColorScheme(.dark)
    }

    func icon(for tab: SettingsTab) -> String {
        switch tab {
        case .home: return "house"
        case .preferences: return "slider.horizontal.3"
        case .sources: return "network"
        case .about: return "info.circle"
        }
    }
}
