//
//  TickerView.swift
//  SuperTicker
//

import SwiftUI
import Combine
import QuartzCore

// MARK: - PREFERENCE KEY FOR ROW WIDTHS
struct RowWidthKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Domain Sanitizer (local replacement for DomainNormalizer)
enum DomainSanitizer {
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "" }

        // If it looks like a full URL, extract host
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            if let url = URL(string: s), let host = url.host {
                s = host
            }
        } else {
            // Strip any accidental path fragment
            if let slash = s.firstIndex(of: "/") {
                s = String(s[..<slash])
            }
        }

        // Remove www.
        if s.hasPrefix("www.") { s.removeFirst(4) }

        // Remove trailing dot(s)
        while s.hasSuffix(".") { s.removeLast() }

        return s
    }
}

// MARK: - SCROLL MANAGER (captures scroll wheel only while hovering)
final class ScrollManager: ObservableObject {
    @Published var isHovering = false
    private var monitor: Any?
    var onScroll: ((CGFloat) -> Void)?

    func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, self.isHovering else { return event }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let delta = abs(dx) > abs(dy) ? dx : dy

            self.onScroll?(delta)
            return nil
        }
    }

    func stopMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

// MARK: - ENGINE
@MainActor
final class TickerEngine: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var visibleItems: [TickerItem] = []

    private var spacing: CGFloat = 60
    private var bufferSize: Int = 15
    private var allItems: [TickerItem] = []
    private var nextSourceIndex: Int = 0
    private var itemWidths: [UUID: CGFloat] = [:]
    private var timer: AnyCancellable?
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var paused: Bool = false
    private var speed: Double = 1.0

    func configure(items: [TickerItem], bufferSize: Int, spacing: CGFloat, speed: Double) {
        // Exclude weather items from the scrolling text so they don't duplicate the pinned weather segment
        self.allItems = items.filter { !$0.sourceDomain.lowercased().contains("meteo.com") }

        self.bufferSize = bufferSize
        self.spacing = spacing
        self.speed = speed

        self.itemWidths.removeAll()
        self.visibleItems.removeAll()
        self.offset = 0
        self.nextSourceIndex = 0
        self.lastTime = CACurrentMediaTime()

        guard !self.allItems.isEmpty else { return }

        let seedCount = min(bufferSize, self.allItems.count)
        for _ in 0..<seedCount { appendNextItem() }
    }

    func setSpeed(_ speed: Double) { self.speed = speed }
    func setPaused(_ paused: Bool) { self.paused = paused }

    func start() {
        stop()
        lastTime = CACurrentMediaTime()
        timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.step() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func updateWidthsOnce(_ widths: [UUID: CGFloat]) {
        for (id, w) in widths where itemWidths[id] == nil && w > 0 {
            itemWidths[id] = w
        }
    }

    func manualScroll(delta: CGFloat) {
        offset += delta
        recycleIfNeeded()
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        lastTime = now

        guard dt > 0, dt < 0.1 else { return }
        guard !paused else { return }
        guard !visibleItems.isEmpty else { return }

        let moveDist = CGFloat(dt * 60.0 * speed)
        offset -= moveDist
        recycleIfNeeded()
    }

    private func recycleIfNeeded() {
        guard !visibleItems.isEmpty else { return }

        while let first = visibleItems.first, let w = itemWidths[first.id] {
            let threshold = -(w + spacing)
            if offset < threshold {
                visibleItems.removeFirst()
                offset += (w + spacing)
                appendNextItem()
            } else {
                break
            }
        }
    }

    private func appendNextItem() {
        guard !allItems.isEmpty else { return }
        let item = allItems[nextSourceIndex % allItems.count]
        visibleItems.append(item)
        nextSourceIndex += 1
    }
}

// MARK: - MAIN VIEW
struct TickerView: View {
    @ObservedObject var feedManager: FeedManager
    @ObservedObject var coordinator: AppCoordinator
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0

    private let spacing: CGFloat = 60
    private let bufferSize: Int = 15
    private let wheelMultiplier: CGFloat = 1.5

    @StateObject private var engine = TickerEngine()
    @StateObject private var scrollManager = ScrollManager()

    @State private var isDragging = false
    @State private var isWheeling = false
    @State private var cursorPushed = false
    @State private var lastDragTranslation: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            FeedsTheme.background.ignoresSafeArea()

