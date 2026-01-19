import SwiftUI
import ServiceManagement
import Combine

// MARK: - THEME EXTENSIONS
extension FeedsTheme {
    static let surface = Color(hex: "16181D")
    static let inputBackground = Color(hex: "000000").opacity(0.4)
    static let success = Color(hex: "34C759")
    static let newsHighContrast = Color(hex: "7E8BA8")
}

// MARK: - WINDOW ACCESSOR
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.callback(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - CONSISTENT TOGGLE STYLE
struct SignalSwitchStyle: ToggleStyle {
    var onColor: Color = FeedsTheme.ai
    var offColor: Color = Color.white.opacity(0.15)
    var knobColor: Color = .white
    var width: CGFloat = 36
    var height: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? onColor : offColor)
                    .frame(width: width, height: height)
                    .overlay(Capsule().stroke(FeedsTheme.divider.opacity(0.8), lineWidth: 1))
                Circle()
                    .fill(knobColor)
                    .frame(width: height - 4, height: height - 4)
                    .padding(2)
                    .shadow(radius: 1)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SETTINGS MAIN VIEW
struct SettingsView: View {
    @ObservedObject var feedManager: FeedManager
    @ObservedObject var coordinator: AppCoordinator
    @State private var selectedTab: SettingsTab = .home

    enum SettingsTab: String, CaseIterable {
        case home = "Home"
        case preferences = "Preferences"
        case sources = "Sources"
        case about = "About"
    }

    var body: some View {
        HStack(spacing: 0) {
            // SIDEBAR
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("FEEDS").font(.system(size: 14, weight: .heavy, design: .monospaced))
                }
                .foregroundColor(FeedsTheme.primaryText).padding(.horizontal, 20).padding(.vertical, 24)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SidebarButton(title: tab.rawValue, icon: icon(for: tab), isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
                Spacer()
                HStack {
                    Circle().fill(FeedsTheme.success).frame(width: 6, height: 6)
                    Text("Signal Active").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                }.padding(20)
            }
            .frame(width: 200).background(FeedsTheme.background)
            .overlay(Rectangle().frame(width: 1).foregroundColor(FeedsTheme.divider), alignment: .trailing)

            // CONTENT
            ZStack {
                FeedsTheme.surface.ignoresSafeArea()
                switch selectedTab {
                case .home: HomeView(coordinator: coordinator, feedManager: feedManager)
                case .preferences: PreferencesView(coordinator: coordinator, feedManager: feedManager)
                case .sources: SourcesView(feedManager: feedManager)
                case .about: AboutView()
                }
            }
        }
        .frame(width: 800, height: 650)
        .preferredColorScheme(.dark) // ✅ FIX: Forces Chevrons & Controls to White
        .background(WindowAccessor { window in
            window?.center()
            window?.makeKeyAndOrderFront(nil)
        })
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

// MARK: - 1. HOME VIEW
struct HomeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var feedManager: FeedManager
    @ObservedObject private var faviconStore = FaviconStore.shared
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showAdminAtStartup") private var showAdminAtStartup = true
    @AppStorage("customFeeds") private var customFeeds = CustomFeedStorage(feeds: [])

    private let iconSize: CGFloat = 16
    private let tileSize: CGFloat = 26
    private var gridCols: [GridItem] { [GridItem(.adaptive(minimum: tileSize, maximum: tileSize), spacing: 8)] }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 46)).foregroundColor(FeedsTheme.ai)
                Text("FEEDS").font(.system(size: 30, weight: .black, design: .monospaced)).tracking(6).foregroundColor(FeedsTheme.primaryText)
                Text("A signal layer for your desktop.").font(.system(size: 14, weight: .medium)).foregroundColor(FeedsTheme.secondaryText)
            }.padding(.top, 18)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SIGNAL BOARD").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(FeedsTheme.ai)
                    Spacer()
                    Text("\(signalTiles.count)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(FeedsTheme.secondaryText)
                }
                LazyVGrid(columns: gridCols, spacing: 8) {
                    ForEach(signalTiles, id: \.id) { tile in
                        SignalIconTileView(domain: tile.domain, fallbackSystemIcon: tile.fallbackIcon, tint: tile.tint, size: iconSize, tileSize: tileSize, faviconStore: faviconStore)
                            .help(tile.tooltip)
                    }
                }
                .padding(12).background(FeedsTheme.surface).cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(FeedsTheme.divider.opacity(0.7), lineWidth: 1))
            }
            .padding(.horizontal, 26)

            Divider().background(FeedsTheme.divider).padding(.horizontal, 80).padding(.bottom, 6)

            VStack(spacing: 12) {
                Button(action: { coordinator.closeSettings() }) {
                    Text("MINIMIZE TO FEED BAR").font(.system(size: 12, weight: .bold)).foregroundColor(FeedsTheme.background)
                        .padding(.vertical, 14).padding(.horizontal, 28).background(FeedsTheme.utility).cornerRadius(6)
                }.buttonStyle(.plain).shadow(radius: 5)

                HStack(spacing: 30) {
                    Toggle("Launch at login", isOn: $launchAtLogin).toggleStyle(CheckboxToggleStyle()).onChange(of: launchAtLogin) { _, val in toggleLaunchAtLogin(enabled: val) }
                    Toggle("Show Admin at startup", isOn: $showAdminAtStartup).toggleStyle(CheckboxToggleStyle())
                }.font(.system(size: 12)).foregroundColor(FeedsTheme.secondaryText)
            }
            Spacer()
        }
    }

    private func toggleLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { print("Launch Error: \(error)") }
        }
    }

    private struct SignalTile { let id, tooltip: String; let domain: String?; let fallbackIcon: String; let tint: Color }
    private var signalTiles: [SignalTile] {
        var tiles: [SignalTile] = []; var seenDomains = Set<String>()
        for s in feedManager.sources {
            if s.name == "Global Market Trends" || s.name == "Futurism Signals" { continue }
            let normalized = GoogleFaviconProvider.normalizedDomain(s.domain)
            guard GoogleFaviconProvider.isLikelyDomain(normalized) else {
                tiles.append(SignalTile(id: "news-\(s.name)", tooltip: s.name, domain: nil, fallbackIcon: "dot.radiowaves.left.and.right", tint: FeedsTheme.newsHighContrast))
                continue
            }
            if !seenDomains.contains(normalized) { seenDomains.insert(normalized); tiles.append(SignalTile(id: "news-\(normalized)", tooltip: s.name, domain: normalized, fallbackIcon: "dot.radiowaves.left.and.right", tint: FeedsTheme.newsHighContrast)) }
        }
        for c in customFeeds.feeds {
            let normalized = GoogleFaviconProvider.normalizedDomain(c.domain)
            let domainToUse = (GoogleFaviconProvider.isLikelyDomain(normalized) && !seenDomains.contains(normalized)) ? normalized : nil
            if let d = domainToUse { seenDomains.insert(d) }
            tiles.append(SignalTile(id: "topic-\(c.id.uuidString)", tooltip: c.name, domain: domainToUse, fallbackIcon: "dot.radiowaves.left.and.right", tint: FeedsTheme.ai))
        }
        tiles.append(SignalTile(id: "sys-trends", tooltip: "Global Market Trends", domain: nil, fallbackIcon: "chart.line.uptrend.xyaxis", tint: FeedsTheme.trends))
        tiles.append(SignalTile(id: "sys-future", tooltip: "Futurism Signals", domain: nil, fallbackIcon: "sparkles", tint: FeedsTheme.futurism))
        return Array(tiles.prefix(180))
    }
}

