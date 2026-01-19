import Foundation
import Combine
import SwiftUI
import CoreLocation

@MainActor
final class FeedManager: NSObject, ObservableObject {
    // MARK: - PUBLISHED PROPERTIES
    @Published var items: [TickerItem] = []
    @Published var sources: [FeedSource] = []
    @Published var isReady: Bool = false
    
    // AI & Sentiment Properties
    @Published var newsSentiment: NewsSentiment?
    @Published var aiFutureSummary: String = "SCANNING HORIZON..."
    @Published var aiTrendSummary: String = "PULSING DATA..."
    @Published var aiScienceSummary: String = "RESEARCHING..."
    @Published var aiSportsSummary: String = "CHECKING SCORES..."
    @Published var aiResearchSummary: String = "MODELING..."
    @Published var currentWeatherTemp: String?
    @Published var itemsRevision: Int = 0
    
    // Internal State
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20.0
        return URLSession(configuration: c)
    }()
    
    private var refreshTask: Task<Void, Never>?
    private var allFeedItems: [TickerItem] = []
    
    var customFeedsMap: [UUID: CustomFeed] = [:]
    
    override init() {
        super.init()
        loadCustomFeeds() // This will work now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.hardRefresh()
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
        Task { AppLog.info("SYSTEM: 🩺 Manual Health Check Triggered...") }
    }
    
    // MARK: - FETCHING LOGIC
    
    private struct ServerEnvelope: Decodable {
        let items: [TickerItem]
        let sources: [FeedSource]
    }

    private func fetchFromNetlify() async {
        guard let url = URL(string: "https://feedbarserver.netlify.app/.netlify/functions/manifest") else { return }
        
        do {
            let (data, _) = try await session.data(from: url)
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            let envelope = try decoder.decode(ServerEnvelope.self, from: data)
            
            // ---------------------------------------------------------
            // 1. FILTER ZERO-ITEM SOURCES
            // ---------------------------------------------------------
            let activeSourceNames = Set(envelope.items.map { $0.sourceName })
            
            let validSources = envelope.sources.filter { source in
                activeSourceNames.contains(source.name)
            }
            
            // ---------------------------------------------------------
            // 2. PRE-WARM ICONS (Cache Injection)
            // ---------------------------------------------------------
            prewarmServerIcons(sources: validSources)

            // ---------------------------------------------------------
            // 3. LOGGING
            // ---------------------------------------------------------
            print("==================================================")
            print("📥 MANIFEST PROCESSED")
            print("   - Raw Items: \(envelope.items.count)")
            print("   - Raw Sources: \(envelope.sources.count)")
            print("   - Valid Sources: \(validSources.count)")
            print("--------------------------------------------------")

            // Update State
            await MainActor.run {
                self.sources = validSources
            }
            
            self.allFeedItems = envelope.items
            
            await rebuildUI()
            
            withAnimation { self.isReady = true }
            
        } catch {
            print("❌ Fetch failed: \(error)")
            await rebuildUI()
            self.isReady = true
        }
    }
    
    /// Downloads icons from the server manifest and injects them into FaviconStore
    private func prewarmServerIcons(sources: [FeedSource]) {
        Task.detached(priority: .background) {
            for source in sources {
                // Skip if no icon provided by server
                guard let urlString = source.icon_url, let url = URL(string: urlString) else { continue }
                
                // 1. Check if FaviconStore already has it (via the Google key format)
                let key = GoogleFaviconProvider.cacheKey(domain: source.domain, size: 128)
                if ImageMemoryCache.shared.get(key) != nil { continue }
                
                // 2. Download
                if let data = try? Data(contentsOf: url), let image = NSImage(data: data) {
                    // 3. Inject into the Main Thread Store
                    await MainActor.run {
                        FaviconStore.shared.inject(image: image, for: source.domain)
                    }
                }
            }
        }
    }
    
    // MARK: - FILTERING & MIXING LOGIC
    
    private func rebuildUI() async {
        let mixed = mixFeeds(allFeedItems)
        
        if let weather = await fetchWeather() {
            var final = mixed
            final.insert(weather, at: 0)
            self.items = Array(final.prefix(500))
        } else {
            self.items = Array(mixed.prefix(500))
        }
        
        self.itemsRevision += 1
    }
    
    private func mixFeeds(_ items: [TickerItem]) -> [TickerItem] {
        let currentCustomFeeds = loadCustomFeedsList()
        
        let allowedItems = items.filter { item in
            // 1. Weather is always allowed
            if item.value == "Weather" { return true }
            
            // 2. Custom Feeds (User added)
            if let customMatch = currentCustomFeeds.first(where: { $0.name == item.sourceName }) {
                let key = "custom_enabled_\(customMatch.id.uuidString)"
                return UserDefaults.standard.object(forKey: key) as? Bool ?? true
            }
            
            // 3. Server Feeds
            // PRIORITY A: Exact Name Match (Fixes the arXiv/multiple-feed issue)
            if let exactSource = sources.first(where: { $0.name == item.sourceName }) {
                return UserDefaults.standard.object(forKey: exactSource.settingKey) as? Bool ?? exactSource.defaultEnabled
            }
            
            // PRIORITY B: Domain Fallback
            if let domainSource = sources.first(where: { $0.domain == item.sourceDomain }) {
                return UserDefaults.standard.object(forKey: domainSource.settingKey) as? Bool ?? domainSource.defaultEnabled
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
    
    // MARK: - LOAD / SAVE HELPERS
    
    private func loadCustomFeeds() {
        if let data = UserDefaults.standard.data(forKey: "custom_feeds"),
           let saved = try? JSONDecoder().decode([CustomFeed].self, from: data) {
            for feed in saved {
                self.customFeedsMap[feed.id] = feed
            }
        }
    }
    
    // MARK: - WEATHER
    
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
                
                return TickerItem(
                    text: "\(city.uppercased()): \(tempStr)",
                    type: .news,
                    value: "Weather",
                    score: nil,
                    sourceDomain: "open-meteo.com",
                    sourceName: "Local Weather",
                    sourceIcon: nil,
                    mediaURL: nil,
                    isVideo: false,
                    articleURL: URL(string: "https://weather.com")!,
                    publishedAt: Date()
                )
            }
        } catch { return nil }
        return nil
    }
    
    // MARK: - SETTINGS HELPERS
    
    func validateAndAddCustomRSS(urlString: String, providedName: String) async throws -> CustomFeed {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        let (data, _) = try await session.data(from: url)
        
        guard let str = String(data: data, encoding: .utf8), str.contains("<rss") || str.contains("<feed") else {
            throw URLError(.cannotParseResponse)
        }
        
        // Pass STRING to normalizedDomain
        let domain = BrandIconProvider.normalizedDomain(urlString)
        let name = providedName.isEmpty ? domain : providedName
        
        let newFeed = CustomFeed(
            name: name,
            url: urlString,
            category: "RSS",
            domain: domain
        )
        
        DispatchQueue.main.async {
            var currentFeeds = self.loadCustomFeedsList()
            currentFeeds.append(newFeed)
            self.saveCustomFeedsList(currentFeeds)
            self.customFeedsMap[newFeed.id] = newFeed
        }
        
        return newFeed
    }
    
    func startAutoRefresh(interval: TimeInterval) {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.hardRefresh()
        }
    }
    
    func refreshWeatherOnly() {
        Task {
            if let w = await fetchWeather() {
                if let idx = self.items.firstIndex(where: { $0.value == "Weather" }) {
                    self.items[idx] = w
                } else {
                    self.items.insert(w, at: 0)
                }
            }
        }
    }
    
    // MARK: - PERSISTENCE
    
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
    
    // MARK: - COUNTER (CASE INSENSITIVE)
    func itemCount(for sourceName: String) -> Int {
        let needle = sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        return allFeedItems.filter {
            $0.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }.count
    }
}