            HStack(spacing: spacing) {
                ForEach(engine.visibleItems) { item in
                    TickerRow(item: item, size: coordinator.tickerSize)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: RowWidthKey.self,
                                    value: [item.id: proxy.size.width]
                                )
                            }
                        )
                }
            }
            .offset(x: engine.offset)
            .onPreferenceChange(RowWidthKey.self) { widths in
                engine.updateWidthsOnce(widths)
            }

            .contentShape(Rectangle())
            .onHover { hovering in
                scrollManager.isHovering = hovering

                if hovering && !cursorPushed { NSCursor.pointingHand.push(); cursorPushed = true }
                if !hovering && cursorPushed { NSCursor.pop(); cursorPushed = false }

                engine.setPaused(hovering || isDragging || isWheeling)
            }
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { val in
                        if !isDragging {
                            isDragging = true
                            lastDragTranslation = 0
                            engine.setPaused(true)
                        }
                        let delta = val.translation.width - lastDragTranslation
                        lastDragTranslation = val.translation.width
                        engine.manualScroll(delta: delta)
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastDragTranslation = 0
                        engine.setPaused(scrollManager.isHovering || isWheeling)
                    }
            )

            // Pass the dynamic ticker size to the fixed block so it scales correctly
            FixedBrandBlock(coordinator: coordinator, feedManager: feedManager, size: coordinator.tickerSize)
        }
        .frame(height: heightForSize(coordinator.tickerSize))
        .onAppear {
            engine.configure(items: feedManager.items,
                             bufferSize: bufferSize,
                             spacing: spacing,
                             speed: scrollSpeed)
            engine.start()

            scrollManager.onScroll = { rawDelta in
                isWheeling = true
                engine.setPaused(true)

                engine.manualScroll(delta: rawDelta * wheelMultiplier)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isWheeling = false
                    engine.setPaused(scrollManager.isHovering || isDragging)
                }
            }
            scrollManager.startMonitor()
        }
        .onDisappear {
            engine.stop()
            scrollManager.stopMonitor()
        }
        .onChange(of: scrollSpeed) { newSpeed in engine.setSpeed(newSpeed) }

        // ✅ IMPORTANT FIX:
        // The feed can change without changing `items.count` (e.g. trends replace items 1:1).
        // Use FeedManager.itemsRevision to force a reconfigure.
        .onChange(of: feedManager.itemsRevision) { _ in
            engine.configure(items: feedManager.items,
                             bufferSize: bufferSize,
                             spacing: spacing,
                             speed: scrollSpeed)
        }

        // Keep this as a harmless extra safety net
        .onChange(of: feedManager.items.count) { _ in
            engine.configure(items: feedManager.items,
                             bufferSize: bufferSize,
                             spacing: spacing,
                             speed: scrollSpeed)
        }

        .contextMenu {
            Button("Settings...") { coordinator.openSettings() }
            Divider()
            Button("Quit SuperTicker") { NSApp.terminate(nil) }
        }
    }

    private func heightForSize(_ size: Int) -> CGFloat {
        size == 1 ? 48 : (size == 4 ? 108 : 72)
    }
}

// MARK: - ROW
struct TickerRow: View {
    let item: TickerItem
    let size: Int
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            TickerIconView(item: item, size: size)

            if let mediaURL = item.mediaURL {
                AsyncImage(url: mediaURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.05)
                    }
                }
                .frame(width: mediaWidth(size), height: mediaHeight(size))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // ✅ show date in eyebrow label
                    Text(item.signalLabelWithDate)
                        .font(.system(size: labelFontSize(size), weight: .black, design: .monospaced))
                        .foregroundColor(item.accentColor)

                    // Leave score pill alone (as requested)
                    if let score = item.score {
                        Text(score)
                            .font(.system(size: labelFontSize(size) - 1, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.9))
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.text)
                        .font(.system(size: mainFontSize(size), weight: .medium))
                        .foregroundColor(FeedsTheme.primaryText)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(item.sourceDomain.lowercased())
                        .font(.system(size: mainFontSize(size) - 2, weight: .semibold, design: .monospaced))
                        .foregroundColor(FeedsTheme.secondaryText)
                        .opacity(0.7)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
        )
        .fixedSize()
        .onHover { isHovered = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.articleURL) }
    }

    private func mediaWidth(_ size: Int) -> CGFloat { size == 1 ? 38 : (size == 4 ? 90 : 60) }
    private func mediaHeight(_ size: Int) -> CGFloat { size == 1 ? 24 : (size == 4 ? 60 : 40) }
    private func mainFontSize(_ size: Int) -> CGFloat { size == 1 ? 15 : (size == 4 ? 30 : 22) }
    private func labelFontSize(_ size: Int) -> CGFloat { size == 1 ? 9 : (size == 4 ? 14 : 11) }
}

