import Foundation
import Combine
import SwiftUI
import CoreLocation

@MainActor
final class FeedManager: NSObject, ObservableObject {
    // MARK: - PUBLISHED PROPERTIES
    @Published var items: [TickerItem] = []
    @Published var sources: [FeedSource] = [] // Keeps track of RSS sources
    @Published var isReady: Bool = false
    
    // AI & Sentiment Properties
    @Published var newsSentiment: NewsSentiment?
    @Published var aiFutureSummary: String = "SCANNING HORIZON..."
    @Published var aiTrendSummary: String = "PULSING DATA..."
    @Published var aiScienceSummary: String = "RESEARCHING..."
    @Published var aiSportsSummary: String = "CHECKING SCORES..."
    @Published var aiResearchSummary: String = "MODELING..."
    @Published var currentWeatherTemp: String?
    @Published var itemsRevision: Int = 0 // Triggers Ticker re-draws
    
    // Internal State
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20.0
        return URLSession(configuration: c)
    }()
    
    private var refreshTask: Task<Void, Never>?
    private var allFeedItems: [TickerItem] = [] // Stores everything before filtering
    
    // Custom Feeds Map (for O(1) lookup during filtering)
    var customFeedsMap: [UUID: CustomFeed] = [:]
    
    override init() {
        super.init()
        // Load custom feeds from storage immediately
        loadCustomFeeds()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.hardRefresh()
        }
    }
    
    // MARK: - PUBLIC API
    
    /// Re-downloads data from the net (Expensive)
    func hardRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await fetchFromNetlify() }
    }
    
    /// Re-shuffles and Re-filters existing data (Cheap)
    /// Call this when toggling "SpaceX" or "Trump" buttons.
    func softRefresh() {
        Task {
            await rebuildUI()
            // Increment revision to force TickerView to redraw
            self.itemsRevision += 1
        }
    }
    
    func runHealthCheckNow() {
        Task { AppLog.info("SYSTEM: 🩺 Manual Health Check Triggered...") }
    }
    
    // MARK: - FETCHING LOGIC
    
    // 1. Define the Envelope to match the new manifest structure
        private struct ServerEnvelope: Decodable {
            let items: [TickerItem]
            let sources: [FeedSource] // <--- The new Source of Truth
        }

    private func fetchFromNetlify() async {
            // ✅ VERIFY THIS URL matches your actual running server
            guard let url = URL(string: "https://feedbarserver.netlify.app/.netlify/functions/manifest") else { return }
            
            do {
                let (data, _) = try await session.data(from: url)
                
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                
                // 2. Decode the Full Envelope
                let envelope = try decoder.decode(ServerEnvelope.self, from: data)
                
                // 3. Update the Data Stores
                // We update `sources` immediately so the Settings View knows the categories
                await MainActor.run {
                    self.sources = envelope.sources
                }
                
                self.allFeedItems = envelope.items
                
                await rebuildUI()
                
                withAnimation { self.isReady = true }
                print("✅ Success: Loaded \(self.allFeedItems.count) items and \(self.sources.count) sources.")
                
            } catch {
                print("❌ Fetch failed: \(error)")
                await rebuildUI()
                self.isReady = true
            }
        }
    
        
    
    // MARK: - FILTERING & MIXING LOGIC (THE IDENTITY PIVOT)
    
    private func rebuildUI() async {
        // 1. Filter and Mix
        let mixed = mixFeeds(allFeedItems)
        
        // 2. Add Weather if enabled
        if let weather = await fetchWeather() {
            var final = mixed
            final.insert(weather, at: 0)
            self.items = Array(final.prefix(500))
        } else {
            self.items = Array(mixed.prefix(500))
        }
        
        // 3. Update Revision
        self.itemsRevision += 1
    }
    
    private func mixFeeds(_ items: [TickerItem]) -> [TickerItem] {
        // STEP 1: FILTERING (The "Identity Pivot")
        // We only allow items if their source name is toggled ON in UserDefaults.
        
        let allowedItems = items.filter { item in
            // Always keep Weather
            if item.value == "Weather" { return true }
            
            // Check Identity (Name-Based Toggle)
            // Use the item's sourceName (e.g., "SpaceX") to check the preference
            let cleanName = item.sourceName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "toggle_name_\(cleanName)"
            
            // Default to TRUE if the key doesn't exist yet (so new feeds show up)
            return UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
        }
        
        // STEP 2: BUCKETING (Category Mixing)
        var buckets: [String: [TickerItem]] = [:]
        for item in allowedItems {
            let cat = (item.value ?? "NEWS").uppercased()
            buckets[cat, default: []].append(item)
        }
        
        // STEP 3: INTERLEAVING (Round-Robin)
        var out: [TickerItem] = []
        let categories = buckets.keys.sorted()
        var indices = [String: Int]()
        for cat in categories {
            indices[cat] = 0
            // Sort each bucket by date (newest first)
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
        // Load custom feeds so we have them ready for matching (future proofing)
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
                // Update the published property for the UI Widget
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
    // MARK: - SETTINGS VIEW HELPERS
    
    func validateAndAddCustomRSS(urlString: String, providedName: String) async throws -> CustomFeed {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        // 1. Validate by fetching
        let (data, _) = try await session.data(from: url)
        
        // 2. Simple XML check (robust parsing happens later)
        guard let str = String(data: data, encoding: .utf8), str.contains("<rss") || str.contains("<feed") else {
            throw URLError(.cannotParseResponse)
        }
        
        // 3. Create CustomFeed
        let domain = BrandIconProvider.normalizedDomain(urlString)
        let name = providedName.isEmpty ? domain : providedName
        
        let newFeed = CustomFeed(
            name: name,
            url: urlString,
            category: "RSS", // Default category
            domain: domain
        )
        
        // 4. Save to Storage
        DispatchQueue.main.async {
            var currentFeeds = self.loadCustomFeedsList()
            currentFeeds.append(newFeed)
            self.saveCustomFeedsList(currentFeeds)
            self.customFeedsMap[newFeed.id] = newFeed
        }
        
        return newFeed
    }
    
    func startAutoRefresh(interval: TimeInterval) {
        // Simple timer logic
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.hardRefresh()
        }
    }
    
    func refreshWeatherOnly() {
        Task {
            if let w = await fetchWeather() {
                // Find existing weather item index or insert
                if let idx = self.items.firstIndex(where: { $0.value == "Weather" }) {
                    self.items[idx] = w
                } else {
                    self.items.insert(w, at: 0)
                }
            }
        }
    }
    
    // MARK: - PERSISTENCE HELPERS
        
        private func loadCustomFeedsList() -> [CustomFeed] {
            // Read as String to match SettingsView's @AppStorage format
            if let jsonString = UserDefaults.standard.string(forKey: "customFeeds"),
               let data = jsonString.data(using: .utf8),
               let feeds = try? JSONDecoder().decode([CustomFeed].self, from: data) {
                return feeds
            }
            return []
        }
        
        private func saveCustomFeedsList(_ feeds: [CustomFeed]) {
            // Save as String to match SettingsView's @AppStorage format
            if let data = try? JSONEncoder().encode(feeds),
               let jsonString = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(jsonString, forKey: "customFeeds")
            }
        }
}
