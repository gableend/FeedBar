import Foundation
import Combine
import SwiftUI
import CoreLocation

// MARK: - GLOBAL MODELS
struct UnifiedItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let category: String
    let settingKey: String
    let isPersonal: Bool
    let defaultEnabled: Bool
    let domain: String
}

@MainActor
final class FeedManager: NSObject, ObservableObject {
    // MARK: - PUBLISHED PROPERTIES
    @Published var items: [TickerItem] = []
    @Published var sources: [FeedSource] = []
    @Published var customFeeds: [CustomFeed] = []
    @Published var unifiedSources: [UnifiedItem] = []
    @Published var isReady: Bool = false
    
    @Published var newsSentiment: NewsSentiment?
    @Published var aiFutureSummary: String = "SCANNING HORIZON..."
    @Published var aiTrendSummary: String = "PULSING DATA..."
    @Published var aiScienceSummary: String = "RESEARCHING..."
    @Published var aiSportsSummary: String = "CHECKING SCORES..."
    @Published var aiResearchSummary: String = "MODELING..."
    
    @Published var currentWeatherTemp: String?
    @Published var itemsRevision: Int = 0
    
    // MARK: - INTERNAL STATE
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20.0
        return URLSession(configuration: c)
    }()
    
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>? // ✅ For modern Task-based timer
    private var allFeedItems: [TickerItem] = []
    var customFeedsMap: [UUID: CustomFeed] = [:]
    
    override init() {
        super.init()
        loadCustomFeeds()
        
        // Initial refresh
        Task {
            // Slight delay to allow environment to settle
            try? await Task.sleep(nanoseconds: 500_000_000)
            await fetchFromNetlify()
        }
    }
    
    // MARK: - PUBLIC API
    
    func hardRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await fetchFromNetlify() }
    }
    
    func softRefresh() {
        Task {
            await rebuildUI()
            self.itemsRevision += 1
        }
    }

    func runHealthCheckNow() {
        print("SYSTEM: 🩺 Manual Health Check Triggered...")
    }

    func getSignalTiles() -> [SignalTile] {
        var tiles: [SignalTile] = []
        var seenDomains = Set<String>()
        
        for item in unifiedSources {
            let domainKey = item.domain.isEmpty ? GoogleFaviconProvider.normalizedDomain(item.name) : item.domain
            
            if !seenDomains.contains(domainKey) {
                seenDomains.insert(domainKey)
                tiles.append(SignalTile(
                    id: item.id.uuidString,
                    tooltip: item.name,
                    domain: domainKey,
                    tint: FeedsTheme.categoryColor(for: item.category)
                ))
            }
        }
        return Array(tiles.prefix(180))
    }

    // MARK: - FETCHING LOGIC
    
    private func fetchFromNetlify() async {
        guard let url = URL(string: "https://feedbarserver.netlify.app/.netlify/functions/manifest") else { return }
        
        do {
            let (data, _) = try await session.data(from: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            struct ServerEnvelope: Decodable {
                let items: [TickerItem]
                let sources: [FeedSource]
            }
            
            let envelope = try decoder.decode(ServerEnvelope.self, from: data)
            let activeSourceNames = Set(envelope.items.map { $0.sourceName })
            let validSources = envelope.sources.filter { activeSourceNames.contains($0.name) }
            
            prewarmServerIcons(sources: validSources)

            self.sources = validSources
            self.allFeedItems = envelope.items
            
            await rebuildUI()
            withAnimation { self.isReady = true }
            
        } catch {
            print("❌ Fetch failed: \(error)")
            await rebuildUI()
            self.isReady = true
        }
    }
    
    private func prewarmServerIcons(sources: [FeedSource]) {
        Task {
            for source in sources {
                let key = GoogleFaviconProvider.cacheKey(domain: source.domain, size: 128)
                if ImageMemoryCache.shared.get(key) != nil { continue }
                
                guard let urlString = source.icon_url, let url = URL(string: urlString) else { continue }
                
                do {
                    let (data, _) = try await session.data(from: url)
                    if let image = NSImage(data: data) {
                        await MainActor.run {
                            FaviconStore.shared.inject(image: image, for: source.domain)
                        }
                    }
                } catch { continue }
            }
        }
    }
    
    // MARK: - UI RECONSTRUCTION
    
    private func rebuildUI() async {
        var unified: [UnifiedItem] = []
        var liveCategories = Set<String>()
        
        for source in sources {
            let cat = source.category ?? "General"
            liveCategories.insert(cat)
            unified.append(UnifiedItem(
                id: source.id,
                name: source.name,
                category: cat,
                settingKey: source.settingKey,
                isPersonal: false,
                defaultEnabled: source.defaultEnabled,
                domain: source.domain
            ))
        }
        
        let currentCustoms = loadCustomFeedsList()
        self.customFeeds = currentCustoms
        
        for c in currentCustoms {
            let savedCat = c.category ?? ""
            let bestCat: String
            
            // ✅ FIX: Removed 'await' because CategoryNormalizer.match is synchronous
            if !savedCat.isEmpty && savedCat != "General" && savedCat != "RSS" && liveCategories.contains(savedCat) {
                bestCat = savedCat
            } else {
                bestCat = CategoryNormalizer.match(feedName: c.name, url: c.url, liveCategories: liveCategories)
            }
            
            unified.append(UnifiedItem(
                id: c.id,
                name: c.name,
                category: bestCat,
                settingKey: "custom_enabled_\(c.id.uuidString)",
                isPersonal: true,
                defaultEnabled: true,
                domain: c.domain
            ))
        }
        
        self.unifiedSources = unified
        let mixed = mixFeeds(allFeedItems)
        var finalItems = mixed
        if let weather = await fetchWeather() { finalItems.insert(weather, at: 0) }
        
        self.items = Array(finalItems.prefix(500))
        self.itemsRevision += 1
    }

    /// ✅ FIXED: Replaced Timer with Task-based loop to solve MainActor capture violation
    func startAutoRefresh(interval: TimeInterval) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if !Task.isCancelled {
                    self.hardRefresh() // Safe because Task is isolated to the actor
                }
            }
        }
    }

    // MARK: - HELPERS & PERSISTENCE
    
    private func mixFeeds(_ items: [TickerItem]) -> [TickerItem] {
        let currentCustomFeeds = self.customFeeds
        let allowedItems = items.filter { item in
            if item.value == "Weather" { return true }
            if let customMatch = currentCustomFeeds.first(where: { $0.name == item.sourceName }) {
                return UserDefaults.standard.object(forKey: "custom_enabled_\(customMatch.id.uuidString)") as? Bool ?? true
            }
            if let exactSource = sources.first(where: { $0.name == item.sourceName }) {
                return UserDefaults.standard.object(forKey: exactSource.settingKey) as? Bool ?? exactSource.defaultEnabled
            }
            return true
        }
        
        var buckets: [String: [TickerItem]] = [:]
        for item in allowedItems {
            let cat = (item.value ?? "NEWS").uppercased()
            buckets[cat, default: []].append(item)
        }
        
        var out: [TickerItem] = []
        let categories = buckets.keys.sorted()
        var indices = [String: Int]()
        for cat in categories {
            indices[cat] = 0
            buckets[cat]?.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        }
        
        while out.count < 500 {
            var added = false
            for cat in categories {
                if let bucket = buckets[cat], let idx = indices[cat], idx < bucket.count {
                    out.append(bucket[idx])
                    indices[cat] = idx + 1
                    added = true
                }
            }
            if !added { break }
        }
        return out
    }
    
    private func loadCustomFeeds() {
        let feeds = loadCustomFeedsList()
        for feed in feeds { self.customFeedsMap[feed.id] = feed }
        self.customFeeds = feeds
    }

    private func loadCustomFeedsList() -> [CustomFeed] {
        if let jsonString = UserDefaults.standard.string(forKey: "customFeeds"),
           let data = jsonString.data(using: .utf8),
           let feeds = try? JSONDecoder().decode([CustomFeed].self, from: data) {
            return feeds
        }
        return []
    }

    private func saveCustomFeedsList(_ feeds: [CustomFeed]) {
        if let data = try? JSONEncoder().encode(feeds),
           let jsonString = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(jsonString, forKey: "customFeeds")
        }
    }

    func addCustomFeed(_ feed: CustomFeed) {
        var current = loadCustomFeedsList()
        current.append(feed)
        saveCustomFeedsList(current)
        self.customFeedsMap[feed.id] = feed
        softRefresh()
    }

    func removeCustomFeed(at offsets: IndexSet) {
        var current = loadCustomFeedsList()
        current.remove(atOffsets: offsets)
        saveCustomFeedsList(current)
        softRefresh()
    }

    func fetchWeather() async -> TickerItem? {
        let city = UserDefaults.standard.string(forKey: "weatherCity") ?? "Dublin"
        let geocoder = CLGeocoder()
        let location = await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            geocoder.geocodeAddressString(city) { placemarks, _ in
                cont.resume(returning: placemarks?.first?.location)
            }
        }
        
        guard let loc = location else { return nil }
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(loc.coordinate.latitude)&longitude=\(loc.coordinate.longitude)&current_weather=true")!
        
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let current = json["current_weather"] as? [String: Any],
               let temp = current["temperature"] as? Double {
                let tempStr = "\(Int(temp))°C"
                self.currentWeatherTemp = tempStr
                return TickerItem(text: "\(city.uppercased()): \(tempStr)", type: .news, value: "Weather", score: nil, sourceDomain: "open-meteo.com", sourceName: "Local Weather", sourceIcon: nil, mediaURL: nil, isVideo: false, articleURL: URL(string: "https://weather.com")!, publishedAt: Date())
            }
        } catch { return nil }
        return nil
    }

    func validateAndAddCustomRSS(urlString: String, providedName: String) async throws -> CustomFeed {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        guard let str = String(data: data, encoding: .utf8), str.contains("<rss") || str.contains("<feed") else {
            throw URLError(.cannotParseResponse)
        }
        
        let domain = BrandIconProvider.normalizedDomain(urlString)
        let name = providedName.isEmpty ? domain : providedName
        let newFeed = CustomFeed(name: name, url: urlString, category: "RSS", domain: domain)
        addCustomFeed(newFeed)
        return newFeed
    }

    func refreshWeatherOnly() {
        Task {
            if let w = await fetchWeather() {
                if let idx = self.items.firstIndex(where: { $0.value == "Weather" }) {
                    self.items[idx] = w
                } else {
                    self.items.insert(w, at: 0)
                }
                self.itemsRevision += 1
            }
        }
    }

    func itemCount(for sourceName: String) -> Int {
        let needle = sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allFeedItems.filter {
            $0.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }.count
    }
}
