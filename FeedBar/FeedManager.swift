//
//  FeedManager.swift
//  SuperTicker
//

import Foundation
import Combine
import SwiftUI
import CoreLocation

@MainActor
class FeedManager: NSObject, ObservableObject {
    @Published var items: [TickerItem] = []
    @Published var itemsRevision: Int = 0
    @Published var sources: [FeedSource] = []

    @Published var lastHealthCheckSummary: String? = nil
    @Published var isRunningHealthCheck: Bool = false

    // ✅ AI sentiment “orb” state
    struct NewsSentiment: Equatable {
        enum Level: String, Codable { case green, amber, red }

        let level: Level
        let threeWordSummary: String   // e.g. "Rates Rise Again"
        let computedAt: Date
    }

    @Published var newsSentiment: NewsSentiment? = nil
    @Published var isComputingSentiment: Bool = false

    // Cache so we don’t call repeatedly
    private var sentimentCacheDayKey: String? = nil
    private var sentimentTask: Task<Void, Never>? = nil

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 15.0
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    private let trendProvider: any TrendProvider
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    // ✅ Trends moved out of the main load path (separate process/task)
    private var trendsTask: Task<Void, Never>?
    private var lastTrendsRefreshAt: Date? = nil
    private let trendsMinIntervalSeconds: TimeInterval = 60 * 60 // 1 hour throttle
    private let trendsInitialDelaySeconds: TimeInterval = 90      // show up later, not blocking first paint

    private var loadedNews: Set<TickerItem> = []
    private var lastNetworkRefreshAt: Date? = nil

    // Lazy OG image enrichment
    private let ogEnricher = OGImageEnricher()

    // MARK: - Request headers (critical for feeds that 403 "bots")
    private let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private let acceptHeader =
        "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
    private let acceptLanguage = "en-IE,en;q=0.9"

    // MARK: - Freshness rules
    private let maxItemAgeDays: Int = 90

    // MARK: - Refresh policy
    private let refreshIntervalSeconds: TimeInterval = 30 * 60    // 30 minutes
    private let initialHealthCheckDelay: TimeInterval = 5 * 60    // 5 minutes

    // MARK: - Mixer policy
    private let maxPerSourcePerCategory: Int = 12
    private let maxVisibleItems: Int = 200

