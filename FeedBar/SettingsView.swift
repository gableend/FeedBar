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

// MARK: - WINDOW ACCESSOR (Centers Window on Launch)
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
                    .overlay(
                        Capsule()
                            .stroke(FeedsTheme.divider.opacity(0.8), lineWidth: 1)
                    )

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
        .accessibilityLabel(Text("Toggle"))
        .accessibilityValue(Text(configuration.isOn ? "On" : "Off"))
    }
}

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
            // MARK: LEFT SIDEBAR
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("FEEDS")
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                }
                .foregroundColor(FeedsTheme.primaryText)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SidebarButton(title: tab.rawValue, icon: icon(for: tab), isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }

                Spacer()

                HStack {
                    Circle().fill(FeedsTheme.success).frame(width: 6, height: 6)
                    Text("Signal Active")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .padding(20)
            }
            .frame(width: 200)
            .background(FeedsTheme.background)
            .overlay(Rectangle().frame(width: 1).foregroundColor(FeedsTheme.divider), alignment: .trailing)

            // MARK: RIGHT CONTENT
            ZStack {
                FeedsTheme.surface.ignoresSafeArea()

                switch selectedTab {
                case .home:
                    HomeView(coordinator: coordinator, feedManager: feedManager)
                case .preferences:
                    PreferencesView(coordinator: coordinator, feedManager: feedManager)
                case .sources:
                    SourcesView(feedManager: feedManager)
                case .about:
                    AboutView()
                }
            }
        }
        .frame(width: 800, height: 650)
        // Auto-center the window when this view appears
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

    private var gridCols: [GridItem] {
        [GridItem(.adaptive(minimum: tileSize, maximum: tileSize), spacing: 8, alignment: .center)]
    }

    var body: some View {
        VStack(spacing: 18) {

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

            // SIGNAL BOARD: icons only (favicons)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SIGNAL BOARD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(FeedsTheme.ai)
                    Spacer()
                    Text("\(signalTiles.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(FeedsTheme.secondaryText)
                }

                LazyVGrid(columns: gridCols, spacing: 8) {
                    ForEach(signalTiles, id: \.id) { tile in
                        SignalIconTileView(
                            domain: tile.domain,
                            fallbackSystemIcon: tile.fallbackIcon,
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
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(FeedsTheme.divider.opacity(0.7), lineWidth: 1))
                .onAppear {
                    let domains = signalTiles
                        .compactMap { $0.domain }
                        .map { GoogleFaviconProvider.normalizedDomain($0) }
                        .filter { GoogleFaviconProvider.isLikelyDomain($0) }

                    faviconStore.prewarm(domains: domains, size: 64)
                }
            }
            .padding(.horizontal, 26)

            // REDUCED WHITESPACE
            Divider()
                .background(FeedsTheme.divider)
                .padding(.horizontal, 80)
                .padding(.bottom, 6)

            VStack(spacing: 12) { // Reduced spacing
                Button(action: { coordinator.closeSettings() }) {
                    Text("MINIMIZE TO FEED BAR")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(FeedsTheme.background)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 28)
                        .background(FeedsTheme.utility) // Uses ORANGE (utility color)
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

            Spacer()
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

    private struct SignalTile {
        let id: String
        let tooltip: String
        let domain: String?
        let fallbackIcon: String
        let tint: Color
    }

    private var signalTiles: [SignalTile] {
        var tiles: [SignalTile] = []
        var seenDomains = Set<String>()

        for s in feedManager.sources {
            // FIX: Filter duplicates by name.
            // "Global Market Trends" and "Futurism Signals" are appended manually below, so skip them here.
            if s.name == "Global Market Trends" || s.name == "Futurism Signals" { continue }

            let normalized = GoogleFaviconProvider.normalizedDomain(s.domain)

            guard GoogleFaviconProvider.isLikelyDomain(normalized) else {
                tiles.append(SignalTile(id: "news-\(s.name)", tooltip: s.name, domain: nil, fallbackIcon: fallbackSymbolFor(name: s.name, domain: s.domain), tint: FeedsTheme.newsHighContrast))
                continue
            }

            guard !seenDomains.contains(normalized) else { continue }
            seenDomains.insert(normalized)

            tiles.append(SignalTile(id: "news-\(normalized)", tooltip: s.name, domain: normalized, fallbackIcon: fallbackSymbolFor(name: s.name, domain: s.domain), tint: FeedsTheme.newsHighContrast))
        }

        for c in customFeeds.feeds {
            let normalized = GoogleFaviconProvider.normalizedDomain(c.domain)
            let domainToUse: String?
            if GoogleFaviconProvider.isLikelyDomain(normalized) {
                if seenDomains.contains(normalized) { domainToUse = nil }
                else {
                    seenDomains.insert(normalized)
                    domainToUse = normalized
                }
            } else { domainToUse = nil }

            tiles.append(SignalTile(id: "topic-\(c.id.uuidString)", tooltip: c.name, domain: domainToUse, fallbackIcon: "dot.radiowaves.left.and.right", tint: FeedsTheme.ai))
        }

        // Manually appended at the end (This is the only place they should appear)
        tiles.append(SignalTile(id: "sys-trends", tooltip: "Global Market Trends", domain: nil, fallbackIcon: "chart.line.uptrend.xyaxis", tint: FeedsTheme.trends))
        tiles.append(SignalTile(id: "sys-future", tooltip: "Futurism Signals", domain: nil, fallbackIcon: "sparkles", tint: FeedsTheme.futurism))

        return Array(tiles.prefix(180))
    }

    private func fallbackSymbolFor(name: String, domain: String) -> String {
        let n = name.lowercased()
        let d = domain.lowercased()
        if n.contains("bbc") || d.contains("bbc") { return "globe.europe.africa.fill" }
        if n.contains("guardian") { return "newspaper.fill" }
        if n.contains("cnn") { return "bolt.horizontal.fill" }
        if n.contains("npr") { return "mic.fill" }
        if n.contains("openai") { return "brain.head.profile" }
        if n.contains("arxiv") { return "doc.text.fill" }
        if n.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if n.contains("security") || n.contains("hacker") { return "lock.shield.fill" }
        if n.contains("weather") { return "cloud.sun.fill" }
        if n.contains("tech") { return "cpu.fill" }
        if n.contains("finance") || n.contains("ft") || n.contains("bloomberg") { return "banknote.fill" }
        return "dot.radiowaves.left.and.right"
    }
}

// MARK: - Home tile view
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
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .grayscale(1.0)
                        .opacity(0.95)
                }
            } else {
                Image(systemName: fallbackSystemIcon)
                    .font(.system(size: size, weight: .bold))
                    .foregroundColor(tint)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .shadow(color: .black.opacity(isHovering ? 0.3 : 0), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onAppear {
            if let domain, !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                faviconStore.load(domain: domain, size: 64)
            }
        }
    }
}