// MARK: - ICON VIEW (Favicons + SF Symbol Fallbacks, NO GLOBE)
struct TickerIconView: View {
    let item: TickerItem
    let size: Int

    var body: some View {
        if shouldSkipNetworkFavicon(item) {
            fallbackBadge(symbol: fallbackSymbol(for: item))
        } else {
            AsyncImage(url: faviconURL(for: item)) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .grayscale(1.0)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(Circle())
                } else {
                    fallbackBadge(symbol: fallbackSymbol(for: item))
                }
            }
            .frame(width: iconSize, height: iconSize)
        }
    }

    private var iconSize: CGFloat {
        size == 1 ? 22 : (size == 4 ? 48 : 34)
    }

    private func faviconURL(for item: TickerItem) -> URL? {
        let d = DomainSanitizer.normalize(item.sourceDomain)
        guard !d.isEmpty else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(d)&sz=64")
    }

    private func shouldSkipNetworkFavicon(_ item: TickerItem) -> Bool {
        let d = DomainSanitizer.normalize(item.sourceDomain)

        // Keep using the *stable* label (without date) for logic.
        let label = item.signalLabel.lowercased()

        if label.contains("topic") || label.contains("trend") || label.contains("future") { return true }
        if d.isEmpty || !d.contains(".") { return true }
        if d == "news" || d == "topic" || d == "topics" { return true }
        if d.contains("meteo") { return true }

        return false
    }

    private func fallbackSymbol(for item: TickerItem) -> String {
        let d = DomainSanitizer.normalize(item.sourceDomain)
        let label = item.signalLabel.lowercased()

        if label.contains("topic") { return "magnifyingglass" }
        if label.contains("trend") { return "chart.line.uptrend.xyaxis" }
        if label.contains("future") { return "sparkles" }

        if d.contains("youtube") || d.contains("video") || d.contains("tv") { return "play.tv" }
        if d.contains("github") || d.contains("gitlab") || d.contains("code") { return "terminal" }
        if d.contains("podcast") { return "mic" }
        if d.contains("finance") || d.contains("market") || d.contains("stocks") { return "chart.xyaxis.line" }
        if d.contains("weather") || d.contains("meteo") { return "cloud.sun" }
        if d.contains("sport") { return "sportscourt" }

        return "newspaper"
    }

    private func fallbackBadge(symbol: String) -> some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: iconSize * 0.55, weight: .semibold))
            .foregroundColor(item.accentColor)
            .frame(width: iconSize, height: iconSize)
            .background(Color.white.opacity(0.10))
            .clipShape(Circle())
    }
}

// MARK: - FIXED BRAND BLOCK
struct FixedBrandBlock: View {
    let coordinator: AppCoordinator
    @ObservedObject var feedManager: FeedManager
    let size: Int

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                FeedsTheme.background.frame(width: blockWidth(size))

                HStack(spacing: 12) {
                    Button(action: { coordinator.openSettings() }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(FeedsTheme.secondaryText.opacity(0.5))
                            .font(.system(size: settingsIconSize(size)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 15)

                    // ✅ Weather first
                    WeatherSegment(feedManager: feedManager, size: size)

                    // ✅ Sentiment to the RIGHT of weather
                    NewsSentimentOrb(feedManager: feedManager, size: size)
                }
            }

            LinearGradient(
                gradient: Gradient(colors: [FeedsTheme.background, .clear]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 40)
        }
        .allowsHitTesting(true)
        .zIndex(10)
    }

    private func blockWidth(_ size: Int) -> CGFloat { size == 1 ? 210 : (size == 4 ? 360 : 270) } // a bit wider for stacked words
    private func settingsIconSize(_ size: Int) -> CGFloat { size == 1 ? 14 : (size == 4 ? 24 : 18) }
}

// MARK: - NEWS SENTIMENT ORB
struct NewsSentimentOrb: View {
    @ObservedObject var feedManager: FeedManager
    let size: Int

    @State private var hovered = false
    @State private var pulse = false

    var body: some View {
        Button {
            // Force a refresh (it will still no-op if no "today" news)
            feedManager.refreshNewsSentimentAfterRender(delaySeconds: 0.2)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    // Outer glow
                    Circle()
                        .fill(orbCoreColor.opacity(0.25))
                        .frame(width: orbSize * 1.25, height: orbSize * 1.25)
                        .blur(radius: hovered ? 8 : 6)
                        .opacity(hovered ? 1.0 : 0.85)

                    // Animated “computing” ring
                    if feedManager.isComputingSentiment {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.55), lineWidth: ringWidth)
                            .frame(width: orbSize * 1.15, height: orbSize * 1.15)
                            .scaleEffect(pulse ? 1.08 : 0.92)
                            .opacity(pulse ? 0.9 : 0.35)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    }