    // MARK: - Sources
    private let defaultSources: [FeedSource] = [
        FeedSource(name: "BBC News", url: "https://feeds.bbci.co.uk/news/rss.xml", domain: "bbc.co.uk", defaultEnabled: true),
        FeedSource(name: "The Guardian World", url: "https://www.theguardian.com/world/rss", domain: "theguardian.com", defaultEnabled: true),
        FeedSource(name: "CNN Top Stories", url: "http://rss.cnn.com/rss/cnn_topstories.rss", domain: "cnn.com", defaultEnabled: true),
        FeedSource(name: "Sky News", url: "https://feeds.skynews.com/feeds/rss/home.xml", domain: "skynews.com", defaultEnabled: false),
        FeedSource(name: "NPR Top Stories", url: "https://feeds.npr.org/1001/rss.xml", domain: "npr.org", defaultEnabled: true),
        FeedSource(name: "Al Jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml", domain: "aljazeera.com", defaultEnabled: false),
        FeedSource(name: "Deutsche Welle", url: "https://rss.dw.com/rdf/rss-en-all", domain: "dw.com", defaultEnabled: false),
        FeedSource(name: "Financial Times", url: "https://www.ft.com/?format=rss", domain: "ft.com", defaultEnabled: true),
        FeedSource(name: "WSJ World News", url: "https://feeds.a.dj.com/rss/RSSWorldNews.xml", domain: "wsj.com", defaultEnabled: false),
        FeedSource(name: "WSJ Tech", url: "https://feeds.a.dj.com/rss/RSSWSJD.xml", domain: "wsj.com", defaultEnabled: false),
        FeedSource(name: "Bloomberg Technology", url: "https://www.bloomberg.com/feed/podcast/etf-report.xml", domain: "bloomberg.com", defaultEnabled: false),
        FeedSource(name: "Harvard Business Review", url: "https://hbr.org/feed", domain: "hbr.org", defaultEnabled: false),
        FeedSource(name: "McKinsey Insights", url: "https://www.mckinsey.com/featured-insights/rss", domain: "mckinsey.com", defaultEnabled: false),

        FeedSource(name: "Hacker News", url: "https://news.ycombinator.com/rss", domain: "ycombinator.com", defaultEnabled: true),
        FeedSource(name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", domain: "arstechnica.com", defaultEnabled: true),
        FeedSource(name: "The Verge", url: "https://www.theverge.com/rss/index.xml", domain: "theverge.com", defaultEnabled: false),
        FeedSource(name: "Wired", url: "https://www.wired.com/feed/rss", domain: "wired.com", defaultEnabled: false),
        FeedSource(name: "TechCrunch", url: "https://techcrunch.com/feed/", domain: "techcrunch.com", defaultEnabled: true),
        FeedSource(name: "The Register", url: "https://www.theregister.com/headlines.atom", domain: "theregister.com", defaultEnabled: false),
        FeedSource(name: "MIT Technology Review", url: "https://www.technologyreview.com/topnews.rss", domain: "technologyreview.com", defaultEnabled: true),
        FeedSource(name: "IEEE Spectrum", url: "https://spectrum.ieee.org/rss/fulltext", domain: "ieee.org", defaultEnabled: false),

        FeedSource(name: "YC News", url: "https://www.ycombinator.com/blog/rss", domain: "ycombinator.com", defaultEnabled: false),
        FeedSource(name: "a16z", url: "https://a16z.com/feed/", domain: "a16z.com", defaultEnabled: false),
        FeedSource(name: "Sequoia", url: "https://www.sequoiacap.com/feed/", domain: "sequoiacap.com", defaultEnabled: false),
        FeedSource(name: "First Round Review", url: "https://review.firstround.com/rss", domain: "firstround.com", defaultEnabled: false),

        FeedSource(name: "GitHub Blog", url: "https://github.blog/feed/", domain: "github.blog", defaultEnabled: false),
        FeedSource(name: "GitHub Changelog", url: "https://github.blog/changelog/feed/", domain: "github.blog", defaultEnabled: false),
        FeedSource(name: "AWS News Blog", url: "https://aws.amazon.com/blogs/aws/feed/", domain: "aws.amazon.com", defaultEnabled: false),
        FeedSource(name: "Google AI Blog", url: "https://ai.googleblog.com/feeds/posts/default", domain: "googleblog.com", defaultEnabled: false),
        FeedSource(name: "Google Security Blog", url: "https://security.googleblog.com/feeds/posts/default", domain: "googleblog.com", defaultEnabled: false),
        FeedSource(name: "Cloudflare Blog", url: "https://blog.cloudflare.com/rss/", domain: "cloudflare.com", defaultEnabled: false),
        FeedSource(name: "Stripe Blog", url: "https://stripe.com/blog/feed.rss", domain: "stripe.com", defaultEnabled: false),
        FeedSource(name: "Shopify Engineering", url: "https://shopify.engineering/blog.atom", domain: "shopify.engineering", defaultEnabled: false),

        FeedSource(name: "Krebs on Security", url: "https://krebsonsecurity.com/feed/", domain: "krebsonsecurity.com", defaultEnabled: false),
        FeedSource(name: "Schneier on Security", url: "https://www.schneier.com/feed/atom/", domain: "schneier.com", defaultEnabled: false),
        FeedSource(name: "The Hacker News", url: "https://feeds.feedburner.com/TheHackersNews", domain: "thehackernews.com", defaultEnabled: false),

        FeedSource(name: "OpenAI News", url: "https://openai.com/news/rss.xml", domain: "openai.com", defaultEnabled: true),
        FeedSource(name: "DeepMind Blog", url: "https://deepmind.google/discover/blog/rss.xml", domain: "deepmind.google", defaultEnabled: false),
        FeedSource(name: "Anthropic News", url: "https://www.anthropic.com/news/rss.xml", domain: "anthropic.com", defaultEnabled: false),
        FeedSource(name: "Google Research", url: "https://research.google/blog/rss/", domain: "google.com", defaultEnabled: false),
        FeedSource(name: "Meta AI", url: "https://ai.meta.com/blog/rss/", domain: "meta.com", defaultEnabled: false),
        FeedSource(name: "Hugging Face Blog", url: "https://huggingface.co/blog/feed.xml", domain: "huggingface.co", defaultEnabled: false),

        FeedSource(name: "arXiv AI", url: "https://export.arxiv.org/rss/cs.AI", domain: "arxiv.org", defaultEnabled: false),
        FeedSource(name: "arXiv ML", url: "https://export.arxiv.org/rss/cs.LG", domain: "arxiv.org", defaultEnabled: false),
        FeedSource(name: "arXiv HCI", url: "https://export.arxiv.org/rss/cs.HC", domain: "arxiv.org", defaultEnabled: false),
        FeedSource(name: "arXiv Security", url: "https://export.arxiv.org/rss/cs.CR", domain: "arxiv.org", defaultEnabled: false),

        FeedSource(name: "Nielsen Norman Group", url: "https://www.nngroup.com/feed/rss/", domain: "nngroup.com", defaultEnabled: false),
        FeedSource(name: "Inside Intercom", url: "https://www.intercom.com/blog/feed/", domain: "intercom.com", defaultEnabled: false),
        FeedSource(name: "Figma Blog", url: "https://www.figma.com/blog/rss.xml", domain: "figma.com", defaultEnabled: false),

        FeedSource(name: "Stratechery", url: "https://stratechery.com/feed/", domain: "stratechery.com", defaultEnabled: false),
        FeedSource(name: "Benedict Evans", url: "https://www.ben-evans.com/benedictevans?format=rss", domain: "ben-evans.com", defaultEnabled: false),

        FeedSource(name: "NOAA Climate", url: "https://www.climate.gov/feeds/news-features/rss.xml", domain: "climate.gov", defaultEnabled: false),
        FeedSource(name: "IEA News", url: "https://www.iea.org/rss/news.xml", domain: "iea.org", defaultEnabled: false),

        FeedSource(name: "BBC Business", url: "https://feeds.bbci.co.uk/news/business/rss.xml", domain: "bbc.co.uk", defaultEnabled: false),
        FeedSource(name: "BBC Technology", url: "https://feeds.bbci.co.uk/news/technology/rss.xml", domain: "bbc.co.uk", defaultEnabled: false),
        FeedSource(name: "Guardian Technology", url: "https://www.theguardian.com/uk/technology/rss", domain: "theguardian.com", defaultEnabled: false),
        FeedSource(name: "Guardian Business", url: "https://www.theguardian.com/uk/business/rss", domain: "theguardian.com", defaultEnabled: false),
        FeedSource(name: "NPR Technology", url: "https://feeds.npr.org/1019/rss.xml", domain: "npr.org", defaultEnabled: false),
        FeedSource(name: "NPR Planet Money", url: "https://feeds.npr.org/510289/podcast.xml", domain: "npr.org", defaultEnabled: false),
        FeedSource(name: "NPR Consider This", url: "https://feeds.npr.org/510355/podcast.xml", domain: "npr.org", defaultEnabled: false),

        FeedSource(name: "Apple Newsroom", url: "https://www.apple.com/newsroom/rss-feed.rss", domain: "apple.com", defaultEnabled: false),
        FeedSource(name: "Microsoft Blog", url: "https://blogs.microsoft.com/feed/", domain: "microsoft.com", defaultEnabled: false),
        FeedSource(name: "Google Blog", url: "https://blog.google/rss/", domain: "google.com", defaultEnabled: false),

        FeedSource(name: "Mozilla Blog", url: "https://blog.mozilla.org/feed/", domain: "mozilla.org", defaultEnabled: false),
        FeedSource(name: "Stack Overflow Blog", url: "https://stackoverflow.blog/feed/", domain: "stackoverflow.blog", defaultEnabled: false),
        FeedSource(name: "JetBrains Blog", url: "https://blog.jetbrains.com/feed/", domain: "jetbrains.com", defaultEnabled: false),

        FeedSource(name: "The Information (if you have access)", url: "https://www.theinformation.com/feed", domain: "theinformation.com", defaultEnabled: false),

        FeedSource(name: "NASA Breaking News", url: "https://www.nasa.gov/rss/dyn/breaking_news.rss", domain: "nasa.gov", defaultEnabled: false),
        FeedSource(name: "Nature News", url: "https://www.nature.com/subjects/science/rss", domain: "nature.com", defaultEnabled: false),
        FeedSource(name: "Science Magazine", url: "https://www.science.org/rss/news_current.xml", domain: "science.org", defaultEnabled: false)
    ]

    let predictionSources: [FeedSource] = [
        FeedSource(name: "Futurism", url: "https://futurism.com/feed", domain: "futurism.com", defaultEnabled: true),
        FeedSource(name: "Singularity Hub", url: "https://singularityhub.com/feed/", domain: "singularityhub.com", defaultEnabled: true)
    ]

    init(trendProvider: (any TrendProvider)? = nil) {
        if let provider = trendProvider {
            self.trendProvider = provider
        } else {
            self.trendProvider = PythonTrendAdapter()
        }
        self.sources = defaultSources
        super.init()

        // 1) First paint quickly, then load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.hardRefresh()
        }

        // ✅ Trends: explicitly delayed + separate task so Python can't stall UX
        DispatchQueue.main.asyncAfter(deadline: .now() + trendsInitialDelaySeconds) { [weak self] in
            self?.kickOffTrendsIfNeeded(force: false, reason: "startup-delayed")
        }

        // 2) Healthcheck 5 mins after startup (non-blocking for UX)
        DispatchQueue.main.asyncAfter(deadline: .now() + initialHealthCheckDelay) { [weak self] in
            self?.runHealthCheckNow()
        }

        // 3) Auto refresh every 30 mins (non-blocking; just pulls new items)
        startAutoRefresh(interval: refreshIntervalSeconds)

        // ✅ AI sentiment: schedule after first paint (non-blocking)
        scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: 7)
    }

    deinit {
        refreshTask?.cancel()
        autoRefreshTask?.cancel()
        trendsTask?.cancel()
        sentimentTask?.cancel()
    }

    // MARK: - Centralized visible items setter (always bumps revision)
    private func setItems(_ newItems: [TickerItem]) {
        self.items = newItems
        self.itemsRevision &+= 1
    }

    // MARK: - Public: schedule health check
    func scheduleHealthCheck(after seconds: TimeInterval = 300) {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self.runFeedHealthCheck(reason: "scheduled")
        }
    }

    // MARK: - Public: validate + add RSS by URL (Admin UI)
    @MainActor
    func validateAndAddCustomRSS(urlString: String, providedName: String?) async throws -> CustomFeed {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host
        else {
            throw NSError(domain: "feeds", code: 400, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        // Use existing pipeline to validate
        let domain = host.replacingOccurrences(of: "www.", with: "")
        let name = {
            let n = (providedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? domain : n
        }()

        let tempSource = FeedSource(name: name, url: trimmed, domain: domain, defaultEnabled: true)

        // Force network so we really validate, not cached junk
        let parsed = await fetchRSS(source: tempSource, type: .news, topicName: "NEWS", forceNetwork: true)

        // If empty/unparseable, reject
        if parsed.isEmpty {
            throw NSError(domain: "feeds", code: 422, userInfo: [NSLocalizedDescriptionKey: "Empty/unparseable feed"])
        }

        // Persist as CustomFeed
        let newFeed = CustomFeed(id: UUID(), name: name, url: trimmed, domain: domain)

        let raw = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
        var storage = CustomFeedStorage(rawValue: raw) ?? CustomFeedStorage(feeds: [])

        // Dedupe by URL
        if storage.feeds.contains(where: { $0.url == newFeed.url }) {
            throw NSError(domain: "feeds", code: 409, userInfo: [NSLocalizedDescriptionKey: "Already exists"])
        }

        storage.feeds.append(newFeed)
        UserDefaults.standard.set(storage.rawValue, forKey: "customFeeds")

        // Ensure enabled by default
        UserDefaults.standard.set(true, forKey: "custom_enabled_\(newFeed.id.uuidString)")

        return newFeed
    }

    // MARK: - Public: manual trigger
    func runHealthCheckNow() {
        Task { [weak self] in
            guard let self else { return }
            await self.runFeedHealthCheck(reason: "manual")
        }
    }

    // MARK: - Public: manual trigger for sentiment
    func refreshNewsSentimentAfterRender(delaySeconds: Double = 0.2) {
        scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: delaySeconds, force: true)
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
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self.progressiveLoad(forceNetwork: true)
        }
    }

    // MARK: - ACTIONS
    func softRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.progressiveLoad(forceNetwork: false)
        }
    }

    func hardRefresh() {
        refreshTask?.cancel()
        loadedNews.removeAll()
        setItems([])

        // allow a fresh sentiment attempt if needed (cache still prevents repeat per day)
        sentimentTask?.cancel()
        sentimentTask = nil

        Task { await progressiveLoad(forceNetwork: true) }
    }

    func refreshWeatherOnly() {
        Task {
            if let newWeather = await self.fetchWeather() {
                var updated = self.items
                if let index = updated.firstIndex(where: { $0.sourceName == "Local Weather" }) {
                    updated[index] = newWeather
                } else {
                    updated.insert(newWeather, at: 0)
                }
                self.setItems(updated)
            }
        }
    }

    // MARK: - LOGIC
    private func progressiveLoad(forceNetwork: Bool) async {
        pruneDisabledItems()

        if let weather = await fetchWeather() {
            let mixedItems = mixFeeds(self.loadedNews)
            withAnimation {
                self.setItems([weather] + Array(mixedItems.prefix(maxVisibleItems - 1)))
            }
        }

        // ✅ Schedule sentiment after we have something visible (non-blocking)
        scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: 6)

        if forceNetwork {
            lastNetworkRefreshAt = Date()
        }

        await withTaskGroup(of: [TickerItem].self) { group in
            // A. News
            for source in sources where isEnabled(source) {
                group.addTask { await self.fetchRSS(source: source, type: .news, topicName: "NEWS", forceNetwork: forceNetwork) }
            }

            // B. Predictions
            let showPredictions = UserDefaults.standard.object(forKey: "showPredictions") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "showPredictions")

            if showPredictions {
                for source in predictionSources {
                    group.addTask { await self.fetchRSS(source: source, type: .prediction, topicName: "FUTURE", forceNetwork: forceNetwork) }
                }
            }

            // ✅ C. Trends REMOVED from task group (separate task after refresh)

            // D. Custom
            let customData = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
            if let storage = CustomFeedStorage(rawValue: customData) {
                for custom in storage.feeds {
                    let key = "custom_enabled_\(custom.id.uuidString)"
                    let enabled = (UserDefaults.standard.object(forKey: key) == nil)
                        ? true
                        : UserDefaults.standard.bool(forKey: key)

                    if enabled {
                        let source = FeedSource(name: custom.name, url: custom.url, domain: custom.domain, defaultEnabled: true)
                        group.addTask { await self.fetchRSS(source: source, type: .news, topicName: custom.name, forceNetwork: forceNetwork) }
                    }
                }
            }

            // E. Stream
            for await batch in group {
                if batch.isEmpty { continue }

                let freshBatch = batch.filter { !$0.isStale(maxDays: self.maxItemAgeDays) }
                let newItems = freshBatch.filter { !self.loadedNews.contains($0) }
                if newItems.isEmpty { continue }

                self.loadedNews.formUnion(newItems)
                self.loadedNews = self.setPrunedByRecency(self.loadedNews)

                let mixedList = self.mixFeeds(self.loadedNews)
                var finalItems = mixedList
                if let weather = self.items.first(where: { $0.sourceName == "Local Weather" }) {
                    finalItems.insert(weather, at: 0)
                }

                self.setItems(Array(finalItems.prefix(maxVisibleItems)))

                // Lazy OG image enrichment (does not block UI)
                self.enqueueOGEnrichment(for: self.items)

                // ✅ Schedule sentiment again (cheap; cache prevents waste)
                scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: 6)

                self.debugPrintState(phase: "batch-merge")
            }
        }

        // ✅ Kick off trends after the main refresh work completes (still non-blocking)
        kickOffTrendsIfNeeded(force: forceNetwork, reason: forceNetwork ? "post-network-refresh" : "post-soft-refresh")

        debugPrintState(phase: "post-load")
        refreshTask = nil
    }

    // MARK: - AI News Sentiment (Responses API)
    private func scheduleSentimentComputationAfterRenderIfNeeded(delaySeconds: Double, force: Bool = false) {
        sentimentTask?.cancel()
        sentimentTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            await self.refreshNewsSentimentIfNeeded(force: force)
        }
    }

    private func refreshNewsSentimentIfNeeded(force: Bool = false) async {
        let todayKey = Self.dayKey(Date())
        if !force, sentimentCacheDayKey == todayKey, newsSentiment != nil {
            print("🤖 Sentiment skip: cached for \(todayKey)")
            return
        }

        let todays = todaysNewsHeadlines(limit: 40)
        print("🤖 Sentiment headlines today: \(todays.count) (force=\(force))")

        guard !todays.isEmpty else {
            print("🤖 Sentiment abort: no 'today' NEWS headlines yet")
            return
        }

        if isComputingSentiment {
            print("🤖 Sentiment skip: already computing")
            return
        }

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
            print("✅ Sentiment OK: \(result.level.rawValue) | \(result.threeWordSummary)")
        } catch {
            print("❌ Sentiment error: \(error.localizedDescription)")
        }
    }

    private func todaysNewsHeadlines(limit: Int) -> [String] {
        let cal = Calendar.current
        let now = Date()

        let filtered = items.filter { item in
            guard (item.value ?? "") == "NEWS" else { return false }
            guard let d = item.publishedAt else { return false }
            guard cal.isDate(d, inSameDayAs: now) else { return false }
            return true
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

    // MARK: - Trends (separate process/task, throttled)
    private func kickOffTrendsIfNeeded(force: Bool, reason: String) {
        let showTrends = UserDefaults.standard.object(forKey: "showTrends") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "showTrends")

        guard showTrends else {
            print("📈 Trends skipped (\(reason)): disabled in settings")
            trendsTask?.cancel()
            trendsTask = nil
            removeExistingTrendsFromCache()
            return
        }

        if !force, let last = lastTrendsRefreshAt, Date().timeIntervalSince(last) < trendsMinIntervalSeconds {
            let remaining = Int(trendsMinIntervalSeconds - Date().timeIntervalSince(last))
            print("📈 Trends throttled (\(reason)): next allowed in ~\(max(0, remaining))s")
            return
        }

        if trendsTask != nil {
            print("📈 Trends already running (\(reason))")
            return
        }

        print("📈 Trends kickoff (\(reason))… (force=\(force))")

        trendsTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }

            do {
                print("🐍 Trends fetch start (python) (\(reason))")
                let trendItems = try await self.fetchTrendsOffMain()
                if Task.isCancelled { return }

                await MainActor.run {
                    self.lastTrendsRefreshAt = Date()
                    self.mergeTrendsIntoCache(trendItems)
                    print("✅ Trends fetch OK (\(reason)): \(trendItems.count) items")
                    self.debugPrintState(phase: "trends-merge (\(reason))")
                    self.trendsTask = nil
                }
            } catch {
                await MainActor.run {
                    print("❌ Trends fetch failed (\(reason)): \(error)")
                    self.trendsTask = nil
                }
            }
        }
    }

    private func fetchTrendsOffMain() async throws -> [TickerItem] {
        let provider = self.trendProvider

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                Task {
                    do {
                        let items = try await provider.fetchGlobalTrends()
                        continuation.resume(returning: items)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func removeExistingTrendsFromCache() {
        loadedNews = setFilter(loadedNews) { $0.sourceName != "Global Market Trends" }

        let mixedList = mixFeeds(loadedNews)
        if let weather = items.first(where: { $0.sourceName == "Local Weather" }) {
            setItems([weather] + Array(mixedList.prefix(maxVisibleItems - 1)))
        } else {
            setItems(Array(mixedList.prefix(maxVisibleItems)))
        }
    }

    private func mergeTrendsIntoCache(_ incoming: [TickerItem]) {
        loadedNews = setFilter(loadedNews) { $0.sourceName != "Global Market Trends" }

        let fresh = incoming.filter { !$0.isStale(maxDays: maxItemAgeDays) }
        if !fresh.isEmpty {
            loadedNews.formUnion(fresh)
        }

        loadedNews = setPrunedByRecency(loadedNews)

        let mixedList = mixFeeds(loadedNews)
        var finalItems = mixedList
        if let weather = items.first(where: { $0.sourceName == "Local Weather" }) {
            finalItems.insert(weather, at: 0)
        }

        setItems(Array(finalItems.prefix(maxVisibleItems)))
        enqueueOGEnrichment(for: items)
    }

    // MARK: - MIXER (Trends priority)
    private func mixFeeds(_ items: Set<TickerItem>) -> [TickerItem] {
        var topics: [TickerItem] = []
        var future: [TickerItem] = []
        var news: [TickerItem] = []
        var trends: [TickerItem] = []

        for item in items {
            if item.sourceName == "Local Weather" { continue }

            let val = item.value ?? ""
            if item.sourceName == "Global Market Trends" {
                trends.append(item)
            } else if val == "NEWS" {
                news.append(item)
            } else if val == "FUTURE" {
                future.append(item)
            } else {
                topics.append(item)
            }
        }

        let mixedTopics = roundRobinBySource(topics, maxPerSource: maxPerSourcePerCategory)
        let mixedFuture = roundRobinBySource(future, maxPerSource: maxPerSourcePerCategory)
        let mixedNews = roundRobinBySource(news, maxPerSource: maxPerSourcePerCategory)
        let mixedTrends = roundRobinBySource(trends, maxPerSource: maxPerSourcePerCategory)

        var result: [TickerItem] = []
        var tIndex = 0, fIndex = 0, nIndex = 0, trIndex = 0

        // Trends priority interleave:
        // Trends -> Topic -> Trends -> Future -> News
        while tIndex < mixedTopics.count || trIndex < mixedTrends.count || fIndex < mixedFuture.count || nIndex < mixedNews.count {
            if trIndex < mixedTrends.count { result.append(mixedTrends[trIndex]); trIndex += 1 }
            if tIndex < mixedTopics.count { result.append(mixedTopics[tIndex]); tIndex += 1 }
            if trIndex < mixedTrends.count { result.append(mixedTrends[trIndex]); trIndex += 1 }
            if fIndex < mixedFuture.count { result.append(mixedFuture[fIndex]); fIndex += 1 }
            if nIndex < mixedNews.count { result.append(mixedNews[nIndex]); nIndex += 1 }
        }

        return result
    }

    private func roundRobinBySource(_ items: [TickerItem], maxPerSource: Int) -> [TickerItem] {
        guard !items.isEmpty else { return [] }

        var grouped = Dictionary(grouping: items, by: { $0.sourceName })

        for key in grouped.keys {
            grouped[key]?.sort { a, b in
                let da = a.publishedAt ?? .distantPast
                let db = b.publishedAt ?? .distantPast
                return da > db
            }
            if let capped = grouped[key]?.prefix(maxPerSource) {
                grouped[key] = Array(capped)
            }
        }

        var sourceKeys = Array(grouped.keys)
        sourceKeys.shuffle()

        var indices: [String: Int] = [:]
        indices.reserveCapacity(sourceKeys.count)
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

    // MARK: - FILTERING
    private func pruneDisabledItems() {
        let disabledNewsNames = Set(sources.filter { !isEnabled($0) }.map { $0.name })
        let showTrends = UserDefaults.standard.object(forKey: "showTrends") == nil ? true : UserDefaults.standard.bool(forKey: "showTrends")
        let showPredictions = UserDefaults.standard.object(forKey: "showPredictions") == nil ? true : UserDefaults.standard.bool(forKey: "showPredictions")

        var validCustomNames: Set<String> = []
        let customData = UserDefaults.standard.string(forKey: "customFeeds") ?? "[]"
        if let storage = CustomFeedStorage(rawValue: customData) {
            for feed in storage.feeds {
                let key = "custom_enabled_\(feed.id.uuidString)"
                if (UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)) {
                    validCustomNames.insert(feed.name)
                }
            }
        }

        loadedNews = setPrunedByRecency(loadedNews)

        loadedNews = setFilter(loadedNews) { item in
            if item.sourceName == "Local Weather" { return true }

            let val = item.value ?? ""

            if item.sourceName == "Global Market Trends" {
                return showTrends
            }
            if val == "FUTURE" {
                return showPredictions
            }

            if val == "NEWS" {
                return !disabledNewsNames.contains(item.sourceName)
            }

            return validCustomNames.contains(val)
        }

        let mixed = mixFeeds(loadedNews)
        if let weather = items.first(where: { $0.sourceName == "Local Weather" }) {
            setItems([weather] + Array(mixed.prefix(maxVisibleItems - 1)))
        } else {
            setItems(Array(mixed.prefix(maxVisibleItems)))
        }

        debugPrintState(phase: "prune", disabledNews: disabledNewsNames, trends: showTrends, future: showPredictions, custom: validCustomNames)

        if !showTrends {
            trendsTask?.cancel()
            trendsTask = nil
            removeExistingTrendsFromCache()
        }
    }

    private func debugPrintState(
        phase: String,
        disabledNews: Set<String>? = nil,
        trends: Bool? = nil,
        future: Bool? = nil,
        custom: Set<String>? = nil
    ) {
        let pruned = setPrunedByRecency(loadedNews)
        let staleCount = loadedNews.count - pruned.count

        print("------- FEED MANAGER DEBUG -------")
        print("🧭 Phase: \(phase)")
        if let t = trends { print("📈 Show Trends: \(t)") }
        if let f = future { print("🔮 Show Future: \(f)") }
        print("🧹 Recency prune: -\(staleCount) (>\(self.maxItemAgeDays)d)")
        print("📦 CACHE STATS: \(pruned.count) items (raw: \(loadedNews.count))")
        print("🧾 VISIBLE ITEMS: \(items.count) (rev=\(itemsRevision))")

        let counts = Dictionary(grouping: pruned, by: { $0.sourceName })
        for (key, value) in counts {
            print("   - \(key): \(value.count) items")
        }
        print("----------------------------------")
    }

    // MARK: - Helpers (Set-safe filtering)
    private func setFilter(_ set: Set<TickerItem>, include: (TickerItem) -> Bool) -> Set<TickerItem> {
        var out = Set<TickerItem>()
        out.reserveCapacity(set.count)
        for item in set where include(item) {
            out.insert(item)
        }
        return out
    }

    private func setPrunedByRecency(_ set: Set<TickerItem>) -> Set<TickerItem> {
        return setFilter(set) { !$0.isStale(maxDays: self.maxItemAgeDays) }
    }

    private func isEnabled(_ source: FeedSource) -> Bool {
        return UserDefaults.standard.object(forKey: source.settingKey) == nil
            ? source.defaultEnabled
            : UserDefaults.standard.bool(forKey: source.settingKey)
    }

    // IMPORTANT: use URLRequest so headers apply
    private func fetchRSS(source: FeedSource, type: TickerType, topicName: String, forceNetwork: Bool) async -> [TickerItem] {
        guard let url = URL(string: source.url) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12.0
            request.cachePolicy = forceNetwork ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")

            let (data, response) = try await self.session.data(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("❌ RSS HTTP \(http.statusCode) for \(source.name) (\(source.url))")
                return []
            }

            return await parseXMLInBackground(data: data, source: source, type: type, topicName: topicName)
        } catch {
            print("❌ RSS fetch error for \(source.name): \(error.localizedDescription)")
            return []
        }
    }

    nonisolated private func parseXMLInBackground(data: Data, source: FeedSource, type: TickerType, topicName: String) async -> [TickerItem] {
        let parser = RSSParser(data: data, source: source, type: type, topicName: topicName, maxAgeDays: maxItemAgeDays)
        return parser.parse()
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
                sourceDomain: "meteo.com",
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
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            return await group.next() ?? nil
        }
    }

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

    // MARK: - Lazy OG image enrichment
    private func enqueueOGEnrichment(for items: [TickerItem]) {
        for item in items {
            guard item.mediaURL == nil else { continue }
            guard item.sourceName != "Local Weather" else { continue }
            guard item.sourceName != "Global Market Trends" else { continue }

            ogEnricher.enqueue(item: item) { [weak self] updated in
                guard let self else { return }
                Task { @MainActor in
                    self.applyEnrichedItem(updated)
                }
            }
        }
    }

    @MainActor
    private func applyEnrichedItem(_ updated: TickerItem) {
        if let idx = items.firstIndex(where: { $0 == updated }) {
            items[idx] = updated
            itemsRevision &+= 1
        }

        if loadedNews.contains(updated) {
            loadedNews.remove(updated)
            loadedNews.insert(updated)
        }
    }

    // MARK: - Feed health check
    private enum FeedHealthStatus {
        case ok
        case badHTTP(Int)
        case emptyOrUnparseable
        case error(String)
    }

    private struct FeedHealthResult {
        let source: FeedSource
        let status: FeedHealthStatus
    }

    private func checkFeedHealth(_ source: FeedSource) async -> FeedHealthResult {
        guard let url = URL(string: source.url) else {
            return FeedHealthResult(source: source, status: .error("Bad URL"))
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10.0
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")

            let (data, response) = try await self.session.data(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return FeedHealthResult(source: source, status: .badHTTP(http.statusCode))
            }

            let parsed = await parseXMLInBackground(data: data, source: source, type: .news, topicName: "HEALTH")
            if parsed.isEmpty {
                return FeedHealthResult(source: source, status: .emptyOrUnparseable)
            }

            return FeedHealthResult(source: source, status: .ok)
        } catch {
            return FeedHealthResult(source: source, status: .error(error.localizedDescription))
        }
    }

    private func runFeedHealthCheck(reason: String) async {
        if isRunningHealthCheck { return }
        isRunningHealthCheck = true
        defer { isRunningHealthCheck = false }

        let toCheck = self.sources.filter { self.isEnabled($0) }
        guard !toCheck.isEmpty else {
            lastHealthCheckSummary = "No enabled feeds to check."
            return
        }

        print("🩺 Feed health check (\(reason)) starting: \(toCheck.count) enabled feeds…")

        let maxConcurrent = 8
        var failures: [FeedHealthResult] = []

        var idx = 0
        while idx < toCheck.count {
            let chunk = Array(toCheck[idx..<min(idx + maxConcurrent, toCheck.count)])
            idx += chunk.count

            await withTaskGroup(of: FeedHealthResult.self) { group in
                for src in chunk {
                    group.addTask { await self.checkFeedHealth(src) }
                }
                for await result in group {
                    switch result.status {
                    case .ok:
                        break
                    default:
                        failures.append(result)
                    }
                }
            }
        }

        if failures.isEmpty {
            lastHealthCheckSummary = "Health check OK. \(toCheck.count) feeds."
            print("✅ Feed health check OK")
            return
        }

        for f in failures {
            let name = f.source.name
            let url = f.source.url

            switch f.status {
            case .badHTTP(let code):
                print("   - ❌ \(name) (HTTP \(code)) \(url)")
            case .emptyOrUnparseable:
                print("   - ❌ \(name) (empty/unparseable) \(url)")
            case .error(let msg):
                print("   - ❌ \(name) (error: \(msg)) \(url)")
            case .ok:
                break
            }

            UserDefaults.standard.set(false, forKey: f.source.settingKey)
        }

        lastHealthCheckSummary = "Disabled \(failures.count) dead feeds."
        pruneDisabledItems()
        softRefresh()
    }
}