// MARK: - 2. SOURCES VIEW
struct SourcesView: View {
    @ObservedObject var feedManager: FeedManager
    @AppStorage("customFeeds") var customFeeds = CustomFeedStorage(feeds: [])

    @State private var enabledStates: [String: Bool] = [:]
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var statusMessage: String? = nil
    @State private var newlyAddedIDs: Set<UUID> = []
    @State private var filter: SourceFilter = .all
    @State private var showDeleteConfirmation = false
    
    // Tracks open/closed state for RSS Categories
    @State private var expandedCategories: [String: Bool] = [:]

    // Add RSS
    @State private var rssURLInput: String = ""
    @State private var rssNameInput: String = ""
    @State private var isAddingRSS: Bool = false
    @State private var rssStatus: String? = nil
    @State private var scrollToID: UUID? = nil

    enum SourceFilter: String, CaseIterable {
        case all = "All", topics = "Topics", news = "RSS Feeds", system = "System"
    }

    var body: some View {
        VStack(spacing: 0) {

            // SEARCH + ADD RSS
            VStack(alignment: .leading, spacing: 14) {
                Text("SMART DISCOVERY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.ai)
                    .padding(.leading, 2)

                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(FeedsTheme.secondaryText)
                        ZStack(alignment: .leading) {
                            if searchText.isEmpty {
                                Text("Enter a topic...")
                                    .font(.system(size: 13))
                                    .foregroundColor(FeedsTheme.secondaryText)
                                    .allowsHitTesting(false)
                            }
                            TextField("", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .onSubmit { discover() }
                        }
                    }
                    .padding(12)
                    .background(FeedsTheme.inputBackground)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.divider, lineWidth: 1))

                    Button(action: discover) {
                        if isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("FIND FEEDS")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(FeedsTheme.utility)
                                .cornerRadius(6)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSearching || searchText.isEmpty)
                }

                // Add RSS row (Fixed Layout)
                VStack(alignment: .leading, spacing: 8) {
                    // 1. Blue Header
                    Text("ADD RSS FEEDS BY URL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(FeedsTheme.ai)

                    HStack(alignment: .bottom, spacing: 10) {
                        // URL Input - Flexible
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Feed URL").font(.system(size: 9)).foregroundColor(FeedsTheme.secondaryText)
                            ZStack(alignment: .leading) {
                                if rssURLInput.isEmpty {
                                    // 2. Fixed: Text(verbatim:) stops the URL from becoming blue
                                    Text(verbatim: "https://site.com/feed.xml")
                                        .font(.system(size: 12))
                                        .foregroundColor(FeedsTheme.secondaryText.opacity(0.5))
                                        .allowsHitTesting(false)
                                        .padding(.leading, 10)
                                }
                                TextField("", text: $rssURLInput)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(FeedsTheme.inputBackground)
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.divider, lineWidth: 1))
                            }
                        }

                        // Name Input - Fixed width to ensure button fits
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom Name").font(.system(size: 9)).foregroundColor(FeedsTheme.secondaryText)
                            ZStack(alignment: .leading) {
                                if rssNameInput.isEmpty {
                                    // 2. Consistent Grey Placeholder
                                    Text("e.g. Sky News")
                                        .font(.system(size: 12))
                                        .foregroundColor(FeedsTheme.secondaryText.opacity(0.5))
                                        .allowsHitTesting(false)
                                        .padding(.leading, 10)
                                }
                                TextField("", text: $rssNameInput)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .frame(width: 140)
                                    .background(FeedsTheme.inputBackground)
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.divider, lineWidth: 1))
                            }
                        }

                        // Button - Same size as FIND FEEDS
                        Button(action: addRSS) {
                            if isAddingRSS {
                                ProgressView().controlSize(.small)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                            } else {
                                Text("ADD RSS")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(FeedsTheme.utility) // Grey color
                                    .cornerRadius(6)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isAddingRSS || rssURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let rssStatus {
                        Text(rssStatus)
                            .font(.system(size: 11))
                            .foregroundColor(rssStatus.hasPrefix("✓") ? FeedsTheme.success : .red)
                            .padding(.leading, 4)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 4)

                if let msg = statusMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(FeedsTheme.success)
                        .padding(.leading, 4)
                        .transition(.opacity)
                }
            }
            .padding(24)
            .background(FeedsTheme.surface)

            // TABS
            HStack(spacing: 0) {
                ForEach(SourceFilter.allCases, id: \.self) { tab in
                    Button(action: { filter = tab }) {
                        VStack(spacing: 6) {
                            Text(tab.rawValue.uppercased())
                                .font(.system(size: 11, weight: filter == tab ? .bold : .medium))
                                .foregroundColor(filter == tab ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                            Rectangle()
                                .fill(filter == tab ? FeedsTheme.ai : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 10)
            .background(FeedsTheme.surface)
            .overlay(Rectangle().frame(height: 1).foregroundColor(FeedsTheme.divider), alignment: .bottom)

            // BULK TOGGLE
            HStack {
                Text(bulkLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isBulkEnabled },
                    set: { newValue in setBulkEnabled(newValue) }
                ))
                .labelsHidden()
                .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(FeedsTheme.surface)
            .overlay(Rectangle().frame(height: 1).foregroundColor(FeedsTheme.divider.opacity(0.6)), alignment: .bottom)

            // LIST CONTENT
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1, pinnedViews: []) {

                        // TOPICS
                        if filter == .all || filter == .topics {
                            HStack {
                                Text("TOPICS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(FeedsTheme.secondaryText)
                                Spacer()
                                if !customFeeds.feeds.isEmpty {
                                    Button("DELETE ALL") { showDeleteConfirmation = true }
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.red)
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(20)
                            .background(FeedsTheme.divider.opacity(0.3))

                            ForEach(customFeeds.feeds) { feed in
                                DataRow(name: feed.name, type: "TOPIC", typeColor: FeedsTheme.ai, isEnabled: cachedBinding(key: "custom_enabled_\(feed.id.uuidString)", defaultVal: true), isNew: newlyAddedIDs.contains(feed.id)) {
                                    deleteFeed(feed)
                                }
                                .id(feed.id)
                            }
                        }

                        // RSS FEEDS (Grouped by Category)
                        if filter == .all || filter == .news {
                            HStack {
                                Text("RSS FEEDS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(FeedsTheme.secondaryText)
                                Spacer()
                            }
                            .padding(20)
                            .background(FeedsTheme.divider.opacity(0.3))

                            let grouped = Dictionary(grouping: feedManager.sources, by: { $0.category })
                            let sortedCategories = grouped.keys.sorted()

                            ForEach(sortedCategories, id: \.self) { category in
                                // Manually implemented expandable section with binding
                                let isExpandedBinding = Binding(
                                    get: { expandedCategories[category] ?? false },
                                    set: { expandedCategories[category] = $0 }
                                )
                                
                                VStack(spacing: 0) {
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            isExpandedBinding.wrappedValue.toggle()
                                        }
                                    }) {
                                        HStack {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(FeedsTheme.secondaryText)
                                                .rotationEffect(.degrees(isExpandedBinding.wrappedValue ? 90 : 0))
                                                .frame(width: 14)
                                            
                                            Text(category.uppercased())
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(FeedsTheme.primaryText)
                                            
                                            Spacer()
                                        }
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 20)
                                        .background(Color.white.opacity(0.01))
                                    }
                                    .buttonStyle(.plain)

                                    if isExpandedBinding.wrappedValue {
                                        ForEach(grouped[category] ?? []) { source in
                                            DataRow(
                                                name: source.name,
                                                type: "RSS",
                                                typeColor: FeedsTheme.newsHighContrast,
                                                isEnabled: cachedBinding(key: source.settingKey, defaultVal: source.defaultEnabled),
                                                isNew: false,
                                                onDelete: nil
                                            )
                                            .padding(.leading, 14)
                                            .transition(.opacity)
                                        }
                                    }
                                }
                            }
                        }

                        // SYSTEM
                        if filter == .all || filter == .system {
                            HStack {
                                Text("SYSTEM")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(FeedsTheme.secondaryText)
                                Spacer()
                            }
                            .padding(20)
                            .background(FeedsTheme.divider.opacity(0.3))

                            DataRow(name: "Global Market Trends", type: "TRENDS", typeColor: FeedsTheme.trends, isEnabled: cachedBinding(key: "showTrends", defaultVal: true), isNew: false, onDelete: nil)
                            DataRow(name: "Futurism Signals", type: "FUTURE", typeColor: FeedsTheme.futurism, isEnabled: cachedBinding(key: "showPredictions", defaultVal: true), isNew: false, onDelete: nil)
                        }
                    }
                    .padding(.bottom, 40)
                }
                .background(FeedsTheme.surface)
                .onChange(of: scrollToID) { _, newID in
                    guard let id = newID else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { scrollToID = nil }
                }
            }
            .alert("Delete all smart topics?", isPresented: $showDeleteConfirmation) {
                Button("Delete All", role: .destructive) { deleteAllTopics() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This action cannot be undone.") }
        }
        .onAppear { loadEnabledStates() }
    }

    // MARK: - Logic
    private var bulkLabel: String {
        switch filter {
        case .all: return "ENABLE ALL SOURCES"
        case .topics: return "ENABLE ALL TOPICS"
        case .news: return "ENABLE ALL FEEDS"
        case .system: return "ENABLE ALL SYSTEM"
        }
    }

    private var isBulkEnabled: Bool {
        let keys = bulkKeysForCurrentFilter()
        guard !keys.isEmpty else { return true }
        return keys.allSatisfy { enabledStates[$0] ?? defaultValueForKey($0) }
    }

    private func setBulkEnabled(_ enabled: Bool) {
        let keys = bulkKeysForCurrentFilter()
        guard !keys.isEmpty else { return }
        for k in keys { enabledStates[k] = enabled }
        DispatchQueue.global(qos: .userInitiated).async {
            for k in keys { UserDefaults.standard.set(enabled, forKey: k) }
            DispatchQueue.main.async { feedManager.softRefresh() }
        }
    }

    private func bulkKeysForCurrentFilter() -> [String] {
        switch filter {
        case .all:
            var keys: [String] = []
            keys.append(contentsOf: customFeeds.feeds.map { "custom_enabled_\($0.id.uuidString)" })
            keys.append(contentsOf: feedManager.sources.map { $0.settingKey })
            keys.append(contentsOf: ["showTrends", "showPredictions"])
            return keys
        case .topics: return customFeeds.feeds.map { "custom_enabled_\($0.id.uuidString)" }
        case .news: return feedManager.sources.map { $0.settingKey }
        case .system: return ["showTrends", "showPredictions"]
        }
    }

    private func defaultValueForKey(_ key: String) -> Bool {
        if key == "showTrends" { return true }
        if key == "showPredictions" { return true }
        if key.hasPrefix("custom_enabled_") { return true }
        if let source = feedManager.sources.first(where: { $0.settingKey == key }) { return source.defaultEnabled }
        return true
    }

    private func loadEnabledStates() {
        for feed in customFeeds.feeds {
            let key = "custom_enabled_\(feed.id.uuidString)"
            enabledStates[key] = (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
        }
        for source in feedManager.sources {
            enabledStates[source.settingKey] = (UserDefaults.standard.object(forKey: source.settingKey) as? Bool) ?? source.defaultEnabled
        }
        enabledStates["showTrends"] = (UserDefaults.standard.object(forKey: "showTrends") as? Bool) ?? true
        enabledStates["showPredictions"] = (UserDefaults.standard.object(forKey: "showPredictions") as? Bool) ?? true
    }

    private func cachedBinding(key: String, defaultVal: Bool) -> Binding<Bool> {
        Binding(
            get: { enabledStates[key] ?? defaultVal },
            set: { newValue in
                enabledStates[key] = newValue
                DispatchQueue.global(qos: .userInitiated).async {
                    UserDefaults.standard.set(newValue, forKey: key)
                    DispatchQueue.main.async { feedManager.softRefresh() }
                }
            }
        )
    }

    private func deleteAllTopics() {
        customFeeds = CustomFeedStorage(feeds: [])
        UserDefaults.standard.set(customFeeds.rawValue, forKey: "customFeeds")
        feedManager.softRefresh()
        loadEnabledStates()
    }

    private func deleteFeed(_ feed: CustomFeed) {
        var current = customFeeds.feeds
        current.removeAll { $0.id == feed.id }
        customFeeds = CustomFeedStorage(feeds: current)
        UserDefaults.standard.set(customFeeds.rawValue, forKey: "customFeeds")
        feedManager.softRefresh()
        loadEnabledStates()
    }

    private func discover() {
        isSearching = true
        statusMessage = "Scanning signal sources..."
        Task {
            do {
                let feeds = try await AIDiscoveryService.shared.discoverFeeds(for: searchText)
                if !feeds.isEmpty {
                    var current = customFeeds.feeds
                    current.append(contentsOf: feeds)
                    customFeeds = CustomFeedStorage(feeds: current)
                    UserDefaults.standard.set(customFeeds.rawValue, forKey: "customFeeds")
                    feedManager.softRefresh()

                    await MainActor.run {
                        filter = .topics
                        newlyAddedIDs = Set(feeds.map { $0.id })
                        statusMessage = "✓ Added \(feeds.count) sources for '\(searchText)'."
                        searchText = ""
                        loadEnabledStates()
                        scrollToID = feeds.first?.id
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        withAnimation { newlyAddedIDs.removeAll() }
                    }
                } else {
                    statusMessage = "No high-quality signals found."
                }
            } catch {
                statusMessage = "Connection error."
            }
            isSearching = false
        }
    }

    private func addRSS() {
        let urlString = rssURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlString.isEmpty { return }
        isAddingRSS = true
        rssStatus = "Checking RSS feed…"

        Task {
            do {
                let added = try await feedManager.validateAndAddCustomRSS(urlString: urlString, providedName: rssNameInput)
                await MainActor.run {
                    self.customFeeds = CustomFeedStorage(rawValue: UserDefaults.standard.string(forKey: "customFeeds") ?? "[]") ?? CustomFeedStorage(feeds: self.customFeeds.feeds)
                    filter = .topics
                    newlyAddedIDs = [added.id]
                    scrollToID = added.id
                    rssStatus = "✓ Added RSS: \(added.name)"
                    rssURLInput = ""
                    rssNameInput = ""
                    loadEnabledStates()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    withAnimation { newlyAddedIDs.removeAll() }
                }
                feedManager.softRefresh()
            } catch {
                await MainActor.run { rssStatus = "✕ Invalid feed URL or empty/unparseable feed." }
            }
            await MainActor.run { isAddingRSS = false }
        }
    }
}