// MARK: - 2. SOURCES VIEW
struct SourcesView: View {
    @ObservedObject var feedManager: FeedManager
    @AppStorage("customFeeds") var customFeeds = CustomFeedStorage(feeds: [])

    @State private var filter: SourceFilter = .feeds
    @State private var enabledStates: [String: Bool] = [:]
    @State private var expandedCategories: [String: Bool] = [:]
    
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var statusMessage: String? = nil
    @State private var newlyAddedIDs: Set<UUID> = []
    
    @State private var rssURLInput: String = ""
    @State private var rssNameInput: String = ""
    @State private var isAddingRSS: Bool = false
    @State private var rssStatus: String? = nil
    @State private var showDeleteConfirmation = false

    enum SourceFilter: String, CaseIterable {
        case feeds = "Feeds"
        case system = "System"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            tabSection
            controlBar
            
            ScrollView {
                mainListContent
            }
            .background(FeedsTheme.surface)
            .accentColor(.white) // ✅ Force Chevrons White
            
            footerSection
        }
        .onAppear { loadEnabledStates() }
        .alert("Delete all topics?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteAllTopics() }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DISCOVER NEW FEEDS").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(FeedsTheme.ai)
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(FeedsTheme.secondaryText)
                    TextField("Topic (e.g. 'SpaceX')...", text: $searchText).textFieldStyle(.plain).onSubmit { discover() }
                }.padding(12).background(FeedsTheme.inputBackground).cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.divider, lineWidth: 1))
                Button(action: discover) {
                    if isSearching { ProgressView().controlSize(.small) }
                    else { Text("FIND").font(.system(size: 11, weight: .bold)).padding(.horizontal, 16).padding(.vertical, 12).background(FeedsTheme.utility).cornerRadius(6) }
                }.buttonStyle(.plain).disabled(isSearching || searchText.isEmpty)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ADD A NEW FEED BY URL").font(.system(size: 9, weight: .bold)).foregroundColor(.blue).padding(.top, 4)
                HStack(alignment: .top, spacing: 10) {
                    TextField("https://...", text: $rssURLInput).textFieldStyle(.plain).padding(10).background(FeedsTheme.inputBackground).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.divider, lineWidth: 1))
                    TextField("Name", text: $rssNameInput).textFieldStyle(.plain).padding(10).frame(width: 140).background(FeedsTheme.inputBackground).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.divider, lineWidth: 1))
                    Button(action: addRSS) {
                        if isAddingRSS { ProgressView().controlSize(.small) }
                        else { Text("ADD").font(.system(size: 11, weight: .bold)).padding(.horizontal, 16).padding(.vertical, 12).background(FeedsTheme.utility).cornerRadius(6) }
                    }.buttonStyle(.plain).disabled(isAddingRSS || rssURLInput.isEmpty)
                }
            }
            if let status = statusMessage ?? rssStatus {
                Text(status).font(.system(size: 11, weight: .medium)).foregroundColor(status.contains("✕") ? .red : FeedsTheme.success)
            }
        }.padding(24).background(FeedsTheme.surface)
    }

    private var tabSection: some View {
        HStack(spacing: 8) {
            ForEach(SourceFilter.allCases, id: \.self) { tab in
                Button(action: { withAnimation { filter = tab } }) {
                    Text(tab.rawValue.uppercased()).font(.system(size: 11, weight: .bold)).padding(.vertical, 8).frame(maxWidth: .infinity)
                        .background(filter == tab ? Color.white.opacity(0.1) : Color.clear)
                        .foregroundColor(filter == tab ? FeedsTheme.primaryText : FeedsTheme.secondaryText).cornerRadius(6)
                        .overlay(filter == tab ? RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.ai.opacity(0.5), lineWidth: 1) : nil)
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 24).padding(.vertical, 12).background(FeedsTheme.surface).overlay(Rectangle().frame(height: 1).foregroundColor(FeedsTheme.divider), alignment: .bottom)
    }

    private var controlBar: some View {
        HStack {
            Text(filter == .feeds ? "SOURCE CONTROL" : "SYSTEM CONTROL").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(FeedsTheme.secondaryText)
            Spacer()
            HStack(spacing: 8) {
                Text("ENABLE ALL").font(.system(size: 9, weight: .bold)).foregroundColor(FeedsTheme.secondaryText)
                Toggle("", isOn: Binding(get: { isBulkEnabled }, set: { setBulkEnabled($0) })).labelsHidden().toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
            }
        }.padding(.horizontal, 24).padding(.vertical, 12).background(FeedsTheme.surface).overlay(Rectangle().frame(height: 1).foregroundColor(FeedsTheme.divider.opacity(0.6)), alignment: .bottom)
    }

    private var mainListContent: some View {
        LazyVStack(spacing: 1) {
            if filter == .system {
                DataRow(name: "Global Market Trends", isEnabled: cachedBinding(key: "showTrends", defaultVal: true), isPersonal: false, isNew: false, itemCount: 2, onDelete: nil)
                    .padding(.horizontal, 24)
                DataRow(name: "Futurism Signals", isEnabled: cachedBinding(key: "showPredictions", defaultVal: true), isPersonal: false, isNew: false, itemCount: 1, onDelete: nil)
                    .padding(.horizontal, 24)
            } else {
                let allItems = getUnifiedItems()
                let grouped = Dictionary(grouping: allItems, by: { $0.category })
                ForEach(grouped.keys.sorted(), id: \.self) { cat in
                    renderCategorySection(name: cat, items: grouped[cat] ?? [])
                }
            }
        }.padding(.bottom, 20)
    }

    private func renderCategorySection(name: String, items: [UnifiedItem]) -> some View {
        let isExp = Binding(get: { expandedCategories[name] ?? true }, set: { expandedCategories[name] = $0 })
        
        return DisclosureGroup(isExpanded: isExp) {
            ForEach(items) { item in
                DataRow(
                    name: item.name,
                    isEnabled: cachedBinding(key: item.settingKey, defaultVal: item.defaultEnabled),
                    isPersonal: item.isPersonal,
                    isNew: newlyAddedIDs.contains(item.id),
                    // ✅ FIXED: Pass item count (or 0 if not found)
                    itemCount: feedManager.itemCount(for: item.name),
                    onDelete: item.isPersonal ? { deletePersonalFeed(id: item.id) } : nil
                )
            }
        } label: {
            HStack {
                Text(name.uppercased()).font(.system(size: 11, weight: .bold)).foregroundColor(FeedsTheme.primaryText)
                Spacer()
                Text("\(items.count)").font(.system(size: 9)).foregroundColor(FeedsTheme.secondaryText).padding(4).background(Color.white.opacity(0.1)).cornerRadius(4)
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 24) // Align chevron with header
    }

    private var footerSection: some View {
        Group {
            if filter == .feeds && !customFeeds.feeds.isEmpty {
                Button(action: disableAllPersonal) {
                    HStack { Image(systemName: "power.circle.fill"); Text("DISABLE ALL PERSONAL FEEDS") }
                        .font(.system(size: 10, weight: .bold)).foregroundColor(.red.opacity(0.7)).frame(maxWidth: .infinity).padding(.vertical, 12).background(Color.red.opacity(0.05))
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: - LOGIC
    
    private struct UnifiedItem: Identifiable { let id: UUID; let name, category, settingKey: String; let isPersonal, defaultEnabled: Bool }
    
    private func getUnifiedItems() -> [UnifiedItem] {
        var out: [UnifiedItem] = []
        var liveCategories = Set<String>()
        
        for s in feedManager.sources {
            let cat = (s.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let finalCat = cat.isEmpty ? "General" : cat
            liveCategories.insert(finalCat)
            out.append(UnifiedItem(id: s.id, name: s.name, category: finalCat, settingKey: s.settingKey, isPersonal: false, defaultEnabled: s.defaultEnabled))
        }
        
        for c in customFeeds.feeds {
            let savedCat = (c.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // ✅ DYNAMIC MATCHING
            let bestCat: String
            if !savedCat.isEmpty && savedCat != "General" && savedCat != "RSS" && liveCategories.contains(savedCat) {
                bestCat = savedCat
            } else {
                bestCat = CategoryNormalizer.match(feedName: c.name, url: c.url, liveCategories: liveCategories)
            }
            out.append(UnifiedItem(id: c.id, name: c.name, category: bestCat, settingKey: "custom_enabled_\(c.id.uuidString)", isPersonal: true, defaultEnabled: true))
        }
        return out
    }

    private var isBulkEnabled: Bool {
        let keys = filter == .system ? ["showTrends", "showPredictions"] : getUnifiedItems().map { $0.settingKey }
        return keys.allSatisfy { enabledStates[$0] ?? true }
    }
    
    private func setBulkEnabled(_ enabled: Bool) {
        let keys = filter == .system ? ["showTrends", "showPredictions"] : getUnifiedItems().map { $0.settingKey }
        for k in keys { enabledStates[k] = enabled; UserDefaults.standard.set(enabled, forKey: k) }
        feedManager.softRefresh()
    }
    
    private func loadEnabledStates() {
        for item in getUnifiedItems() {
            enabledStates[item.settingKey] = UserDefaults.standard.object(forKey: item.settingKey) as? Bool ?? item.defaultEnabled
        }
        enabledStates["showTrends"] = UserDefaults.standard.object(forKey: "showTrends") as? Bool ?? true
        enabledStates["showPredictions"] = UserDefaults.standard.object(forKey: "showPredictions") as? Bool ?? true
    }
    
    private func cachedBinding(key: String, defaultVal: Bool) -> Binding<Bool> {
        Binding(
            get: { enabledStates[key] ?? defaultVal },
            set: { newValue in
                enabledStates[key] = newValue
                UserDefaults.standard.set(newValue, forKey: key)
                feedManager.softRefresh()
            }
        )
    }
    
    private func deletePersonalFeed(id: UUID) {
        var current = customFeeds.feeds; current.removeAll { $0.id == id }
        customFeeds = CustomFeedStorage(feeds: current); UserDefaults.standard.set(customFeeds.rawValue, forKey: "customFeeds"); feedManager.softRefresh()
    }
    
    private func deleteAllTopics() { customFeeds = CustomFeedStorage(feeds: []); UserDefaults.standard.set(customFeeds.rawValue, forKey: "customFeeds"); feedManager.softRefresh(); loadEnabledStates() }
    
    private func disableAllPersonal() {
        for c in customFeeds.feeds {
            let key = "custom_enabled_\(c.id.uuidString)"
            enabledStates[key] = false
            UserDefaults.standard.set(false, forKey: key)
        }
        let _ = enabledStates
        feedManager.softRefresh()
    }
    
    private func discover() {
        isSearching = true; statusMessage = "Scanning..."
        Task {
            do {
                let feeds = try await AIDiscoveryService.shared.discoverFeeds(for: searchText)
                if !feeds.isEmpty {
                    var current = customFeeds.feeds; current.append(contentsOf: feeds)
                    customFeeds = CustomFeedStorage(feeds: current); UserDefaults.standard.set(customFeeds.rawValue, forKey: "customFeeds")
                    await MainActor.run { newlyAddedIDs = Set(feeds.map { $0.id }); statusMessage = "✓ Added \(feeds.count) sources."; searchText = ""; loadEnabledStates() }
                    feedManager.softRefresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { withAnimation { newlyAddedIDs.removeAll() } }
                } else { statusMessage = "No signals found." }
            } catch { statusMessage = "Connection error." }
            isSearching = false
        }
    }
    
    private func addRSS() {
        let urlString = rssURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlString.isEmpty { return }
        isAddingRSS = true; rssStatus = "Validating..."
        Task {
            do {
                let added = try await self.feedManager.validateAndAddCustomRSS(urlString: urlString, providedName: rssNameInput)
                await MainActor.run {
                    self.customFeeds = CustomFeedStorage(rawValue: UserDefaults.standard.string(forKey: "customFeeds") ?? "[]") ?? CustomFeedStorage(feeds: self.customFeeds.feeds)
                    newlyAddedIDs = [added.id]; rssStatus = "✓ Added"; rssURLInput = ""; rssNameInput = ""; loadEnabledStates()
                }
                feedManager.softRefresh()
            } catch { await MainActor.run { rssStatus = "✕ Invalid feed." } }
            await MainActor.run { isAddingRSS = false }
        }
    }
}

// MARK: - GLOBAL HELPER VIEWS

struct SignalIconTileView: View {
    let domain: String?
    let fallbackSystemIcon: String
    let tint: Color
    let size: CGFloat
    let tileSize: CGFloat
    @ObservedObject var faviconStore: FaviconStore
    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(FeedsTheme.inputBackground)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(FeedsTheme.divider.opacity(0.7), lineWidth: 1))

            if let domain, let img = faviconStore.image(for: domain, size: 64) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.16)).frame(width: size + 8, height: size + 8)
                    Image(nsImage: img)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .grayscale(1.0).opacity(0.95)
                }
            } else {
                Image(systemName: fallbackSystemIcon)
                    .font(.system(size: size, weight: .bold)).foregroundColor(tint)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct DataRow: View {
    let name: String
    @Binding var isEnabled: Bool
    let isPersonal: Bool
    let isNew: Bool
    let itemCount: Int // ✅ Correctly receives count
    let onDelete: (() -> Void)?
    
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 13, weight: .medium))
                    .foregroundColor(isEnabled ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                if isPersonal { Circle().fill(FeedsTheme.ai).frame(width: 5, height: 5).padding(.top, 2) }
            }.frame(width: 240, alignment: .leading)

            if isNew {
                Text("NEW").font(.system(size: 8, weight: .black)).padding(3)
                    .background(FeedsTheme.success).foregroundColor(.black).cornerRadius(2)
            }

            Spacer()

            // ✅ Live Item Count
            Text("\(itemCount)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(itemCount > 0 ? FeedsTheme.secondaryText : .red.opacity(0.6))
                .frame(width: 30, alignment: .trailing)
                .padding(.trailing, 4)

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                .frame(width: 44)

            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isHovering ? .red : FeedsTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .frame(width: 20)
            } else {
                Spacer().frame(width: 20)
            }
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 10)
        .background(isNew ? FeedsTheme.success.opacity(0.1) : (isHovering ? FeedsTheme.divider.opacity(0.3) : Color.clear))
        .onHover { isHovering = $0 }
    }
}