// MARK: - OpenAI (Responses API) helper
private enum OpenAIService {
    private struct SentimentResponse: Codable {
        let level: String
        let threeWordSummary: String
    }

    static func classifySentimentAndSummarize(
        session: URLSession,
        apiKey: String,
        headlines: [String]
    ) async throws -> FeedManager.NewsSentiment {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "openai", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing API key"])
        }

        let url = URL(string: "https://api.openai.com/v1/responses")!

        // Keep prompt extremely tight to reduce latency + token spend
        let joined = headlines.prefix(40).map { "• \($0)" }.joined(separator: "\n")

        let instructions =
"""
You are classifying the overall sentiment of today's news headlines.
Return STRICT JSON only (no markdown, no extra text).
Schema:
{"level":"green|amber|red","threeWordSummary":"exactly three words"}
Rules:
- green = broadly positive
- amber = mixed/uncertain/neutral
- red = broadly negative
- threeWordSummary MUST be exactly 3 words, Title Case, no punctuation.
"""

        // Try gpt-5.2 first (your preference), then fallbacks
        let modelCandidates = ["gpt-5.2", "gpt-4.1-mini", "gpt-4o-mini", "gpt-4o"]

        var lastError: Error?

        for model in modelCandidates {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 18.0
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: Any] = [
                    "model": model,
                    "instructions": instructions,
                    "input": "HEADLINES (today only):\n\(joined)"
                ]

                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