// MARK: - 3. PREFERENCES VIEW
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
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                            Text("60 min").tag(60)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 150)
                        .onChange(of: refreshIntervalMinutes) { _, newVal in
                            let seconds = TimeInterval(max(1, newVal) * 60)
                            feedManager.startAutoRefresh(interval: seconds)
                        }
                    }

                    ConfigRow(label: "Refresh now") {
                        Button(action: { feedManager.hardRefresh() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                Text("REFRESH NOW")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(FeedsTheme.utility)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ConfigSection(title: "DISPLAY GEOMETRY") {
                    ConfigRow(label: "Target Monitor") {
                        Picker("", selection: $coordinator.preferredMonitorName) {
                            ForEach(NSScreen.screens, id: \.localizedName) { screen in
                                let idNum = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                                Text(screen.localizedName).tag(String(idNum))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 150)
                    }

                    ConfigRow(label: "Feed Bar Placement") {
                        CustomSegmentedControl(options: ["Bottom", "Top"], selection: Binding(
                            get: { coordinator.tickerPositionString == "top" ? "Top" : "Bottom" },
                            set: { val in coordinator.tickerPositionString = (val == "Bottom" ? "bottom" : "top") }
                        ))
                    }

                    ConfigRow(label: "Feed Bar Size") {
                        CustomSegmentedControl(options: ["Compact", "Standard", "Large"], selection: Binding(
                            get: { coordinator.tickerSize == 1 ? "Compact" : (coordinator.tickerSize == 2 ? "Standard" : "Large") },
                            set: { val in coordinator.tickerSize = (val == "Compact" ? 1 : (val == "Standard" ? 2 : 4)) }
                        ))
                    }

                    // ADDED: Always on Top Toggle with correct label
                    ConfigRow(label: "Always on top") {
                        Toggle("", isOn: $coordinator.alwaysOnTop)
                            .labelsHidden()
                            .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                    }
                   
                    ConfigRow(label: "Background Opacity") {
                        HStack {
                            Text("Invisible").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                            ZStack {
                                Capsule().fill(FeedsTheme.secondaryText.opacity(0.3)).frame(height: 4)
                                Slider(value: $localTickerOpacity, in: 0.0...1.0) { editing in
                                    if !editing { tickerOpacity = localTickerOpacity }
                                }
                                .tint(FeedsTheme.utility)
                            }
                            Text("Solid").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                        }
                        .frame(width: 200)
                        .onAppear { localTickerOpacity = tickerOpacity }
                    }
                }

                ConfigSection(title: "LIVE UTILITIES") {
                    ConfigRow(label: "Local Weather") {
                        HStack(spacing: 0) {
                            TextField("City...", text: $cityInput)
                                .textFieldStyle(.plain)
                                .padding(6)
                                .frame(width: 140)
                                .foregroundColor(FeedsTheme.primaryText)
                                .background(FeedsTheme.inputBackground)
                                .onAppear { cityInput = weatherCity }
                                .onSubmit { updateWeather() }

                            Button(action: updateWeather) {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 28, height: 28)
                                    .background(FeedsTheme.utility)
                                    .foregroundColor(.black)
                            }
                            .buttonStyle(.plain)
                        }
                        .cornerRadius(4)
                    }
                }

                ConfigSection(title: "STREAM KINETICS") {
                    ConfigRow(label: "Flow Speed") {
                        HStack {
                            Text("Slow").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                            ZStack {
                                Capsule().fill(FeedsTheme.secondaryText.opacity(0.3)).frame(height: 4)
                                // UPDATED: Slider range increased to 20.0 to match Turbo mode
                                Slider(value: $localScrollSpeed, in: 0.5...20.0) { editing in
                                    if !editing { scrollSpeed = localScrollSpeed }
                                }
                                .tint(FeedsTheme.utility)
                            }
                            Text("Fast").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                        }
                        .frame(width: 200)
                        .onAppear { localScrollSpeed = scrollSpeed }
                    }
                }
            }
            .padding(30)
        }
        .scrollIndicators(.visible)
        .onAppear {
            let seconds = TimeInterval(max(1, refreshIntervalMinutes) * 60)
            feedManager.startAutoRefresh(interval: seconds)
        }
    }

    private func updateWeather() {
        weatherCity = cityInput
        feedManager.refreshWeatherOnly()
    }
}

