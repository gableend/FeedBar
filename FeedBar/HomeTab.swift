import SwiftUI
import ServiceManagement

struct HomeTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var feedManager: FeedManager
    @ObservedObject private var faviconStore = FaviconStore.shared
    
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showAdminAtStartup") private var showAdminAtStartup = true

    private let iconSize: CGFloat = 16
    private let tileSize: CGFloat = 26
    private var gridCols: [GridItem] { [GridItem(.adaptive(minimum: tileSize, maximum: tileSize), spacing: 8)] }

    var body: some View {
        // ✅ Ask the manager for the tiles to ensure domain-key consistency
        let tiles = feedManager.getSignalTiles()
        
        VStack(spacing: 18) {
            headerSection
            
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SIGNAL BOARD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(FeedsTheme.ai)
                    Spacer()
                    Text("\(tiles.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(FeedsTheme.secondaryText)
                }
                
                LazyVGrid(columns: gridCols, spacing: 8) {
                    ForEach(tiles) { tile in
                        // ✅ SignalIconTileView is now observing faviconStore correctly
                        SignalIconTileView(
                            domain: tile.domain,
                            fallbackSystemIcon: "antenna.radiowaves.left.and.right",
                            tint: tile.tint,
                            size: iconSize,
                            tileSize: tileSize,
                            faviconStore: faviconStore
                        )
                        .help(tile.tooltip)
                    }
                }
                .padding(12)
                .background(FeedsTheme.surface)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(FeedsTheme.divider).opacity(0.7), lineWidth: 1))
            }
            .padding(.horizontal, 26)

            controlSection
            Spacer()
        }
        .onAppear {
            feedManager.softRefresh()
        }
    }

    // MARK: - Subviews
    private var headerSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 46))
                .foregroundColor(FeedsTheme.ai)
            Text("FEEDS")
                .font(.system(size: 30, weight: .black, design: .monospaced))
                .tracking(6)
                .foregroundColor(FeedsTheme.primaryText)
            Text("A signal layer for your desktop.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(FeedsTheme.secondaryText)
        }
        .padding(.top, 18)
    }

    private var controlSection: some View {
        VStack(spacing: 12) {
            Button(action: { coordinator.closeSettings() }) {
                Text("MINIMIZE TO FEED BAR")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(FeedsTheme.background)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 28)
                    .background(FeedsTheme.utility)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .shadow(radius: 5)

            HStack(spacing: 30) {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(CheckboxToggleStyle())
                    .onChange(of: launchAtLogin) { _, val in toggleLaunchAtLogin(enabled: val) }
                
                Toggle("Show Admin at startup", isOn: $showAdminAtStartup)
                    .toggleStyle(CheckboxToggleStyle())
            }
            .font(.system(size: 12))
            .foregroundColor(FeedsTheme.secondaryText)
        }
    }

    private func toggleLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                print("Launch Error: \(error)")
            }
        }
    }
}
