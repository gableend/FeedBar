import SwiftUI

struct SourcesTab: View {
    @ObservedObject var feedManager: FeedManager
    @AppStorage("customFeeds") var customFeeds = CustomFeedStorage(feeds: [])

    @State private var filter: SourceFilter = .feeds
    @State private var searchText = ""
    @State private var isSearching = false
    
    // RSS Input State
    @State private var rssURLInput: String = ""
    @State private var rssNameInput: String = ""
    @State private var isAddingRSS: Bool = false
    @State private var rssStatus: String? = nil
    
    @State private var expandedCategories: [String: Bool] = [:]
    @State private var showDeleteConfirmation = false

    enum SourceFilter: String, CaseIterable {
        case feeds = "Feeds", system = "System"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection // Discovery + Manual RSS
            
            tabPicker
            
            // UNIFIED CONTENT CONTAINER
            VStack(spacing: 0) {
                bulkControlBar
                
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if filter == .system {
                            systemContent
                        } else {
                            feedContent
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
            .background(FeedsTheme.surface) // Unified background for the list area
            
            footerActions
        }
        .alert("Delete all personal feeds?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteAllTopics() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - HEADER SECTION
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("DISCOVER NEW FEEDS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.ai)
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(FeedsTheme.secondaryText)
                        TextField("Topic (e.g. 'SpaceX')...", text: $searchText).textFieldStyle(.plain).onSubmit { discover() }
                    }.padding(12).background(FeedsTheme.inputBackground).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.divider, lineWidth: 1))
                    