// MARK: - 4. ABOUT TAB
struct AboutView: View {
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundColor(FeedsTheme.ai)

            Text("FEEDS")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(FeedsTheme.primaryText)

            Text("Signal Layer v1.0")
                .font(.caption)
                .foregroundColor(FeedsTheme.secondaryText)

            VStack(spacing: 5) {
                Text("feeds.bar")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(FeedsTheme.primaryText)
                Text("hello@feeds.bar")
                    .font(.system(size: 12))
                    .foregroundColor(FeedsTheme.secondaryText)
            }
            .padding(.top, 10)
        }
    }
}

// MARK: - UI COMPONENTS
struct CustomSegmentedControl: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button(action: { selection = option }) {
                    Text(option)
                        .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? .black : FeedsTheme.primaryText)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 12)
                        .background(isSelected ? FeedsTheme.primaryText : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(FeedsTheme.inputBackground)
        .cornerRadius(6)
    }
}

struct DataRow: View {
    let name: String
    let type: String
    let typeColor: Color
    @Binding var isEnabled: Bool
    let isNew: Bool
    let onDelete: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isEnabled ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                .frame(width: 220, alignment: .leading)

            if isNew {
                Text("NEW")
                    .font(.system(size: 9, weight: .black))
                    .padding(4)
                    .background(FeedsTheme.success)
                    .foregroundColor(.black)
                    .cornerRadius(2)
            }