                    // Core orb
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0.55),
                                    orbCoreColor.opacity(0.95)
                                ]),
                                center: .topLeading,
                                startRadius: 2,
                                endRadius: orbSize * 0.7
                            )
                        )
                        .frame(width: orbSize, height: orbSize)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: orbCoreColor.opacity(0.35), radius: hovered ? 10 : 7, x: 0, y: 0)

                    // Tiny spec highlight
                    Circle()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: orbSize * 0.18, height: orbSize * 0.18)
                        .offset(x: -orbSize * 0.18, y: -orbSize * 0.18)
                        .blur(radius: 0.2)
                }

                // ✅ 3 words stacked vertically (sizes 2 & 4)
                if size != 1, let s = feedManager.newsSentiment?.threeWordSummary {
                    let words = s.split(separator: " ").map(String.init)
                    VStack(alignment: .leading, spacing: -1) {
                        ForEach(words.prefix(3), id: \.self) { w in
                            Text(w.uppercased())
                                .font(.system(size: summaryFontSize, weight: .black, design: .monospaced))
                                .foregroundColor(FeedsTheme.utility.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                    .fixedSize()
                    .opacity(hovered ? 1.0 : 0.88)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in hovered = hovering }
        .onAppear {
            if feedManager.isComputingSentiment { pulse = true }
        }
        .onChange(of: feedManager.isComputingSentiment) { computing in
            pulse = computing
        }
    }

    private var orbSize: CGFloat {
        size == 1 ? 12 : (size == 4 ? 22 : 16)
    }

    private var ringWidth: CGFloat {
        size == 1 ? 1.2 : (size == 4 ? 2.0 : 1.6)
    }

    private var summaryFontSize: CGFloat {
        size == 4 ? 12 : 9
    }

    private var orbCoreColor: Color {
        guard let level = feedManager.newsSentiment?.level else {
            return Color.white.opacity(0.35)
        }
        switch level {
        case .green: return Color.green
        case .amber: return Color.orange
        case .red: return Color.red
        }
    }

    private var helpText: String {
        if feedManager.isComputingSentiment {
            return "Computing today's news sentiment…"
        }
        if let s = feedManager.newsSentiment?.threeWordSummary {
            return "News mood: \(s). Click to refresh."
        }
        return "News mood: not computed yet. Click to compute."
    }
}

// MARK: - WEATHER SEGMENT (Live)
struct WeatherSegment: View {
    @ObservedObject var feedManager: FeedManager
    let size: Int
    @AppStorage("weatherCity") private var city = "Dublin"

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.orange).frame(width: dotSize(size), height: dotSize(size))
            VStack(alignment: .leading, spacing: -2) {
                Text(city.uppercased())
                    .font(.system(size: cityLabelSize(size), weight: .black))
                    .foregroundColor(FeedsTheme.utility)

                Text(feedManager.currentWeatherTemp ?? "--°C")
                    .font(.system(size: tempValueSize(size), weight: .bold))
                    .foregroundColor(.white)
            }
            .fixedSize()
        }
    }

    private func dotSize(_ size: Int) -> CGFloat { size == 1 ? 4 : (size == 4 ? 8 : 6) }
    private func cityLabelSize(_ size: Int) -> CGFloat { size == 1 ? 7 : (size == 4 ? 12 : 9) }
    private func tempValueSize(_ size: Int) -> CGFloat { size == 1 ? 13 : (size == 4 ? 26 : 18) }
}

extension FeedManager {
    var currentWeatherTemp: String? {
        let weatherItem = items.first { item in
            let label = item.signalLabel.lowercased()
            let domain = item.sourceDomain.lowercased()

            return label.contains("weather") || label.contains("meteo") || label.contains("forecast") ||
            domain.contains("weather") || domain.contains("meteo") || domain.contains("forecast")
        }

        guard let item = weatherItem else { return nil }

        if let score = item.score, !score.isEmpty {
            return score
        }

        if item.text.contains("°") {
            let words = item.text.components(separatedBy: .whitespaces)
            if let tempString = words.first(where: { $0.contains("°") }) {
                return tempString
            }
        }

        return nil
    }
}