// MARK: - PREFERENCES VIEW
struct PreferencesView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var feedManager: FeedManager
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @State private var localScrollSpeed: Double = 1.0
    @AppStorage("tickerOpacity") private var tickerOpacity = 1.0
    @State private var localTickerOpacity: Double = 1.0
    @AppStorage("weatherCity") private var weatherCity = "Dublin"
    @State private var cityInput = ""
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes: Int = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ConfigSection(title: "RUN CONTROL") {
                    ConfigRow(label: "Refresh interval") {
                        Picker("", selection: $refreshIntervalMinutes) {
                            Text("5 min").tag(5); Text("10 min").tag(10); Text("15 min").tag(15); Text("30 min").tag(30); Text("60 min").tag(60)
                        }.labelsHidden().pickerStyle(.menu).frame(minWidth: 150)
                            .onChange(of: refreshIntervalMinutes) { _, newVal in self.feedManager.startAutoRefresh(interval: TimeInterval(newVal * 60)) }
                    }
                    ConfigRow(label: "Refresh now") {
                        Button(action: { self.feedManager.hardRefresh() }) {
                            HStack(spacing: 8) { Image(systemName: "arrow.clockwise.circle.fill"); Text("REFRESH NOW").font(.system(size: 11, weight: .bold)) }
                                .foregroundColor(.black).padding(.horizontal, 14).padding(.vertical, 8).background(FeedsTheme.utility).cornerRadius(6)
                        }.buttonStyle(.plain)
                    }
                }
                ConfigSection(title: "DISPLAY GEOMETRY") {
                    ConfigRow(label: "Target Monitor") {
                        Picker("", selection: $coordinator.preferredMonitorName) {
                            ForEach(NSScreen.screens, id: \.localizedName) { screen in
                                let idNum = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                                Text(screen.localizedName).tag(String(idNum))
                            }
                        }.labelsHidden().pickerStyle(.menu).frame(minWidth: 150)
                    }
                    ConfigRow(label: "Feed Bar Placement") {
                        CustomSegmentedControl(options: ["Bottom", "Top"], selection: Binding(get: { coordinator.tickerPositionString == "top" ? "Top" : "Bottom" }, set: { coordinator.tickerPositionString = ($0 == "Bottom" ? "bottom" : "top") }))
                    }
                    ConfigRow(label: "Feed Bar Size") {
                        CustomSegmentedControl(options: ["Compact", "Standard", "Large"], selection: Binding(get: { coordinator.tickerSize == 1 ? "Compact" : (coordinator.tickerSize == 2 ? "Standard" : "Large") }, set: { coordinator.tickerSize = ($0 == "Compact" ? 1 : ($0 == "Standard" ? 2 : 4)) }))
                    }
                    ConfigRow(label: "Always on top") {
                        Toggle("", isOn: $coordinator.alwaysOnTop).labelsHidden().toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                    }
                    ConfigRow(label: "Background Opacity") {
                        HStack {
                            Text("Invisible").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                            Slider(value: $localTickerOpacity, in: 0.0...1.0) { editing in if !editing { tickerOpacity = localTickerOpacity } }
                                .tint(FeedsTheme.utility)
                            Text("Solid").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                        }.frame(width: 200).onAppear { localTickerOpacity = tickerOpacity }
                    }
                }
                ConfigSection(title: "LIVE UTILITIES") {
                    ConfigRow(label: "Local Weather") {
                        HStack(spacing: 0) {
                            TextField("City...", text: $cityInput).textFieldStyle(.plain).padding(6).frame(width: 140).foregroundColor(FeedsTheme.primaryText).background(FeedsTheme.inputBackground).onAppear { cityInput = weatherCity }.onSubmit { updateWeather() }
                            Button(action: updateWeather) { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28).background(FeedsTheme.utility).foregroundColor(.black) }.buttonStyle(.plain)
                        }.cornerRadius(4)
                    }
                }
                ConfigSection(title: "STREAM KINETICS") {
                    ConfigRow(label: "Flow Speed") {
                        HStack {
                            Text("Slow").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                            Slider(value: $localScrollSpeed, in: 0.5...20.0) { editing in if !editing { scrollSpeed = localScrollSpeed } }
                                .tint(FeedsTheme.utility)
                            Text("Fast").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                        }.frame(width: 200).onAppear { localScrollSpeed = scrollSpeed }
                    }
                }
            }.padding(30)
        }
        .scrollIndicators(.visible)
    }
    private func updateWeather() { weatherCity = cityInput; self.feedManager.refreshWeatherOnly() }
}

