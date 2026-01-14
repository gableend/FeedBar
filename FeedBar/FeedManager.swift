//
//  FeedManager.swift
//  FeedBar
//

import Foundation
import Combine
import SwiftUI
import CoreLocation
import QuartzCore

// MARK: - Staleness helpers
enum Staleness {
    nonisolated static func cutoff(maxDays: Int, now: Date) -> Date {
        if let d = Calendar.current.date(byAdding: .day, value: -maxDays, to: now) { return d }
        return now.addingTimeInterval(TimeInterval(-maxDays * 24 * 60 * 60))
    }

    nonisolated static func isStale(_ publishedAt: Date?, maxDays: Int, now: Date) -> Bool {
        guard let d = publishedAt else { return false }
        return d < cutoff(maxDays: maxDays, now: now)
    }
}

// MARK: - Safe, Non-Blocking Concurrency Primitives
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ value: Int) { self.permits = max(1, value) }
    func acquire() async {
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { cont in waiters.append(cont) }
    }
    func release() {
        if !waiters.isEmpty { let next = waiters.removeFirst(); next.resume() }
        else { permits += 1 }
    }
}

actor HostLimiter {
    private let perHostLimit: Int
    private var inFlight: [String: Int] = [:]
    private var queues: [String: [CheckedContinuation<Void, Never>]] = [:]
    init(perHostLimit: Int) { self.perHostLimit = max(1, perHostLimit) }
    func acquire(host: String) async {
        let h = host.lowercased()
        let current = inFlight[h] ?? 0
        if current < perHostLimit { inFlight[h] = current + 1; return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in queues[h, default: []].append(cont) }
    }
    func release(host: String) {
        let h = host.lowercased()
        let current = inFlight[h] ?? 0
        guard current > 0 else { return }
        if var q = queues[h], !q.isEmpty {
            let cont = q.removeFirst()
            queues[h] = q
            cont.resume()
            return
        }
        inFlight[h] = current - 1
    }
}

// MARK: - Safe dedupe key
struct TickerKey: Hashable, Sendable {
    let text: String; let sourceName: String; let articleURL: String
    init(_ item: TickerItem) {
        self.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceName = item.sourceName
        self.articleURL = item.articleURL.absoluteString
    }
}

// MARK: - Background RSS fetcher
actor FeedFetcher {
    struct FetchMeta: Sendable {
        let statusCode: Int?; let requestId: String?; let contentType: String?; let bytes: Int; let durationMs: Int; let finalURL: String
    }
    private let session: URLSession; private let userAgent: String; private let acceptHeader: String; private let acceptLanguage: String; private let maxItemAgeDays: Int; private let debug: @Sendable (String) -> Void
    private let networkGate: AsyncSemaphore; private let hostGate: HostLimiter

    init(session: URLSession, userAgent: String, acceptHeader: String, acceptLanguage: String, maxItemAgeDays: Int, maxConcurrentRequests: Int, perHostLimit: Int, debug: @escaping @Sendable (String) -> Void) {
        self.session = session; self.userAgent = userAgent; self.acceptHeader = acceptHeader; self.acceptLanguage = acceptLanguage
        self.maxItemAgeDays = maxItemAgeDays; self.debug = debug
        self.networkGate = AsyncSemaphore(maxConcurrentRequests); self.hostGate = HostLimiter(perHostLimit: perHostLimit)
    }

    func fetchRSSWithMeta(source: FeedSource, type: TickerType, topicName: String, forceNetwork: Bool) async -> ([TickerItem], FetchMeta) {
        guard let url = URL(string: source.url) else { return ([], FetchMeta(statusCode: nil, requestId: nil, contentType: nil, bytes: 0, durationMs: 0, finalURL: source.url)) }
        await networkGate.acquire()
        await hostGate.acquire(host: source.domain)
        defer { Task { await self.hostGate.release(host: source.domain) }; Task { await self.networkGate.release() } }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30.0
            request.cachePolicy = forceNetwork ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
            
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode
            let durMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0)

            if let code, !(200...299).contains(code) {
                return ([], FetchMeta(statusCode: code, requestId: nil, contentType: nil, bytes: data.count, durationMs: durMs, finalURL: source.url))
            }

            let parsed = await parseXMLOffMain(data: data, source: source, type: type, topicName: topicName, maxAgeDays: maxItemAgeDays)
            let now = Date()
            let fresh = parsed.filter { !Staleness.isStale($0.publishedAt, maxDays: maxItemAgeDays, now: now) }
            return (fresh, FetchMeta(statusCode: code, requestId: nil, contentType: nil, bytes: data.count, durationMs: durMs, finalURL: source.url))
        } catch {
            let durMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0)
            return ([], FetchMeta(statusCode: nil, requestId: nil, contentType: nil, bytes: 0, durationMs: durMs, finalURL: source.url))
        }
    }

    private func parseXMLOffMain(data: Data, source: FeedSource, type: TickerType, topicName: String, maxAgeDays: Int) async -> [TickerItem] {
        await Task.detached(priority: .userInitiated) {
            RSSParser(data: data, source: source, type: type, topicName: topicName, maxAgeDays: maxAgeDays).parse()
        }.value
    }
}