                print("🤖 OpenAI request: model=\(model), headlines=\(min(40, headlines.count))")

                let (data, response) = try await session.data(for: request)

                if let http = response as? HTTPURLResponse {
                    let reqId = http.value(forHTTPHeaderField: "x-request-id") ?? "n/a"
                    print("🤖 OpenAI HTTP \(http.statusCode) (request-id: \(reqId)) model=\(model)")
                    if !(200...299).contains(http.statusCode) {
                        let snippet = String(data: data, encoding: .utf8) ?? ""
                        print("🤖 OpenAI error body (first 800 chars):\n\(snippet.prefix(800))")
                        throw NSError(
                            domain: "openai",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(snippet.prefix(240))"]
                        )
                    }
                }

                let payloadAny = try JSONSerialization.jsonObject(with: data, options: [])
                if let dict = payloadAny as? [String: Any] {
                    print("🤖 OpenAI payload keys: \(Array(dict.keys).sorted()) model=\(model)")
                }

                let payloadData = try JSONSerialization.data(withJSONObject: payloadAny, options: [.prettyPrinted])
                let payloadString = String(data: payloadData, encoding: .utf8) ?? ""
                print("🤖 OpenAI payload (first 1200 chars) model=\(model):\n\(payloadString.prefix(1200))")