// MARK: - 4. ABOUT TAB
struct AboutView: View {
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 40)).foregroundColor(FeedsTheme.ai)
            Text("FEEDS").font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundColor(FeedsTheme.primaryText)
            Text("Signal Layer v1.0").font(.caption).foregroundColor(FeedsTheme.secondaryText)
            VStack(spacing: 5) {
                Text("feeds.bar").font(.system(size: 13, weight: .bold)).foregroundColor(FeedsTheme.primaryText)
                Text("hello@feeds.bar").font(.system(size: 12)).foregroundColor(FeedsTheme.secondaryText)
            }.padding(.top, 10)
        }
    }
}

// MARK: - UI COMPONENTS
struct CustomSegmentedControl: View {
    let options: [String]; @Binding var selection: String
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button(action: { selection = option }) {
                    Text(option).font(.system(size: 11, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? .black : FeedsTheme.primaryText)
                        .padding(.vertical, 5).padding(.horizontal, 12).background(isSelected ? FeedsTheme.primaryText : Color.clear).cornerRadius(4)
                }.buttonStyle(.plain)
            }
        }.padding(2).background(FeedsTheme.inputBackground).cornerRadius(6)
    }
}

struct SidebarButton: View {
    let title, icon: String; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Rectangle().fill(isSelected ? FeedsTheme.ai : Color.clear).frame(width: 3)
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(isSelected ? FeedsTheme.primaryText : FeedsTheme.secondaryText).frame(width: 24)
                Text(title.uppercased()).font(.system(size: 11, weight: isSelected ? .bold : .medium)).foregroundColor(isSelected ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                Spacer()
            }.frame(height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain).background(isSelected ? FeedsTheme.divider.opacity(0.3) : Color.clear)
    }
}

struct ConfigSection<Content: View>: View {
    let title: String; let content: Content
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(FeedsTheme.ai)
            VStack(spacing: 0) { content }.padding(1).background(FeedsTheme.divider).cornerRadius(6)
        }
    }
}

struct ConfigRow<Content: View>: View {
    let label: String; let content: Content
    init(label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(FeedsTheme.primaryText).frame(width: 160, alignment: .leading)
            content
            Spacer()
        }.padding(14).background(FeedsTheme.surface)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square").foregroundColor(configuration.isOn ? FeedsTheme.ai : FeedsTheme.secondaryText).onTapGesture { configuration.isOn.toggle() }
            configuration.label
        }
    }
}