// MARK: - FeedManager
@MainActor
final class FeedManager: NSObject, ObservableObject {
    @Published var items: [TickerItem] = []
    @Published var itemsRevision: Int = 0
    @Published var sources: [FeedSource] = []
    @Published var lastHealthCheckSummary: String? = nil
    @Published var isRunningHealthCheck: Bool = false
    @Published var newsSentiment: NewsSentiment? = nil
    @Published var isComputingSentiment: Bool = false
    @Published var isReady: Bool = false
    
    // NEW: AI Summaries
    @Published var aiFutureSummary: String = "SCANNING HORIZON..."
    @Published var aiTrendSummary: String = "CALCULATING VECTORS..."
    @Published var aiScienceSummary: String = "ANALYZING DATA..."
    @Published var aiSportsSummary: String = "TRACKING SCORES..."
    @Published var aiResearchSummary: String = "COMPUTING VIBE..."
    @Published var isComputingAISummaries: Bool = false

    struct NewsSentiment: Equatable {
        enum Level: String, Codable { case green, amber, red }
        let level: Level; let threeWordSummary: String; let computedAt: Date
    }

    private var sentimentCacheDayKey: String? = nil
    private var sentimentTask: Task<Void, Never>? = nil

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20.0; c.timeoutIntervalForResource = 45.0; c.urlCache = URLCache.shared; c.requestCachePolicy = .useProtocolCachePolicy; c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) FeedBar/1.2"
    private let acceptHeader = "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
    private let acceptLanguage = "en-IE,en;q=0.9"

    private let maxItemAgeDays: Int = 90
    private let initialHealthCheckDelay: TimeInterval = 5 * 60
    private let maxPerSourcePerCategory: Int = 12
    private let maxVisibleItems: Int = 200

    private let debugToFile = true
    private let debugFilePath = "/tmp/feedbar_debug.log"
    private var lastConfigDumpKey: String? = nil
    private var lastNetworkRefreshAt: Date? = nil

    private enum LogLevel: Int { case off = 0, error = 1, info = 2, verbose = 3 }
    private let logLevel: LogLevel = .verbose

    // Trends
    private let trendProvider: any TrendProvider
    private var trendsTask: Task<Void, Never>?
    private var lastTrendsRefreshAt: Date? = nil
    private let trendsMinIntervalSeconds: TimeInterval = 60 * 60
    private let trendsInitialDelaySeconds: TimeInterval = 10
    private var cachedTrendItems: [TickerItem] = []

    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var allFeedItems: [TickerItem] = []
    private var trendItems: [TickerItem] = []
    private var loadedNews: [TickerItem] = []
    
    private let ogEnricher = OGImageEnricher()
    private var lastOGEnrichAt: Date? = nil

    private lazy var fetcher: FeedFetcher = {
        let debug: @Sendable (String) -> Void = { [weak self] msg in
            guard let self else { return }
            Task { @MainActor in self.dbg(msg, level: msg.hasPrefix("❌") ? .error : .verbose) }
        }
        return FeedFetcher(session: self.session, userAgent: self.userAgent, acceptHeader: self.acceptHeader, acceptLanguage: self.acceptLanguage, maxItemAgeDays: self.maxItemAgeDays, maxConcurrentRequests: 10, perHostLimit: 2, debug: debug)
    }()

    let predictionSources: [FeedSource] = [
        FeedSource(name: "Futurism", url: "https://futurism.com/feed", domain: "futurism.com", defaultEnabled: true, category: "Future"),
        FeedSource(name: "Singularity Hub", url: "https://singularityhub.com/feed/", domain: "singularityhub.com", defaultEnabled: true, category: "Future")
    ]

    init(trendProvider: (any TrendProvider)? = nil) {
        self.trendProvider = trendProvider ?? PythonTrendAdapter()
        self.sources = defaultSources
        super.init()
        ensureDefaultsOnlyWhenMissing()
        dumpConfigurationIfNeeded(reason: "init")
        showBootPlaceholder("Booting signals…")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.hardRefresh() }
        
        let minutes = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        startAutoRefresh(interval: TimeInterval((minutes > 0 ? minutes : 30) * 60))
        scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: 7)
    }

    deinit { refreshTask?.cancel(); autoRefreshTask?.cancel(); trendsTask?.cancel(); sentimentTask?.cancel() }

    private func ensureDefaultsOnlyWhenMissing() {
        for s in sources {
            if UserDefaults.standard.object(forKey: s.settingKey) == nil { UserDefaults.standard.set(s.defaultEnabled, forKey: s.settingKey) }
        }
        if UserDefaults.standard.object(forKey: "showTrends") == nil { UserDefaults.standard.set(true, forKey: "showTrends") }
        if UserDefaults.standard.object(forKey: "showPredictions") == nil { UserDefaults.standard.set(true, forKey: "showPredictions") }
    }

    private func setItems(_ newItems: [TickerItem]) {
        self.items = newItems; self.itemsRevision &+= 1
    }

    private func dbg(_ msg: String, level: LogLevel = .info) {
        guard level.rawValue <= logLevel.rawValue else { return }
        let line = "FEEDMANAGER: \(msg)"
        print(line)
        guard debugToFile, let data = (line + "\n").data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: debugFilePath)
        if FileManager.default.fileExists(atPath: debugFilePath) {
            if let fh = try? FileHandle(forWritingTo: url) { _ = try? fh.seekToEnd(); try? fh.write(contentsOf: data); try? fh.close() }
        } else { try? data.write(to: url) }
    }

    private func showBootPlaceholder(_ msg: String) {
        let item = TickerItem(text: msg, type: .news, value: "SYSTEM", score: nil, sourceDomain: "feeds.bar", sourceName: "SYSTEM", mediaURL: nil, isVideo: false, articleURL: URL(string: "https://feeds.bar")!, publishedAt: Date())
        setItems([item])
        dbg("UI: placeholder -> \(msg)")
    }

    private func dumpConfigurationIfNeeded(reason: String) {}
    
    private func boolDefaultTrue(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
    
    private func isEnabled(_ source: FeedSource) -> Bool {
        UserDefaults.standard.object(forKey: source.settingKey) == nil ? source.defaultEnabled : UserDefaults.standard.bool(forKey: source.settingKey)
    }

    // MARK: - Validation & Add (Optimized)
    func validateAndAddCustomRSS(urlString: String, providedName: String?) async throws -> CustomFeed {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host else {
            throw NSError(domain: "feeds", code: 400, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }
        let domain = host.replacingOccurrences(of: "www.", with: "")
        let name = (providedName ?? "").isEmpty ? domain : (providedName ?? "")
        let temp = FeedSource(name: name, url: url.absoluteString, domain: domain, defaultEnabled: true, category: "Custom")
        let (parsed, _) = await fetcher.fetchRSSWithMeta(source: temp, type: .news, topicName: name, forceNetwork: true)
        if parsed.isEmpty { throw NSError(domain: "feeds", code: 422, userInfo: [NSLocalizedDescriptionKey: "Empty feed"]) }
        
        let newFeed = CustomFeed(id: UUID(), name: name, url: url.absoluteString, domain: domain)
        let raw = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
        var storage = CustomFeedStorage(rawValue: raw) ?? CustomFeedStorage(feeds: [])
        if storage.feeds.contains(where: { $0.url == newFeed.url }) { throw NSError(domain: "feeds", code: 409, userInfo: [NSLocalizedDescriptionKey: "Already exists"]) }
        storage.feeds.append(newFeed)
        UserDefaults.standard.set(storage.rawValue, forKey: "customFeeds")
        UserDefaults.standard.set(true, forKey: "custom_enabled_\(newFeed.id.uuidString)")
        
        // OPTIMIZATION: Inject immediately
        self.allFeedItems.append(contentsOf: parsed)
        self.rebuildLoadedAndVisible()
        
        return newFeed
    }

    // MARK: - Refresh Logic
    func softRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.progressiveLoad(forceNetwork: false)
        }
    }
    
    // Forces network fetch for active feeds
    func refreshActiveFeeds() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.progressiveLoad(forceNetwork: true)
        }
    }

    func hardRefresh() {
        refreshTask?.cancel()
        allFeedItems.removeAll(); trendItems.removeAll(); loadedNews.removeAll()
        
        self.isReady = false // Trigger Splash
        
        sentimentTask?.cancel(); sentimentTask = nil
        refreshTask = Task { [weak self] in await self?.progressiveLoad(forceNetwork: true) }
    }

    func startAutoRefresh(interval: TimeInterval) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.autoRefreshTick()
            }
        }
    }
    
    func stopAutoRefresh() { autoRefreshTask?.cancel(); autoRefreshTask = nil }

    private func autoRefreshTick() async {
        if refreshTask != nil { return }
        if let last = lastNetworkRefreshAt, Date().timeIntervalSince(last) < 5 * 60 { return }
        refreshTask = Task { [weak self] in await self?.progressiveLoad(forceNetwork: true) }
    }
    
    // MARK: - Extras
    func triggerSentimentRefresh(delaySeconds: Double = 0.2) {
        scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: delaySeconds, force: true)
    }
    
    func refreshNewsSentimentAfterRender(delaySeconds: Double = 0.2) {
        triggerSentimentRefresh(delaySeconds: delaySeconds)
    }

    // MARK: - Progressive Load
    private func progressiveLoad(forceNetwork: Bool) async {
        dbg("PROGRESSIVE: start force=\(forceNetwork)", level: .info)
        
        if !forceNetwork {
            rebuildLoadedAndVisible()
            self.isReady = true
            return
        }
        
        if forceNetwork {
            lastNetworkRefreshAt = Date()
            await fetchAndCacheNetworkUnified()
        }
        
        maybeEnqueueOGEnrichment()
        refreshTask = nil
    }

    // UNIFIED PARALLEL FETCH (News + Topics + Future + Trends)
    private func fetchAndCacheNetworkUnified() async {
        let showPredictions = boolDefaultTrue("showPredictions")
        let showTrends = boolDefaultTrue("showTrends")
        
        var newsJobs: [SourceConfig] = []
        var otherJobs: [SourceConfig] = []
        
        for s in sources {
            let c = SourceConfig(source: s, type: .news, topicName: s.category.uppercased())
            if s.category.uppercased() == "NEWS" { newsJobs.append(c) } else { otherJobs.append(c) }
        }
        
        if showPredictions {
            for s in predictionSources { otherJobs.append(SourceConfig(source: s, type: .prediction, topicName: "FUTURE")) }
        }
        
        let raw = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
        if let storage = CustomFeedStorage(rawValue: raw) {
            for f in storage.feeds {
                if boolDefaultTrue("custom_enabled_\(f.id.uuidString)") {
                    let s = FeedSource(name: f.name, url: f.url, domain: f.domain, defaultEnabled: true, category: "Custom")
                    otherJobs.append(SourceConfig(source: s, type: .news, topicName: f.name))
                }
            }
        }
        
        let f = fetcher
        let age = maxItemAgeDays
        
        // PARALLEL FETCH
        async let fetchedNews = newsJobs.isEmpty ? [] : fetchBatch(jobs: newsJobs, fetcher: f, maxAgeDays: age)
        async let fetchedOthers = otherJobs.isEmpty ? [] : fetchBatch(jobs: otherJobs, fetcher: f, maxAgeDays: age)
        
        // Trends Fetcher (Wrapped)
        async let fetchedTrends: [TickerItem] = {
            if !showTrends { return [] }
            do {
                return try await self.trendProvider.fetchGlobalTrends()
            } catch {
                let msg = "TRENDS: Failed \(error)"
                Task { @MainActor in self.dbg(msg) }
                return []
            }
        }()
        
        // WAIT FOR ALL
        let (newsItems, otherItems, trendItems) = await (fetchedNews, fetchedOthers, fetchedTrends)
        
        var dedupe: [TickerKey: TickerItem] = [:]
        for i in newsItems { dedupe[TickerKey(i)] = i }
        for i in otherItems { dedupe[TickerKey(i)] = i }
        
        self.allFeedItems = Array(dedupe.values)
        self.trendItems = trendItems
        self.cachedTrendItems = trendItems
        self.lastTrendsRefreshAt = Date()
        
        if let weather = await fetchWeather() {
            self.items.append(weather)
        }
        
        rebuildLoadedAndVisible()
        
        // REVEAL
        withAnimation(.easeOut(duration: 0.5)) {
            self.isReady = true
        }
        
        // 6. Post-Load Tasks
        if !self.allFeedItems.isEmpty {
            scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: 0.1, force: true)
            
            // NEW: Trigger AI Summaries for Future/Trends
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s delay
                await self.refreshAISummaries()
            }
        }
        
        if allFeedItems.isEmpty && trendItems.isEmpty {
            if !(await networkProbe()) { showBootPlaceholder("Network blocked.") }
            else { showBootPlaceholder("No items loaded.") }
        } else if loadedNews.isEmpty && trendItems.isEmpty {
            if items.isEmpty { showBootPlaceholder("All feeds disabled.") }
        }
    }
    
    // NEW: AI Summary Refresh
    private func refreshAISummaries() async {
            if isComputingAISummaries { return }
            
            // Helper to grab text for a category
            func headlines(for category: String) -> [String] {
                return items
                    .filter { ($0.value ?? "").uppercased().contains(category) }
                    .map { $0.text }
            }
            
            let futureHeadlines = headlines(for: "FUTURE")
            let scienceHeadlines = headlines(for: "SCIENCE")
            let sportsHeadlines = headlines(for: "SPORT") // Note: "SPORT" matches "SPORTS" and "SPORT"
            let researchHeadlines = headlines(for: "AI & RESEARCH") // Matches your category name
            let trendHeadlines = trendItems.map { $0.text }
            
            // Only run if we have *something* to summarize
            if futureHeadlines.isEmpty && trendHeadlines.isEmpty && scienceHeadlines.isEmpty { return }
            
            isComputingAISummaries = true
            defer { isComputingAISummaries = false }
            
            // Fire parallel requests
            async let future = futureHeadlines.isEmpty ? nil : try? await OpenAIService.generateThreeWordSummary(session: session, apiKey: Secrets.openAIKey, headlines: futureHeadlines, context: "Futurism & Emerging Tech")
            async let trends = trendHeadlines.isEmpty ? nil : try? await OpenAIService.generateThreeWordSummary(session: session, apiKey: Secrets.openAIKey, headlines: trendHeadlines, context: "Global Viral Trends")
            async let science = scienceHeadlines.isEmpty ? nil : try? await OpenAIService.generateThreeWordSummary(session: session, apiKey: Secrets.openAIKey, headlines: scienceHeadlines, context: "Scientific Breakthroughs")
            async let sports = sportsHeadlines.isEmpty ? nil : try? await OpenAIService.generateThreeWordSummary(session: session, apiKey: Secrets.openAIKey, headlines: sportsHeadlines, context: "Sports Headlines")
            async let research = researchHeadlines.isEmpty ? nil : try? await OpenAIService.generateThreeWordSummary(session: session, apiKey: Secrets.openAIKey, headlines: researchHeadlines, context: "Artificial Intelligence Research")
            
            let (f, t, s, sp, r) = await (future, trends, science, sports, research)
            
            await MainActor.run {
                if let v = f { self.aiFutureSummary = v }
                if let v = t { self.aiTrendSummary = v }
                if let v = s { self.aiScienceSummary = v }
                if let v = sp { self.aiSportsSummary = v }
                if let v = r { self.aiResearchSummary = v }
            }
        }
    
    private struct SourceConfig { let source: FeedSource; let type: TickerType; let topicName: String }
    private func fetchBatch(jobs: [SourceConfig], fetcher: FeedFetcher, maxAgeDays: Int) async -> [TickerItem] {
        await withTaskGroup(of: [TickerItem].self) { group in
            for job in jobs {
                group.addTask {
                    let (batch, _) = await fetcher.fetchRSSWithMeta(source: job.source, type: job.type, topicName: job.topicName, forceNetwork: true)
                    let now = Date()
                    return batch.filter { !Staleness.isStale($0.publishedAt, maxDays: maxAgeDays, now: now) }
                }
            }
            var res: [TickerItem] = []
            for await batch in group { res.append(contentsOf: batch) }
            return res
        }
    }
    
    private func networkProbe() async -> Bool {
        guard let url = URL(string: "https://google.com") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 5
        return (try? await session.data(for: req)) != nil
    }

    // MARK: - Rebuild Helpers
    private func rebuildVisibleItemsFromLoadedNews() {
        let mixed = mixFeeds(loadedNews)
        logFeedMix(mixed)
        if let weather = items.first(where: { $0.sourceName == "Local Weather" }) {
            setItems([weather] + Array(mixed.prefix(maxVisibleItems)))
        } else {
            setItems(Array(mixed.prefix(maxVisibleItems)))
        }
    }
    
    private func logFeedMix(_ items: [TickerItem]) {
        if items.isEmpty { return }
        var counts: [String: Int] = [:]
        for item in items {
            let cat = (item.value ?? "UNKNOWN").uppercased()
            counts[cat, default: 0] += 1
        }
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " | ")
        dbg("FEED MIX: Total: \(items.count) [ \(summary) ]", level: .info)
    }

    private func rebuildLoadedAndVisible() {
        let showTrends = boolDefaultTrue("showTrends")
        let merged = allFeedItems + (showTrends ? trendItems : [])
        let now = Date()
        let fresh = merged.filter { !Staleness.isStale($0.publishedAt, maxDays: maxItemAgeDays, now: now) }
        loadedNews = pruneDisabled(from: fresh)
        rebuildVisibleItemsFromLoadedNews()
    }
    
    private func pruneDisabled(from items: [TickerItem]) -> [TickerItem] {
        let enabled = sources.filter { isEnabled($0) }
        let disabledNews = Set(sources.filter { !isEnabled($0) && $0.category.lowercased() == "news" }.map { $0.name })
        let enabledCats = Set(enabled.filter { $0.category.lowercased() != "news" }.map { $0.category.uppercased() })
        let showTrends = boolDefaultTrue("showTrends")
        let showPredictions = boolDefaultTrue("showPredictions")
        var customEnabled = Set<String>()
        if let raw = UserDefaults.standard.string(forKey: "customFeeds"), let storage = CustomFeedStorage(rawValue: raw) {
            for f in storage.feeds {
                if boolDefaultTrue("custom_enabled_\(f.id.uuidString)") {
                    customEnabled.insert(f.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
            }
        }
        
        return items.filter { item in
            if item.sourceName == "Local Weather" { return true }
            let up = (item.value ?? "").uppercased()
            if item.sourceName == "Global Market Trends" || up == "TRENDS" { return showTrends }
            if up == "FUTURE" { return showPredictions }
            if up == "NEWS" { return !disabledNews.contains(item.sourceName) }
            
            // Standard Categories
            if enabledCats.contains(up) { return true }
            
            // Custom Topics (Case insensitive check)
            let val = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if customEnabled.contains(val) { return true }
            
            return false
        }
    }

    // MARK: - WEIGHTED CATEGORY MIXING
    private func mixFeeds(_ items: [TickerItem]) -> [TickerItem] {
        let desired = maxVisibleItems
        
        // 1. Group items by Category/Topic
        var buckets: [String: [TickerItem]] = [:]
        
        for item in items {
            if item.sourceName == "Local Weather" { continue }
            let category = (item.value ?? "UNKNOWN").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            buckets[category, default: []].append(item)
        }
        
        // 2. Shuffle inside each bucket for freshness
        for key in buckets.keys {
            buckets[key] = roundRobinBySource(buckets[key]!, maxPerSource: maxPerSourcePerCategory)
        }
        
        // 3. Create Rotation Keys with BOOSTING
        var rotationKeys: [String] = []
        let categories = buckets.keys.sorted()
        
        for cat in categories {
            if cat == "NEWS" {
                // Boost News: Add 3 slots per cycle (Tripled weight)
                rotationKeys.append(cat)
                rotationKeys.append(cat)
                rotationKeys.append(cat)
            } else if cat == "TRENDS" || cat == "FUTURE" {
                // Boost Trends & Future: Add 2 slots per cycle (Doubled weight)
                rotationKeys.append(cat)
                rotationKeys.append(cat)
            } else {
                // Normal Categories (Sport, Tech, Custom Topics): 1 slot per cycle
                rotationKeys.append(cat)
            }
        }
        
        if rotationKeys.isEmpty { return [] }
        
        var out: [TickerItem] = []
        var bucketIndices: [String: Int] = [:]
        for key in buckets.keys { bucketIndices[key] = 0 }
        
        var active = true
        while active && out.count < desired {
            active = false
            
            for cat in rotationKeys {
                if out.count >= desired { break }
                
                guard let itemsInBucket = buckets[cat], let idx = bucketIndices[cat] else { continue }
                
                if idx < itemsInBucket.count {
                    out.append(itemsInBucket[idx])
                    bucketIndices[cat] = idx + 1
                    active = true
                }
            }
        }
        
        return out
    }

    private func roundRobinBySource(_ items: [TickerItem], maxPerSource: Int) -> [TickerItem] {
        guard !items.isEmpty else { return [] }

        var grouped = Dictionary(grouping: items, by: { $0.sourceName })
        for key in grouped.keys {
            grouped[key]?.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            if let capped = grouped[key]?.prefix(maxPerSource) { grouped[key] = Array(capped) }
        }

        var sourceKeys = Array(grouped.keys)
        sourceKeys.shuffle()

        var indices: [String: Int] = [:]
        for k in sourceKeys { indices[k] = 0 }

        var out: [TickerItem] = []
        out.reserveCapacity(items.count)

        var madeProgress = true
        while madeProgress {
            madeProgress = false
            for k in sourceKeys {
                guard let arr = grouped[k], let i = indices[k], i < arr.count else { continue }
                out.append(arr[i])
                indices[k] = i + 1
                madeProgress = true
            }
        }
        return out
    }
    
    // MARK: - Weather (Restored)
    func refreshWeatherOnly() {
        Task { [weak self] in
            guard let self else { return }
            if let weather = await self.fetchWeather() {
                var current = self.items
                if let idx = current.firstIndex(where: { $0.sourceName == "Local Weather" }) { current[idx] = weather }
                else { current.insert(weather, at: 0) }
                if current.count > self.maxVisibleItems { current = Array(current.prefix(self.maxVisibleItems)) }
                withAnimation { self.setItems(current) }
            }
        }
    }
    
    private func fetchWeather() async -> TickerItem? {
        let city = UserDefaults.standard.string(forKey: "weatherCity") ?? "Dublin"
        guard let location = await withTimeout(seconds: 2.0, operation: { await self.geocodeCity(city) }) else { return await fetchWeatherData(lat: 53.3498, long: -6.2603, name: "Dublin") }
        return await fetchWeatherData(lat: location.coordinate.latitude, long: location.coordinate.longitude, name: city)
    }

    private func fetchWeatherData(lat: Double, long: Double, name: String) async -> TickerItem? {
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(long)&current_weather=true"
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 10.0
            let (data, _) = try await self.session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let current = json["current_weather"] as? [String: Any], let temp = current["temperature"] as? Double else { return nil }
            return TickerItem(text: "\(name.uppercased()): \(Int(temp))°C", type: .news, value: "Weather", score: nil, sourceDomain: "open-meteo.com", sourceName: "Local Weather", mediaURL: nil, isVideo: false, articleURL: URL(string: "https://weather.com")!, publishedAt: nil)
        } catch { return nil }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }; group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let result = await group.next() ?? nil; group.cancelAll(); return result
        }
    }
    
    private func geocodeCity(_ city: String) async -> CLLocation? {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines); if trimmed.isEmpty { return nil }
        let geocoder = CLGeocoder()
        return await withCheckedContinuation { continuation in geocoder.geocodeAddressString(trimmed) { placemarks, _ in continuation.resume(returning: placemarks?.first?.location) } }
    }

    // MARK: - OG & Health (Restored)
    private func maybeEnqueueOGEnrichment() {
        if let last = lastOGEnrichAt, Date().timeIntervalSince(last) < 120 { return }
        lastOGEnrichAt = Date()
        let candidates = items.filter { $0.mediaURL == nil && $0.sourceName != "Local Weather" && $0.sourceName != "Global Market Trends" }
        enqueueOGEnrichment(for: Array(candidates.prefix(40)))
    }

    private func enqueueOGEnrichment(for items: [TickerItem]) {
        var seen = Set<URL>()
        for item in items {
            let u = item.articleURL; if seen.contains(u) { continue }; seen.insert(u)
            ogEnricher.enqueue(item: item) { [weak self] updated in guard let self else { return }; Task { @MainActor in self.applyEnrichedItem(updated) } }
        }
    }

    private func applyEnrichedItem(_ updated: TickerItem) {
        if let idx = items.firstIndex(where: { TickerKey($0) == TickerKey(updated) }) { items[idx] = updated; itemsRevision &+= 1 }
        func replace(in arr: inout [TickerItem]) { if let i = arr.firstIndex(where: { TickerKey($0) == TickerKey(updated) }) { arr[i] = updated } }
        replace(in: &allFeedItems); replace(in: &trendItems); replace(in: &loadedNews)
    }

    func runHealthCheckNow() { Task { await self.runFeedHealthCheck(reason: "manual") } }
    private func runFeedHealthCheck(reason: String) async {
        if isRunningHealthCheck { return }; isRunningHealthCheck = true; defer { isRunningHealthCheck = false }
        let enabled = self.sources.filter { self.isEnabled($0) }
        guard !enabled.isEmpty else { lastHealthCheckSummary = "No enabled feeds."; return }
        lastHealthCheckSummary = "Health check run on \(enabled.count) feeds."
        softRefresh()
    }

    private func scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: Double, force: Bool = false) {
        sentimentTask?.cancel()
        sentimentTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            await self.refreshNewsSentimentIfNeeded(force: force)
        }
    }
    
    private func refreshNewsSentimentIfNeeded(force: Bool) async {
        let todayKey = Self.dayKey(Date())
        if !force, sentimentCacheDayKey == todayKey, newsSentiment != nil { return }
        
        let todays = todaysNewsHeadlines(limit: 40)
        
        guard !todays.isEmpty else { return }
        if isComputingSentiment { return }
        isComputingSentiment = true; defer { isComputingSentiment = false }
        do {
            let result = try await OpenAIService.classifySentimentAndSummarize(session: session, apiKey: Secrets.openAIKey, headlines: todays)
            self.newsSentiment = result; self.sentimentCacheDayKey = todayKey
            dbg("SENTIMENT: \(result.level.rawValue) | \(result.threeWordSummary)", level: .info)
        } catch {
            let err = error as NSError
            if err.domain == NSURLErrorDomain && err.code == NSURLErrorCancelled { return }
            if error is CancellationError { return }
            dbg("❌ Sentiment error: \(error.localizedDescription)", level: .error)
        }
    }

    private func todaysNewsHeadlines(limit: Int) -> [String] {
        let cal = Calendar.current; let now = Date()
        return allFeedItems.filter { ($0.value ?? "").uppercased() == "NEWS" && cal.isDate($0.publishedAt ?? .distantPast, inSameDayAs: now) }
            .compactMap { $0.text.isEmpty ? nil : $0.text }
            .prefix(limit).map { String($0) }
    }

    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    
    // MARK: - Trends (Using Adapter)
    private func kickOffTrendsIfNeeded(force: Bool, reason: String) {
        guard boolDefaultTrue("showTrends") else {
            trendsTask?.cancel(); trendsTask = nil
            trendItems.removeAll(); rebuildLoadedAndVisible()
            return
        }
        
        if trendItems.isEmpty && !cachedTrendItems.isEmpty {
            self.trendItems = cachedTrendItems; rebuildLoadedAndVisible()
            dbg("TRENDS: Restored \(cachedTrendItems.count) from cache.", level: .info)
        }
        
        if !force, let last = lastTrendsRefreshAt, Date().timeIntervalSince(last) < trendsMinIntervalSeconds { return }
        if trendsTask != nil { return }
        
        trendsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await self.trendProvider.fetchGlobalTrends()
                self.cachedTrendItems = items
                self.trendItems = items
                self.lastTrendsRefreshAt = Date()
                self.rebuildLoadedAndVisible()
            } catch {
                self.dbg("TRENDS: Failed \(error)")
            }
            self.trendsTask = nil
        }
    }
    
    // MARK: - HELPER PROPERTY (Moved inside class)
    var currentWeatherTemp: String? {
        let weatherItem = items.first { item in
            let label = item.signalLabel.lowercased()
            let domain = item.sourceDomain.lowercased()
            return label.contains("weather") || label.contains("meteo") || label.contains("forecast") ||
                domain.contains("weather") || domain.contains("meteo") || domain.contains("forecast")
        }
        guard let item = weatherItem else { return nil }
        if let score = item.score, !score.isEmpty { return score }
        if item.text.contains("°") {
            let words = item.text.components(separatedBy: .whitespaces)
            if let tempString = words.first(where: { $0.contains("°") }) { return tempString }
        }
        return nil
    }
}