                    Button(action: discover) {
                        if isSearching { ProgressView().controlSize(.small) }
                        else { Text("FIND").font(.system(size: 11, weight: .bold)).padding(.horizontal, 16).padding(.vertical, 12).background(FeedsTheme.utility).cornerRadius(6).foregroundColor(.black) }
                    }.buttonStyle(.plain).disabled(isSearching || searchText.isEmpty)
                }
            }
            
            Divider().background(FeedsTheme.divider).opacity(0.3)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("ADD A NEW FEED BY URL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)) // Synchronized size 10
                    .foregroundColor(.blue).opacity(0.8)
                HStack(alignment: .top, spacing: 10) {
                    TextField("https://...", text: $rssURLInput).textFieldStyle(.plain).padding(10).background(FeedsTheme.inputBackground).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.divider, lineWidth: 1))
                    
                    TextField("Name", text: $rssNameInput).textFieldStyle(.plain).padding(10).frame(width: 140).background(FeedsTheme.inputBackground).cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(FeedsTheme.divider, lineWidth: 1))
                    
                    Button(action: addRSS) {
                        if isAddingRSS { ProgressView().controlSize(.small) }
                        else { Text("ADD").font(.system(size: 11, weight: .bold)).padding(.horizontal, 16).padding(.vertical, 12).background(FeedsTheme.utility).cornerRadius(6).foregroundColor(.black) }
                    }.buttonStyle(.plain).disabled(isAddingRSS || rssURLInput.isEmpty)
                }
            }
        }.padding(24).background(FeedsTheme.background) // Background matches top level
    }

    // MARK: - TAB PICKER
    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(SourceFilter.allCases, id: \.self) { tab in
                Button(action: { withAnimation(.spring(response: 0.3)) { filter = tab } }) {
                    VStack(spacing: 8) {
                        Text(tab.rawValue.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(filter == tab ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                        
                        // Active Indicator
                        Rectangle()
                            .fill(filter == tab ? FeedsTheme.ai : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
        .background(FeedsTheme.background)
    }

    // MARK: - IMPROVED BULK CONTROL BAR
    private var bulkControlBar: some View {
        HStack(spacing: 24) {
            // Left Justified Toggles
            HStack(spacing: 8) {
                Text("EXPAND ALL FEEDS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText)
                Toggle("", isOn: Binding(get: { isAllExpanded }, set: { toggleAllExpansion(to: $0) }))
                    .labelsHidden().toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
            }

            HStack(spacing: 8) {
                Text("ENABLE ALL FEEDS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText)
                Toggle("", isOn: Binding(get: { isBulkEnabled }, set: { setBulkEnabled($0) }))
                    .labelsHidden().toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
            }
            
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(FeedsTheme.surface)
        .overlay(Rectangle().frame(height: 1).foregroundColor(FeedsTheme.divider), alignment: .bottom)
    }

    // MARK: - LOGIC & HELPERS
    // ... (Keep existing discover, addRSS, binding, isBulkEnabled, setBulkEnabled, etc. logic) ...
    // Note: ensure toggleAllExpansion and isAllExpanded are present as previously defined.

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: key) },
            set: { UserDefaults.standard.set($0, forKey: key); feedManager.softRefresh() }
        )
    }

    private var isBulkEnabled: Bool {
        let items = feedManager.unifiedSources
        return items.allSatisfy { UserDefaults.standard.bool(forKey: $0.settingKey) }
    }

    private func setBulkEnabled(_ enabled: Bool) {
        for item in feedManager.unifiedSources { UserDefaults.standard.set(enabled, forKey: item.settingKey) }
        feedManager.softRefresh()
    }

    private var isAllExpanded: Bool {
        let categories = Set(feedManager.unifiedSources.map { $0.category })
        if categories.isEmpty { return true }
        return categories.allSatisfy { expandedCategories[$0] ?? true }
    }

    private func toggleAllExpansion(to expand: Bool) {
        let categories = Set(feedManager.unifiedSources.map { $0.category })
        withAnimation(.easeInOut(duration: 0.2)) {
            for cat in categories { expandedCategories[cat] = expand }
        }
    }
    
    private func addRSS() {
        let urlString = rssURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlString.isEmpty { return }
        isAddingRSS = true
        Task {
            do {
                _ = try await self.feedManager.validateAndAddCustomRSS(urlString: urlString, providedName: rssNameInput)
                await MainActor.run { rssURLInput = ""; rssNameInput = ""; rssStatus = "✓ Added" }
            } catch { await MainActor.run { rssStatus = "✕ Invalid feed." } }
            isAddingRSS = false
        }
    }
    
    private func discover() {
        isSearching = true
        Task {
            do {
                let feeds = try await AIDiscoveryService.shared.discoverFeeds(for: searchText)
                for f in feeds { feedManager.addCustomFeed(f) }
                searchText = ""
            } catch { }
            isSearching = false
        }
    }

    private var feedContent: some View {
        let grouped = Dictionary(grouping: feedManager.unifiedSources, by: { $0.category })
        return ForEach(grouped.keys.sorted(), id: \.self) { category in
            let items = grouped[category] ?? []
            let isExpanded = Binding(get: { expandedCategories[category] ?? true }, set: { expandedCategories[category] = $0 })
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        DataRow(name: item.name, isEnabled: binding(for: item.settingKey), isPersonal: item.isPersonal, isNew: false, itemCount: feedManager.itemCount(for: item.name), onDelete: item.isPersonal ? { deletePersonalFeed(id: item.id) } : nil)
                    }
                }
            } label: {
                HStack {
                    Text(category.uppercased()).font(.system(size: 11, weight: .bold)).foregroundColor(FeedsTheme.primaryText)
                    Spacer()
                    Text("\(items.count)").font(.system(size: 9)).foregroundColor(FeedsTheme.secondaryText).padding(4).background(Color.white.opacity(0.1)).cornerRadius(4)
                }.padding(.vertical, 8)
            }
            .padding(.horizontal, 24).accentColor(FeedsTheme.secondaryText)
        }
    }

    private var systemContent: some View {
        VStack(spacing: 0) {
            DataRow(name: "Global Market Trends", isEnabled: binding(for: "showTrends"), isPersonal: false, isNew: false, itemCount: 2, onDelete: nil)
            DataRow(name: "Futurism Signals", isEnabled: binding(for: "showPredictions"), isPersonal: false, isNew: false, itemCount: 1, onDelete: nil)
        }.padding(.horizontal, 24)
    }

    private var footerActions: some View {
        Group {
            if filter == .feeds && !customFeeds.feeds.isEmpty {
                HStack(spacing: 0) {
                    HStack {
                        Text("PERSONAL FEED VISIBILITY").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(FeedsTheme.secondaryText)
                        Toggle("", isOn: Binding(get: { isAllPersonalVisible }, set: { setAllPersonalVisibility(to: $0) }))
                        .labelsHidden().toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    Divider().frame(height: 20).background(FeedsTheme.divider)
                    Button(action: { showDeleteConfirmation = true }) {
                        HStack { Image(systemName: "trash.fill"); Text("DELETE ALL PERSONAL") }
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.red.opacity(0.7)).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.plain)
                }.background(Color.black.opacity(0.2)).overlay(Rectangle().frame(height: 1).foregroundColor(FeedsTheme.divider), alignment: .top)
            }
        }
    }
    
    private var isAllPersonalVisible: Bool { customFeeds.feeds.allSatisfy { UserDefaults.standard.bool(forKey: "custom_enabled_\($0.id.uuidString)") } }
    private func setAllPersonalVisibility(to enabled: Bool) { for c in customFeeds.feeds { UserDefaults.standard.set(enabled, forKey: "custom_enabled_\(c.id.uuidString)") }; feedManager.softRefresh() }
    private func deletePersonalFeed(id: UUID) { var current = customFeeds.feeds; current.removeAll { $0.id == id }; customFeeds = CustomFeedStorage(feeds: current); feedManager.softRefresh() }
    private func deleteAllTopics() { customFeeds = CustomFeedStorage(feeds: []); feedManager.softRefresh() }
}

