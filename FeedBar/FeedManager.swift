//
//  FeedManager.swift
//  FeedBar
//

import Foundation
import Combine
import SwiftUI
import CoreLocation
import QuartzCore

// MARK: - Staleness helpers (explicitly nonisolated, Swift-6 safe)
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

    init(_ value: Int) {
        self.permits = max(1, value)
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }
}

actor HostLimiter {
    private let perHostLimit: Int
    private var inFlight: [String: Int] = [:]
    private var queues: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(perHostLimit: Int) {
        self.perHostLimit = max(1, perHostLimit)
    }

    func acquire(host: String) async {
        let h = host.lowercased()
        let current = inFlight[h] ?? 0
        
        if current < perHostLimit {
            inFlight[h] = current + 1
            return
        }
        
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queues[h, default: []].append(cont)
        }
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
    let text: String
    let sourceName: String
    let articleURL: String

    init(_ item: TickerItem) {
        self.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceName = item.sourceName
        self.articleURL = item.articleURL.absoluteString
    }
}

// MARK: - Background RSS fetcher
actor FeedFetcher {
    struct FetchMeta: Sendable {
        let statusCode: Int?
        let requestId: String?
        let contentType: String?
        let bytes: Int
        let durationMs: Int
        let finalURL: String
    }

    private let session: URLSession
    private let userAgent: String
    private let acceptHeader: String
    private let acceptLanguage: String
    private let maxItemAgeDays: Int
    private let debug: @Sendable (String) -> Void

    private let networkGate: AsyncSemaphore
    private let hostGate: HostLimiter

    init(
        session: URLSession,
        userAgent: String,
        acceptHeader: String,
        acceptLanguage: String,
        maxItemAgeDays: Int,
        maxConcurrentRequests: Int,
        perHostLimit: Int,
        debug: @escaping @Sendable (String) -> Void
    ) {
        self.session = session
        self.userAgent = userAgent
        self.acceptHeader = acceptHeader
        self.acceptLanguage = acceptLanguage
        self.maxItemAgeDays = maxItemAgeDays
        self.debug = debug

        self.networkGate = AsyncSemaphore(maxConcurrentRequests)
        self.hostGate = HostLimiter(perHostLimit: perHostLimit)
    }

    func fetchRSSWithMeta(
        source: FeedSource,
        type: TickerType,
        topicName: String,
        forceNetwork: Bool
    ) async -> ([TickerItem], FetchMeta) {
        guard let url = URL(string: source.url) else {
            return ([], FetchMeta(statusCode: nil, requestId: nil, contentType: nil, bytes: 0, durationMs: 0, finalURL: source.url))
        }

        // Acquire global lock then host lock
        await networkGate.acquire()
        await hostGate.acquire(host: source.domain)
        
        defer {
            Task { await self.hostGate.release(host: source.domain) }
            Task { await self.networkGate.release() }
        }

        let start = CFAbsoluteTimeGetCurrent()

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30.0
            request.cachePolicy = forceNetwork ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")

            debug("RSS → \(source.name) host=\(source.domain) force=\(forceNetwork ? "true" : "false") url=\(source.url)")

            let (data, response) = try await session.data(for: request)

            let http = response as? HTTPURLResponse
            let code = http?.statusCode
            let reqId = http?.value(forHTTPHeaderField: "x-request-id")
            let contentType = http?.value(forHTTPHeaderField: "Content-Type")

            let durMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0)

            if let code, !(200...299).contains(code) {
                debug("❌ RSS HTTP \(code) (\(durMs)ms) \(source.name) ct=\(contentType ?? "n/a") url=\(source.url)")
                return ([], FetchMeta(statusCode: code, requestId: reqId, contentType: contentType, bytes: data.count, durationMs: durMs, finalURL: source.url))
            }

            let parsed = await parseXMLOffMain(
                data: data,
                source: source,
                type: type,
                topicName: topicName,
                maxAgeDays: maxItemAgeDays
            )

            if parsed.isEmpty {
                debug("⚠️ RSS parsed 0 items (\(durMs)ms) \(source.name) topic=\(topicName) ct=\(contentType ?? "n/a") url=\(source.url)")
            } else {
                debug("RSS ✓ \(parsed.count) items (\(durMs)ms) \(source.name) ct=\(contentType ?? "n/a")")
            }

            let now = Date()
            let fresh = parsed.filter { !Staleness.isStale($0.publishedAt, maxDays: maxItemAgeDays, now: now) }

            return (fresh, FetchMeta(statusCode: code, requestId: reqId, contentType: contentType, bytes: data.count, durationMs: durMs, finalURL: source.url))
        } catch {
            let durMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0)
            debug("❌ RSS fetch error (\(durMs)ms) \(source.name): \(error.localizedDescription) url=\(source.url)")
            return ([], FetchMeta(statusCode: nil, requestId: nil, contentType: nil, bytes: 0, durationMs: durMs, finalURL: source.url))
        }
    }

    private func parseXMLOffMain(
        data: Data,
        source: FeedSource,
        type: TickerType,
        topicName: String,
        maxAgeDays: Int
    ) async -> [TickerItem] {
        await Task.detached(priority: .userInitiated) {
            let parser = RSSParser(
                data: data,
                source: source,
                type: type,
                topicName: topicName,
                maxAgeDays: maxAgeDays
            )
            return parser.parse()
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

    struct NewsSentiment: Equatable {
        enum Level: String, Codable { case green, amber, red }
        let level: Level
        let threeWordSummary: String
        let computedAt: Date
    }

    @Published var newsSentiment: NewsSentiment? = nil
    @Published var isComputingSentiment: Bool = false

    private var sentimentCacheDayKey: String? = nil
    private var sentimentTask: Task<Void, Never>? = nil

    // MARK: - Networking config
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20.0
        config.timeoutIntervalForResource = 45.0
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private let acceptHeader =
        "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
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
    private let trendsInitialDelaySeconds: TimeInterval = 90

    // Refresh tasks
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    // Cache
    private var allFeedItems: [TickerItem] = []
    private var trendItems: [TickerItem] = []
    private var loadedNews: [TickerItem] = []

    // OG enrichment
    private let ogEnricher = OGImageEnricher()
    private var lastOGEnrichAt: Date? = nil

    // Fetcher
    private lazy var fetcher: FeedFetcher = {
        let debug: @Sendable (String) -> Void = { [weak self] msg in
            guard let self else { return }
            Task { @MainActor in
                let level: LogLevel
                if msg.hasPrefix("❌") { level = .error }
                else if msg.hasPrefix("⚠️") { level = .info }
                else if msg.hasPrefix("RSS ✓") { level = .info }
                else if msg.hasPrefix("RSS →") { level = .verbose }
                else { level = .verbose }

                self.dbg(msg, level: level)
            }
        }

        return FeedFetcher(
            session: self.session,
            userAgent: self.userAgent,
            acceptHeader: self.acceptHeader,
            acceptLanguage: self.acceptLanguage,
            maxItemAgeDays: self.maxItemAgeDays,
            maxConcurrentRequests: 10,
            perHostLimit: 2,
            debug: debug
        )
    }()

    // FUTURE / predictions sources
    let predictionSources: [FeedSource] = [
        FeedSource(name: "Futurism", url: "https://futurism.com/feed", domain: "futurism.com", defaultEnabled: true, category: "Future"),
        FeedSource(name: "Singularity Hub", url: "https://singularityhub.com/feed/", domain: "singularityhub.com", defaultEnabled: true, category: "Future")
    ]

    init(trendProvider: (any TrendProvider)? = nil) {
        self.trendProvider = trendProvider ?? PythonTrendAdapter()
        self.sources = defaultSources
        super.init()

        ensureDefaultsOnlyWhenMissing()
        dbg("initialized (pid:\(ProcessInfo.processInfo.processIdentifier))", level: .info)

        dbg("FEEDMANAGER IDENTITY: \(ObjectIdentifier(self))", level: .info)
        dumpConfigurationIfNeeded(reason: "init")

        // Always show something instantly
        showBootPlaceholder("Booting signals…")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.hardRefresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + trendsInitialDelaySeconds) { [weak self] in
            self?.kickOffTrendsIfNeeded(force: false, reason: "startup-delayed")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + initialHealthCheckDelay) { [weak self] in self?.runHealthCheckNow() }

        let minutes = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        let useMinutes = minutes > 0 ? minutes : 30
        startAutoRefresh(interval: TimeInterval(useMinutes * 60))

        scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: 7)
    }

    deinit {
        refreshTask?.cancel()
        autoRefreshTask?.cancel()
        trendsTask?.cancel()
        sentimentTask?.cancel()
    }

    private func ensureDefaultsOnlyWhenMissing() {
        for s in sources {
            if UserDefaults.standard.object(forKey: s.settingKey) == nil {
                UserDefaults.standard.set(s.defaultEnabled, forKey: s.settingKey)
            }
        }
        if UserDefaults.standard.object(forKey: "showTrends") == nil { UserDefaults.standard.set(true, forKey: "showTrends") }
        if UserDefaults.standard.object(forKey: "showPredictions") == nil { UserDefaults.standard.set(true, forKey: "showPredictions") }
    }

    private func setItems(_ newItems: [TickerItem]) {
        self.items = newItems
        self.itemsRevision &+= 1
    }

    private func dbg(_ msg: String, level: LogLevel = .info) {
        guard level.rawValue <= logLevel.rawValue else { return }
        let line = "FEEDMANAGER: \(msg)"
        print(line)

        guard debugToFile else { return }
        let s = line + "\n"
        guard let data = s.data(using: .utf8) else { return }

        let url = URL(fileURLWithPath: debugFilePath)
        if FileManager.default.fileExists(atPath: debugFilePath) {
            if let fh = try? FileHandle(forWritingTo: url) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
                try? fh.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

    private func showBootPlaceholder(_ msg: String) {
        let placeholder = TickerItem(
            text: msg,
            type: .news,
            value: "SYSTEM",
            score: nil,
            sourceDomain: "feeds.bar",
            sourceName: "SYSTEM",
            mediaURL: nil,
            isVideo: false,
            articleURL: URL(string: "https://feeds.bar")!,
            publishedAt: Date()
        )
        setItems([placeholder])
        dbg("UI: placeholder set -> \(msg)", level: .info)
    }

    private func dumpConfigurationIfNeeded(reason: String) {
        let snapshot = configurationSnapshotKey()
        if lastConfigDumpKey == snapshot { return }
        lastConfigDumpKey = snapshot
        dumpConfiguration(reason: reason)
    }

    private func configurationSnapshotKey() -> String {
        var bits: [String] = []
        for s in sources { bits.append("\(s.settingKey)=\(isEnabled(s) ? "1" : "0")") }
        bits.append("showTrends=\(boolDefaultTrue("showTrends") ? "1" : "0")")
        bits.append("showPredictions=\(boolDefaultTrue("showPredictions") ? "1" : "0")")
        let customRaw = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
        bits.append("customRawHash=\(customRaw.hashValue)")
        return bits.joined(separator: "|")
    }

    private func dumpConfiguration(reason: String) {
        dbg("======= CONFIG DUMP (\(reason)) =======", level: .info)

        let grouped = Dictionary(grouping: sources, by: { $0.category.uppercased() })
        for cat in grouped.keys.sorted() {
            let list = grouped[cat] ?? []
            let enabled = list.filter { isEnabled($0) }.sorted(by: { $0.name < $1.name })
            let disabled = list.filter { !isEnabled($0) }.sorted(by: { $0.name < $1.name })

            dbg("CATEGORY: \(cat) | enabled=\(enabled.count) disabled=\(disabled.count)", level: .info)
            if !enabled.isEmpty {
                dbg("  ENABLED:", level: .info)
                for s in enabled { dbg("    - \(s.name) | domain=\(s.domain) | url=\(s.url)", level: .info) }
            }
            if !disabled.isEmpty {
                dbg("  DISABLED:", level: .info)
                for s in disabled { dbg("    - \(s.name) | domain=\(s.domain) | url=\(s.url)", level: .info) }
            }
        }

        let customData = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
        if let storage = CustomFeedStorage(rawValue: customData) {
            dbg("CUSTOM FEEDS: \(storage.feeds.count)", level: .info)
            for f in storage.feeds {
                let key = "custom_enabled_\(f.id.uuidString)"
                let enabled = boolDefaultTrue(key)
                dbg("  - \(f.name) | enabled=\(enabled ? "true" : "false") | domain=\(f.domain) | url=\(f.url)", level: .info)
            }
        } else {
            dbg("CUSTOM FEEDS: none/invalid storage", level: .info)
        }

        dbg("FLAGS: showTrends=\(boolDefaultTrue("showTrends")) showPredictions=\(boolDefaultTrue("showPredictions"))", level: .info)
        dbg("======================================", level: .info)
    }

    private func boolDefaultTrue(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    private func isEnabled(_ source: FeedSource) -> Bool {
        UserDefaults.standard.object(forKey: source.settingKey) == nil
            ? source.defaultEnabled
            : UserDefaults.standard.bool(forKey: source.settingKey)
    }

    // MARK: - Public: validate + add RSS by URL
    func validateAndAddCustomRSS(urlString: String, providedName: String?) async throws -> CustomFeed {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host else {
            throw NSError(domain: "feeds", code: 400, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        let domain = host.replacingOccurrences(of: "www.", with: "")
        let name: String = {
            let n = (providedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? domain : n
        }()

        let tempSource = FeedSource(name: name, url: trimmed, domain: domain, defaultEnabled: true, category: "Custom")
        let (parsed, _) = await fetcher.fetchRSSWithMeta(source: tempSource, type: .news, topicName: name, forceNetwork: true)

        if parsed.isEmpty {
            throw NSError(domain: "feeds", code: 422, userInfo: [NSLocalizedDescriptionKey: "Empty/unparseable feed"])
        }

        let newFeed = CustomFeed(id: UUID(), name: name, url: trimmed, domain: domain)

        let raw = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
        var storage = CustomFeedStorage(rawValue: raw) ?? CustomFeedStorage(feeds: [])

        if storage.feeds.contains(where: { $0.url == newFeed.url }) {
            throw NSError(domain: "feeds", code: 409, userInfo: [NSLocalizedDescriptionKey: "Already exists"])
        }

        storage.feeds.append(newFeed)
        UserDefaults.standard.set(storage.rawValue, forKey: "customFeeds")
        UserDefaults.standard.set(true, forKey: "custom_enabled_\(newFeed.id.uuidString)")

        dumpConfigurationIfNeeded(reason: "custom-feed-added")
        return newFeed
    }

    // MARK: - Public: refresh triggers
    func softRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.progressiveLoad(forceNetwork: false)
        }
    }

    func hardRefresh() {
        refreshTask?.cancel()

        allFeedItems.removeAll()
        trendItems.removeAll()
        loadedNews.removeAll()

        showBootPlaceholder("Refreshing signals…")

        sentimentTask?.cancel()
        sentimentTask = nil

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.progressiveLoad(forceNetwork: true)
        }
    }

    // MARK: - Auto refresh
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

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func autoRefreshTick() async {
        if refreshTask != nil { return }
        if let last = lastNetworkRefreshAt, Date().timeIntervalSince(last) < 5 * 60 { return }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self.progressiveLoad(forceNetwork: true)
        }
    }

    // MARK: - Weather-only refresh
    func refreshWeatherOnly() {
        Task { [weak self] in
            guard let self else { return }

            if let weather = await self.fetchWeather() {
                var current = self.items
                if let idx = current.firstIndex(where: { $0.sourceName == "Local Weather" }) {
                    current[idx] = weather
                } else {
                    current.insert(weather, at: 0)
                }
                if current.count > self.maxVisibleItems {
                    current = Array(current.prefix(self.maxVisibleItems))
                }
                withAnimation { self.setItems(current) }
            } else {
                self.dbg("WEATHER: refreshWeatherOnly failed (no result)", level: .info)
            }
        }
    }

    // MARK: - NEW: quick “is the network blocked?” probe
    private func networkProbe() async -> Bool {
        // Known-good, HTTPS, simple RSS
        guard let url = URL(string: "https://feeds.bbci.co.uk/news/rss.xml") else { return false }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 6.0
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(acceptHeader, forHTTPHeaderField: "Accept")
            req.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                dbg("PROBE: BBC RSS HTTP \(http.statusCode)", level: .info)
                return (200...299).contains(http.statusCode)
            }
            dbg("PROBE: non-HTTP response", level: .info)
            return false
        } catch {
            dbg("❌ PROBE failed: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    // MARK: - Progressive load
    private func progressiveLoad(forceNetwork: Bool) async {
        dbg("PROGRESSIVE: start forceNetwork=\(forceNetwork)", level: .info)

        // Render whatever we have right now
        rebuildLoadedAndVisible()

        // Weather first (fast)
        if let weather = await fetchWeather() {
            let mixed = mixFeeds(loadedNews)
            withAnimation {
                self.setItems([weather] + Array(mixed.prefix(max(0, maxVisibleItems - 1))))
            }
        } else {
            let mixed = mixFeeds(loadedNews)
            withAnimation { self.setItems(Array(mixed.prefix(maxVisibleItems))) }
        }

        scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: 6)

        // Network
        if forceNetwork {
            lastNetworkRefreshAt = Date()
            await fetchAndCacheNetworkProgressive()
            dbg("PROGRESSIVE: after network allFeedItems=\(allFeedItems.count) loadedNews=\(loadedNews.count)", level: .info)

            if loadedNews.isEmpty {
                let ok = await networkProbe()
                if !ok {
                    showBootPlaceholder("Network blocked. Check App Sandbox: enable Outgoing Connections (Client).")
                } else {
                    showBootPlaceholder("No items loaded. Feeds empty or parser failing. Check /tmp/feedbar_debug.log")
                }
            } else {
                rebuildVisibleItemsFromLoadedNews()
            }
        }

        kickOffTrendsIfNeeded(force: forceNetwork, reason: forceNetwork ? "post-network-refresh" : "post-soft-refresh")
        maybeEnqueueOGEnrichment()

        refreshTask = nil
    }

    // MARK: - Network fetch (Progressive / News-First)
    private struct FetchResult {
        let category: String
        let name: String
        let url: String
        let topicName: String
        let count: Int
        let status: Int?
        let contentType: String?
        let bytes: Int
    }
    
    private struct SourceConfig {
        let source: FeedSource
        let type: TickerType
        let topicName: String
    }

    private func fetchAndCacheNetworkProgressive() async {
        dumpConfigurationIfNeeded(reason: "pre-network-fetch")

        let enabledSources = self.sources.filter { self.isEnabled($0) }
        let showPredictions = self.boolDefaultTrue("showPredictions")

        let customFeeds: [CustomFeed] = {
            let raw = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
            return (CustomFeedStorage(rawValue: raw)?.feeds ?? [])
        }()

        // Map enabled custom feeds
        var activeCustomFeeds: [CustomFeed] = []
        for c in customFeeds {
            let key = "custom_enabled_\(c.id.uuidString)"
            if (UserDefaults.standard.object(forKey: key) == nil) ? true : UserDefaults.standard.bool(forKey: key) {
                activeCustomFeeds.append(c)
            }
        }

        // Build list of all fetch jobs
        var newsJobs: [SourceConfig] = []
        var otherJobs: [SourceConfig] = []

        // 1. Built-in sources
        for s in enabledSources {
            let config = SourceConfig(source: s, type: .news, topicName: s.category.uppercased())
            if s.category.uppercased() == "NEWS" {
                newsJobs.append(config)
            } else {
                otherJobs.append(config)
            }
        }

        // 2. Predictions
        if showPredictions {
            for s in predictionSources {
                otherJobs.append(SourceConfig(source: s, type: .prediction, topicName: "FUTURE"))
            }
        }

        // 3. Custom feeds
        for c in activeCustomFeeds {
            let s = FeedSource(name: c.name, url: c.url, domain: c.domain, defaultEnabled: true, category: "Custom")
            otherJobs.append(SourceConfig(source: s, type: .news, topicName: c.name))
        }

        // Shared dedupe state across phases
        var dedupe: [TickerKey: TickerItem] = [:]
        dedupe.reserveCapacity(2000)
        
        let maxAgeDaysLocal = self.maxItemAgeDays
        let fetcherLocal = self.fetcher

        // --- PHASE 1: NEWS ---
        if !newsJobs.isEmpty {
            dbg("PROGRESSIVE: Phase 1 - Fetching \(newsJobs.count) NEWS sources", level: .info)
            let newsItems = await fetchBatch(jobs: newsJobs, fetcher: fetcherLocal, maxAgeDays: maxAgeDaysLocal)
            
            // Dedupe & Update
            for item in newsItems {
                let k = TickerKey(item)
                dedupe[k] = item
            }
            
            self.allFeedItems = Array(dedupe.values)
            rebuildLoadedAndVisible()
            
            // Immediate Sentiment Trigger using the newly loaded news
            if !loadedNews.isEmpty {
                dbg("PROGRESSIVE: News loaded, triggering sentiment immediately.", level: .info)
                scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: 0.5, force: true)
            }
        }

        // --- PHASE 2: OTHERS ---
        if !otherJobs.isEmpty {
            dbg("PROGRESSIVE: Phase 2 - Fetching \(otherJobs.count) OTHER sources", level: .info)
            let otherItems = await fetchBatch(jobs: otherJobs, fetcher: fetcherLocal, maxAgeDays: maxAgeDaysLocal)
            
            // Dedupe & Update
            for item in otherItems {
                let k = TickerKey(item)
                if let existing = dedupe[k] {
                    // Prefer item with media if existing has none
                    if existing.mediaURL == nil && item.mediaURL != nil {
                        dedupe[k] = item
                    }
                } else {
                    dedupe[k] = item
                }
            }
            
            self.allFeedItems = Array(dedupe.values)
            rebuildLoadedAndVisible()
        }
        
        // --- PHASE 3: TRENDS ---
        kickOffTrendsIfNeeded(force: true, reason: "post-network-refresh")
    }
    
    private func fetchBatch(jobs: [SourceConfig], fetcher: FeedFetcher, maxAgeDays: Int) async -> [TickerItem] {
        await withTaskGroup(of: [TickerItem].self) { group in
            for job in jobs {
                group.addTask {
                    let (batch, _) = await fetcher.fetchRSSWithMeta(
                        source: job.source,
                        type: job.type,
                        topicName: job.topicName,
                        forceNetwork: true
                    )
                    
                    let now = Date()
                    return batch.filter { !Staleness.isStale($0.publishedAt, maxDays: maxAgeDays, now: now) }
                }
            }
            
            var results: [TickerItem] = []
            for await batch in group {
                results.append(contentsOf: batch)
            }
            return results
        }
    }

    // MARK: - Loaded rebuild
    private func rebuildLoadedAndVisible() {
        let showTrends = boolDefaultTrue("showTrends")
        let merged = allFeedItems + (showTrends ? trendItems : [])

        let now = Date()
        let recency = merged.filter { !Staleness.isStale($0.publishedAt, maxDays: maxItemAgeDays, now: now) }

        loadedNews = pruneDisabled(from: recency)
        rebuildVisibleItemsFromLoadedNews()
    }

    private func pruneDisabled(from items: [TickerItem]) -> [TickerItem] {
        let enabledSources = sources.filter { isEnabled($0) }
        let disabledSources = sources.filter { !isEnabled($0) }

        let disabledNewsNames = Set(disabledSources.filter { $0.category.lowercased() == "news" }.map { $0.name })

        let enabledBuiltInCategories: Set<String> = Set(
            enabledSources
                .filter { $0.category.lowercased() != "news" }
                .map { $0.category.uppercased() }
        )

        let showTrends = boolDefaultTrue("showTrends")
        let showPredictions = boolDefaultTrue("showPredictions")

        var enabledCustomNames: Set<String> = []
        let customData = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
        if let storage = CustomFeedStorage(rawValue: customData) {
            for feed in storage.feeds {
                let key = "custom_enabled_\(feed.id.uuidString)"
                if boolDefaultTrue(key) { enabledCustomNames.insert(feed.name) }
            }
        }

        return items.filter { item in
            if item.sourceName == "Local Weather" { return true }

            let val = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let up = val.uppercased()

            if item.sourceName == "Global Market Trends" || up == "TRENDS" { return showTrends }
            if up == "FUTURE" { return showPredictions }
            if up == "NEWS" { return !disabledNewsNames.contains(item.sourceName) }
            if enabledBuiltInCategories.contains(up) { return true }
            if enabledCustomNames.contains(val) { return true }

            return false
        }
    }

    // MARK: - Trends
    private func normalizeTrendItems(_ items: [TickerItem]) -> [TickerItem] {
        items.map { it in
            TickerItem(
                text: it.text,
                type: .news,
                value: "TRENDS",
                score: it.score,
                sourceDomain: it.sourceDomain,
                sourceName: "Global Market Trends",
                mediaURL: it.mediaURL,
                isVideo: it.isVideo,
                articleURL: it.articleURL,
                publishedAt: it.publishedAt ?? Date()
            )
        }
    }

    private func kickOffTrendsIfNeeded(force: Bool, reason: String) {
        let showTrends = boolDefaultTrue("showTrends")

        guard showTrends else {
            trendsTask?.cancel()
            trendsTask = nil
            trendItems.removeAll()
            rebuildLoadedAndVisible()
            dbg("TRENDS: skipped (\(reason)) disabled", level: .info)
            return
        }

        if !force, let last = lastTrendsRefreshAt, Date().timeIntervalSince(last) < trendsMinIntervalSeconds {
            dbg("TRENDS: throttled (\(reason)) last=\(last)", level: .info)
            return
        }

        if trendsTask != nil {
            dbg("TRENDS: already running (\(reason))", level: .info)
            return
        }

        dbg("TRENDS: kickoff (\(reason)) force=\(force)", level: .info)

        trendsTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }

            do {
                let incoming = try await self.trendProvider.fetchGlobalTrends()
                if Task.isCancelled { return }

                let normalized = self.normalizeTrendItems(incoming)
                let now = Date()
                let fresh = normalized.filter { !Staleness.isStale($0.publishedAt, maxDays: self.maxItemAgeDays, now: now) }

                self.trendItems = fresh
                self.lastTrendsRefreshAt = Date()

                self.rebuildLoadedAndVisible()
                self.trendsTask = nil
            } catch {
                self.dbg("❌ Trends fetch failed (\(reason)): \(error)", level: .error)
                self.trendsTask = nil
            }
        }
    }

    // MARK: - MIXER
    private func mixFeeds(_ items: [TickerItem]) -> [TickerItem] {
        let desired = maxVisibleItems

        let trendsEveryN = 4
        let trendsBoostAtStart = 2

        let newsMaxFraction: Double = 0.22
        let futureMaxFraction: Double = 0.22

        var trends: [TickerItem] = []
        var byTopic: [String: [TickerItem]] = [:]

        for item in items {
            if item.sourceName == "Local Weather" { continue }

            let v = (item.value ?? "").uppercased()
            if item.sourceName == "Global Market Trends" || v == "TRENDS" {
                trends.append(item)
                continue
            }

            let topic = (item.value ?? "UNKNOWN").trimmingCharacters(in: .whitespacesAndNewlines)
            byTopic[topic, default: []].append(item)
        }

        var mixedByTopic: [String: [TickerItem]] = [:]
        mixedByTopic.reserveCapacity(byTopic.count)

        for (topic, arr) in byTopic {
            mixedByTopic[topic] = roundRobinBySource(arr, maxPerSource: maxPerSourcePerCategory)
        }

        let mixedTrends = roundRobinBySource(trends, maxPerSource: maxPerSourcePerCategory)
        let topics = Array(mixedByTopic.keys)

        func priority(_ t: String) -> Int {
            switch t.uppercased() {
            case "NEWS": return 1
            case "FUTURE": return 2
            default: return 3
            }
        }

        var topicOrder = topics.sorted { a, b in
            let pa = priority(a), pb = priority(b)
            if pa != pb { return pa > pb }
            return a < b
        }

        // custom first, then future, then news
        let custom = topicOrder.filter { priority($0) == 3 }.shuffled()
        let future = topicOrder.filter { $0.uppercased() == "FUTURE" }
        let news = topicOrder.filter { $0.uppercased() == "NEWS" }
        topicOrder = custom + future + news

        var idxByTopic: [String: Int] = [:]
        for t in mixedByTopic.keys { idxByTopic[t] = 0 }

        let maxNews = Int(Double(desired) * newsMaxFraction)
        let maxFuture = Int(Double(desired) * futureMaxFraction)
        var usedNews = 0
        var usedFuture = 0

        func canTake(_ t: String) -> Bool {
            let up = t.uppercased()
            if up == "NEWS" { return usedNews < maxNews }
            if up == "FUTURE" { return usedFuture < maxFuture }
            return true
        }

        func record(_ t: String) {
            let up = t.uppercased()
            if up == "NEWS" { usedNews += 1 }
            if up == "FUTURE" { usedFuture += 1 }
        }

        var out: [TickerItem] = []
        out.reserveCapacity(desired)

        var trendIndex = 0
        var sinceTrend = 999

        if !mixedTrends.isEmpty {
            let take = min(trendsBoostAtStart, mixedTrends.count)
            for i in 0..<take {
                out.append(mixedTrends[i])
                trendIndex = i + 1
            }
            sinceTrend = 0
        }

        while out.count < desired {
            var progressed = false

            if trendIndex < mixedTrends.count, sinceTrend >= trendsEveryN {
                out.append(mixedTrends[trendIndex])
                trendIndex += 1
                sinceTrend = 0
                progressed = true
                if out.count >= desired { break }
            }

            for topic in topicOrder {
                guard canTake(topic) else { continue }
                guard let arr = mixedByTopic[topic], !arr.isEmpty else { continue }

                let i = idxByTopic[topic] ?? 0
                guard i < arr.count else { continue }

                out.append(arr[i])
                idxByTopic[topic] = i + 1
                record(topic)

                sinceTrend += 1
                progressed = true
                if out.count >= desired { break }

                if trendIndex < mixedTrends.count, sinceTrend >= trendsEveryN {
                    out.append(mixedTrends[trendIndex])
                    trendIndex += 1
                    sinceTrend = 0
                    if out.count >= desired { break }
                }
            }

            if !progressed { break }
        }

        if out.count < desired {
            var remainder: [TickerItem] = []
            for (topic, arr) in mixedByTopic {
                let start = idxByTopic[topic] ?? 0
                if start < arr.count { remainder.append(contentsOf: arr[start...]) }
            }

            remainder.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            for item in remainder where out.count < desired { out.append(item) }

            while out.count < desired, trendIndex < mixedTrends.count {
                out.append(mixedTrends[trendIndex])
                trendIndex += 1
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

    private func rebuildVisibleItemsFromLoadedNews() {
        let mixed = mixFeeds(loadedNews)
        if let weather = items.first(where: { $0.sourceName == "Local Weather" }) {
            setItems([weather] + Array(mixed.prefix(max(0, maxVisibleItems - 1))))
        } else {
            setItems(Array(mixed.prefix(maxVisibleItems)))
        }
    }

    // MARK: - Weather
    private func fetchWeather() async -> TickerItem? {
        let city = UserDefaults.standard.string(forKey: "weatherCity") ?? "Dublin"
        guard let location = await withTimeout(seconds: 2.0, operation: { await self.geocodeCity(city) }) else {
            return await fetchWeatherData(lat: 53.3498, long: -6.2603, name: "Dublin")
        }
        return await fetchWeatherData(lat: location.coordinate.latitude, long: location.coordinate.longitude, name: city)
    }

    private func fetchWeatherData(lat: Double, long: Double, name: String) async -> TickerItem? {
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(long)&current_weather=true"
        guard let url = URL(string: urlString) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10.0
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json, */*", forHTTPHeaderField: "Accept")
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")

            let (data, _) = try await self.session.data(for: request)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current_weather"] as? [String: Any],
                  let temp = current["temperature"] as? Double else { return nil }

            return TickerItem(
                text: "\(name.uppercased()): \(Int(temp))°C",
                type: .news,
                value: "Weather",
                score: nil,
                sourceDomain: "open-meteo.com",
                sourceName: "Local Weather",
                mediaURL: nil,
                isVideo: false,
                articleURL: URL(string: "https://weather.com")!,
                publishedAt: nil
            )
        } catch {
            return nil
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
    
    // Note: kept minimal usage of CoreLocation for geocoding
    private func geocodeCity(_ city: String) async -> CLLocation? {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let geocoder = CLGeocoder()
        return await withCheckedContinuation { continuation in
            geocoder.geocodeAddressString(trimmed) { placemarks, _ in
                continuation.resume(returning: placemarks?.first?.location)
            }
        }
    }

    // MARK: - OG enrichment (capped)
    private func maybeEnqueueOGEnrichment() {
        if let last = lastOGEnrichAt, Date().timeIntervalSince(last) < 120 { return }
        lastOGEnrichAt = Date()

        let candidates = items
            .filter { $0.mediaURL == nil }
            .filter { $0.sourceName != "Local Weather" && $0.sourceName != "Global Market Trends" && $0.sourceName != "SYSTEM" }

        enqueueOGEnrichment(for: Array(candidates.prefix(40)))
    }

    private func enqueueOGEnrichment(for items: [TickerItem]) {
        var seen = Set<URL>()
        for item in items {
            let u = item.articleURL
            if seen.contains(u) { continue }
            seen.insert(u)

            ogEnricher.enqueue(item: item) { [weak self] updated in
                guard let self else { return }
                Task { @MainActor in self.applyEnrichedItem(updated) }
            }
        }
    }

    private func applyEnrichedItem(_ updated: TickerItem) {
        if let idx = items.firstIndex(where: { TickerKey($0) == TickerKey(updated) }) {
            items[idx] = updated
            itemsRevision &+= 1
        }

        func replace(in arr: inout [TickerItem]) {
            if let i = arr.firstIndex(where: { TickerKey($0) == TickerKey(updated) }) {
                arr[i] = updated
            }
        }
        replace(in: &allFeedItems)
        replace(in: &trendItems)
        replace(in: &loadedNews)
    }

    // MARK: - Health check
    func runHealthCheckNow() {
        Task { [weak self] in
            guard let self else { return }
            await self.runFeedHealthCheck(reason: "manual")
        }
    }

    private enum FeedHealthStatus { case ok, badHTTP(Int), emptyOrUnparseable, error(String) }
    private struct FeedHealthResult { let source: FeedSource; let status: FeedHealthStatus }

    private func runFeedHealthCheck(reason: String) async {
        if isRunningHealthCheck { return }
        isRunningHealthCheck = true
        defer { isRunningHealthCheck = false }

        let enabled = self.sources.filter { self.isEnabled($0) }
        guard !enabled.isEmpty else {
            lastHealthCheckSummary = "No enabled feeds to check."
            return
        }

        dbg("HEALTHCHECK: starting (\(reason)) enabledFeeds=\(enabled.count)", level: .info)

        let fetcherLocal = self.fetcher

        func check(_ source: FeedSource) async -> FeedHealthResult {
            let (items, meta) = await fetcherLocal.fetchRSSWithMeta(
                source: source,
                type: .news,
                topicName: "HEALTH",
                forceNetwork: true
            )

            if let code = meta.statusCode, !(200...299).contains(code) {
                return FeedHealthResult(source: source, status: .badHTTP(code))
            }
            if items.isEmpty {
                return FeedHealthResult(source: source, status: .emptyOrUnparseable)
            }
            return FeedHealthResult(source: source, status: .ok)
        }

        let maxConcurrent = 6
        var failures: [FeedHealthResult] = []

        var idx = 0
        while idx < enabled.count {
            let chunk = Array(enabled[idx..<min(idx + maxConcurrent, enabled.count)])
            idx += chunk.count

            await withTaskGroup(of: FeedHealthResult.self) { group in
                for src in chunk { group.addTask { await check(src) } }
                for await result in group {
                    switch result.status {
                    case .ok: break
                    default: failures.append(result)
                    }
                }
            }
        }

        if failures.isEmpty {
            lastHealthCheckSummary = "Health check OK. \(enabled.count) feeds."
            dbg("HEALTHCHECK: OK", level: .info)
            return
        }

        dbg("HEALTHCHECK: disabling \(failures.count) dead feeds", level: .info)
        for f in failures {
            switch f.status {
            case .badHTTP(let code): dbg("  - ❌ \(f.source.name) HTTP \(code) \(f.source.url)", level: .info)
            case .emptyOrUnparseable: dbg("  - ❌ \(f.source.name) empty/unparseable \(f.source.url)", level: .info)
            case .error(let msg): dbg("  - ❌ \(f.source.name) error \(msg) \(f.source.url)", level: .info)
            case .ok: break
            }
            UserDefaults.standard.set(false, forKey: f.source.settingKey)
        }

        lastHealthCheckSummary = "Disabled \(failures.count) dead feeds."
        rebuildLoadedAndVisible()
        softRefresh()
    }

    // MARK: - AI News Sentiment
    private func scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: Double, force: Bool = false) {
        sentimentTask?.cancel()
        sentimentTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            await self.refreshNewsSentimentIfNeeded(force: force)
        }
    }

    func refreshNewsSentimentAfterRender(delaySeconds: Double = 0.2) {
        scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: delaySeconds, force: true)
    }

    private func refreshNewsSentimentIfNeeded(force: Bool = false) async {
        let todayKey = Self.dayKey(Date())
        if !force, sentimentCacheDayKey == todayKey, newsSentiment != nil { return }

        let todays = todaysNewsHeadlines(limit: 40)
        guard !todays.isEmpty else { return }
        if isComputingSentiment { return }

        isComputingSentiment = true
        defer { isComputingSentiment = false }

        do {
            let result = try await OpenAIService.classifySentimentAndSummarize(
                session: self.session,
                apiKey: Secrets.openAIKey,
                headlines: todays
            )
            self.newsSentiment = result
            self.sentimentCacheDayKey = todayKey
            dbg("SENTIMENT: \(result.level.rawValue) | \(result.threeWordSummary)", level: .info)
        } catch {
            dbg("❌ Sentiment error: \(error.localizedDescription)", level: .error)
        }
    }

    private func todaysNewsHeadlines(limit: Int) -> [String] {
        let cal = Calendar.current
        let now = Date()

        let filtered = items.filter { item in
            guard (item.value ?? "").uppercased() == "NEWS" else { return false }
            guard let d = item.publishedAt else { return false }
            return cal.isDate(d, inSameDayAs: now)
        }

        var seen = Set<String>()
        let unique = filtered.compactMap { it -> String? in
            let t = it.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if seen.contains(t) { return nil }
            seen.insert(t)
            return t
        }

        return Array(unique.prefix(limit))
    }

    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