            Text(type)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(typeColor.opacity(0.2))
                .foregroundColor(typeColor)
                .cornerRadius(2)
                .frame(width: 80, alignment: .leading)

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                .frame(width: 44)

            Spacer()

            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isHovering ? .red : FeedsTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(isNew ? FeedsTheme.success.opacity(0.1) : (isHovering ? FeedsTheme.divider.opacity(0.3) : Color.clear))
        .overlay(Rectangle().frame(width: 2).foregroundColor(isNew ? FeedsTheme.success : Color.clear), alignment: .leading)
        .onHover { isHovering = $0 }
    }
}

struct SidebarButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Rectangle().fill(isSelected ? FeedsTheme.ai : Color.clear).frame(width: 3)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                    .frame(width: 24)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                Spacer()
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? FeedsTheme.divider.opacity(0.3) : Color.clear)
    }
}

struct ConfigSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(FeedsTheme.ai)
            VStack(spacing: 0) { content }
                .padding(1)
                .background(FeedsTheme.divider)
                .cornerRadius(6)
        }
    }
}

struct ConfigRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(FeedsTheme.primaryText)
                .frame(width: 160, alignment: .leading)
            content
            Spacer()
        }
        .padding(14)
        .background(FeedsTheme.surface)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isOn ? FeedsTheme.ai : FeedsTheme.secondaryText)
                .onTapGesture { configuration.isOn.toggle() }
            configuration.label
        }
    }
}