                if let extractedText = extractTextFromResponsesPayload(payloadAny) {
                    print("🤖 OpenAI extracted text (first 600) model=\(model):\n\(extractedText.prefix(600))")
                    if let parsed = parseStrictJSONFromString(extractedText) {
                        return mapSentiment(parsed)
                    }
                }

                // Fallback: try to find a JSON object anywhere
                if let extracted = extractFirstJSONObject(from: payloadString),
                   let parsed = parseStrictJSONFromString(extracted) {
                    return mapSentiment(parsed)
                }

                throw NSError(domain: "openai", code: 422, userInfo: [NSLocalizedDescriptionKey: "Could not parse sentiment JSON"])
            } catch {
                lastError = error
                print("❌ OpenAI model failed: \(model) error=\(error.localizedDescription)")
                continue
            }
        }

        throw lastError ?? NSError(domain: "openai", code: 500, userInfo: [NSLocalizedDescriptionKey: "Unknown OpenAI error"])
    }

    private static func extractTextFromResponsesPayload(_ any: Any) -> String? {
        guard let dict = any as? [String: Any] else { return nil }

        if let t = dict["output_text"] as? String, !t.isEmpty { return t }

        // Common shape: output: [ { content: [ { text: "..." } ] } ]
        if let output = dict["output"] as? [[String: Any]] {
            var chunks: [String] = []
            for o in output {
                if let content = o["content"] as? [[String: Any]] {
                    for c in content {
                        if let text = c["text"] as? String { chunks.append(text) }
                        else if let t = c["output_text"] as? String { chunks.append(t) }
                    }
                }
            }
            let joined = chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private static func mapSentiment(_ parsed: SentimentResponse) -> FeedManager.NewsSentiment {
        let levelRaw = parsed.level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let level: FeedManager.NewsSentiment.Level = {
            switch levelRaw {
            case "green": return .green
            case "amber": return .amber
            case "red": return .red
            default: return .amber
            }
        }()

        let summary = parsed.threeWordSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedManager.NewsSentiment(level: level, threeWordSummary: summary, computedAt: Date())
    }

    private static func parseStrictJSONFromString(_ s: String) -> SentimentResponse? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = extractFirstJSONObject(from: trimmed) ?? trimmed
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SentimentResponse.self, from: data)
    }

    private static func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: i)
                    return String(text[start..<end])
                }
            }
            i = text.index(after: i)
        }
        return nil
    }
}

// MARK: - RSS / Atom Parser
final class RSSParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var parser: XMLParser
    private let source: FeedSource
    private let type: TickerType
    private let topicName: String
    private let maxAgeDays: Int

    private var items: [TickerItem] = []

    private var currentTag: String = ""
    private var elementStack: [String] = []

    private var currentTitle: String = ""
    private var currentLink: String = ""
    private var currentDescription: String = ""
    private var currentContentEncoded: String = ""

    private var currentPublishedAt: Date?
    private var currentDateText: String = ""

    private var imageCandidates: [String] = []

    init(data: Data, source: FeedSource, type: TickerType, topicName: String, maxAgeDays: Int) {
        self.parser = XMLParser(data: data)
        self.source = source
        self.type = type
        self.topicName = topicName
        self.maxAgeDays = maxAgeDays
        super.init()
        self.parser.delegate = self
        self.parser.shouldProcessNamespaces = true
    }

    func parse() -> [TickerItem] {
        parser.parse()
        return items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        let tag = (qName ?? elementName)
        currentTag = tag
        elementStack.append(tag)

        if tag == "item" || tag == "entry" {
            currentTitle = ""
            currentLink = ""
            currentDescription = ""
            currentContentEncoded = ""
            currentPublishedAt = nil
            currentDateText = ""
            imageCandidates.removeAll()
        }

        let urlAttr = attributeDict["url"] ?? ""
        let hrefAttr = attributeDict["href"] ?? ""
        let typeAttr = (attributeDict["type"] ?? "").lowercased()
        let mediumAttr = (attributeDict["medium"] ?? "").lowercased()
        let relAttr = (attributeDict["rel"] ?? "").lowercased()

        if tag == "enclosure" {
            if !urlAttr.isEmpty && (typeAttr.contains("image") || mediumAttr == "image") {
                imageCandidates.append(urlAttr)
            }
        }

        if tag == "media:content" || tag == "media:thumbnail" || tag.hasSuffix(":content") || tag.hasSuffix(":thumbnail") {
            let candidate = !urlAttr.isEmpty ? urlAttr : hrefAttr
            if !candidate.isEmpty {
                if looksLikeImageURL(candidate) || typeAttr.contains("image") || mediumAttr == "image" || typeAttr.isEmpty {
                    imageCandidates.append(candidate)
                }
            }
        }

        if tag == "itunes:image" {
            if !hrefAttr.isEmpty {
                imageCandidates.append(hrefAttr)
            }
        }

        if tag == "link" || tag.hasSuffix(":link") {
            if !hrefAttr.isEmpty {
                if currentLink.isEmpty || relAttr == "alternate" {
                    currentLink = hrefAttr
                }
                if relAttr == "enclosure" && (typeAttr.contains("image") || looksLikeImageURL(hrefAttr)) {
                    imageCandidates.append(hrefAttr)
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }

        let tag = currentTag.lowercased()

        if tag == "title" {
            currentTitle += trimmed
        } else if tag == "link" {
            if currentLink.isEmpty {
                currentLink += trimmed
            }
        } else if tag == "description" || tag == "summary" {
            currentDescription += string
        } else if tag == "content:encoded" || tag == "encoded" {
            currentContentEncoded += string
        } else if tag == "pubdate" || tag == "published" || tag == "updated" || tag == "dc:date" || tag == "date" {
            currentDateText += string
        } else if tag == "url" {
            if elementStack.contains(where: { $0.lowercased().contains("image") || $0.lowercased().contains("thumbnail") || $0.lowercased().contains("media") }) {
                imageCandidates.append(trimmed)
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let tag = (qName ?? elementName)
        _ = elementStack.popLast()

        if tag == "item" || tag == "entry" {
            let cleanTitle = cleanText(currentTitle)
            guard !cleanTitle.isEmpty else { return }

            if currentPublishedAt == nil {
                currentPublishedAt = parseFeedDate(currentDateText)
            }

            if let pub = currentPublishedAt, pub < cutoffDate(daysAgo: maxAgeDays) {
                return
            }

            let linkToUse = currentLink.isEmpty ? "https://\(source.domain)" : currentLink
            let rawURL = URL(string: linkToUse) ?? URL(string: "https://\(source.domain)")!
            let finalURL = normalizedArticleURL(rawURL)

            var chosenImage: String? = bestImageCandidate(from: imageCandidates)
            if chosenImage == nil {
                chosenImage = extractFirstImageURL(fromHTML: currentContentEncoded) ??
                              extractFirstImageURL(fromHTML: currentDescription)
            }

            let mediaURL: URL? = {
                guard let s = chosenImage else { return nil }
                let normalized = normalizeURLString(s, baseDomain: source.domain)
                return URL(string: normalized)
            }()

            items.append(
                TickerItem(
                    text: cleanTitle,
                    type: type,
                    value: topicName,
                    score: nil,
                    sourceDomain: source.domain,
                    sourceName: source.name,
                    mediaURL: mediaURL,
                    isVideo: false,
                    articleURL: finalURL,
                    publishedAt: currentPublishedAt
                )
            )
        }
    }

    private func normalizedArticleURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let drop = Set([
            "utm_source","utm_medium","utm_campaign","utm_term","utm_content","utm_id","utm_name","utm_reader","utm_referrer",
            "ref","source","cmpid","mc_cid","mc_eid","ocid"
        ])
        if let q = comps.queryItems {
            comps.queryItems = q.filter { !drop.contains($0.name.lowercased()) }
        }
        return comps.url ?? url
    }

    private func cutoffDate(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())
            ?? Date().addingTimeInterval(TimeInterval(-daysAgo * 24 * 60 * 60))
    }

    private func cleanText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseFeedDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm Z"
        ]
        for f in formats {
            rfc822.dateFormat = f
            if let d = rfc822.date(from: s) { return d }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }

        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }

        return nil
    }

    private func bestImageCandidate(from candidates: [String]) -> String? {
        var seen = Set<String>()
        let unique = candidates.compactMap { c -> String? in
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if seen.contains(t) { return nil }
            seen.insert(t)
            return t
        }

        let imagey = unique.filter { looksLikeImageURL($0) }
        if let best = imagey.first(where: { $0.lowercased().hasPrefix("https://") }) { return best }
        if let best = imagey.first(where: { $0.lowercased().hasPrefix("http://") }) { return best }
        return imagey.first ?? unique.first
    }

    private func extractFirstImageURL(fromHTML html: String) -> String? {
        guard !html.isEmpty else { return nil }

        let patterns: [String] = [
            #"<img[^>]+(?:src|data-src|data-lazy-src|data-original)\s*=\s*["']([^"']+)["']"#,
            #"<img[^>]+srcset\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]+property\s*=\s*["']og:image["'][^>]+content\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]+name\s*=\s*["']twitter:image["'][^>]+content\s*=\s*["']([^"']+)["']"#
        ]

        for p in patterns {
            if let match = firstRegexGroup(in: html, pattern: p) {
                if p.contains("srcset") {
                    let first = match.split(separator: ",").first?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: " ").first
                        .map(String.init)
                    if let first, !first.isEmpty { return first }
                } else {
                    return match
                }
            }
        }

        if let url = firstRegexGroup(
            in: html,
            pattern: #"(https?:\/\/[^\s"'<>]+?\.(?:jpg|jpeg|png|webp|gif))(?:\?[^\s"'<>]*)?"#
        ) {
            return url
        }

        return nil
    }

    private func firstRegexGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    private func normalizeURLString(_ raw: String, baseDomain: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "&amp;", with: "&")

        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("/") { s = "https://\(baseDomain)" + s }
        return s
    }

    private func looksLikeImageURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png") || lower.contains(".webp") || lower.contains(".gif") {
            return true
        }
        if lower.contains("image") && (lower.contains("cdn") || lower.contains("img")) {
            return true
        }
        return false
    }
}

// MARK: - Staleness helper (kept here to avoid touching Models.swift again)
private extension TickerItem {
    func isStale(maxDays: Int) -> Bool {
        guard let d = publishedAt else { return false } // if no date, keep
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxDays, to: Date())
            ?? Date().addingTimeInterval(TimeInterval(-maxDays * 24 * 60 * 60))
        return d < cutoff
    }
}
