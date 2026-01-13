import Foundation
import SwiftUI
import Combine
import AppKit

// MARK: - Debug Logging Helper (global)

enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
func dbg(_ message: String,
         level: LogLevel = .info,
         file: String = #file,
         line: Int = #line) {
    #if DEBUG
    let fileName = (file as NSString).lastPathComponent
    print("FEEDBAR [\(level.rawValue)] \(fileName):\(line) – \(message)")
    #endif
}

// MARK: - Network Sessions (tuned for 4000+ item loads)
enum NetworkSessions {
    /// For tiny icon assets (favicons).
    static let icon: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // Increased from 4 to 8 to reduce "Operation timed out" on slow CDNs
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.waitsForConnectivity = false
        c.requestCachePolicy = .returnCacheDataElseLoad
        // Increased memory capacity to reduce disk thrashing
        c.urlCache = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    /// For media thumbnails and OG HTML fetch.
    static let media: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // Increased from 6 to 12.
        // When fetching 100+ images, 6s is too strict and causes "Socket not connected" errors.
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.urlCache = URLCache(memoryCapacity: 100 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()
}

// MARK: - HTML Decoder
extension String {
    var decodedHTML: String {
        guard let data = self.data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string) ?? self
    }
}

// MARK: - Simple in-memory image cache
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.countLimit = 500 }

    func get(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func set(_ image: NSImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

// MARK: - Brand icon URL strategy
enum BrandIconProvider {
    static func normalizedDomain(_ raw: String) -> String {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        d = d.replacingOccurrences(of: "https://", with: "")
        d = d.replacingOccurrences(of: "http://", with: "")
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        if d.hasPrefix("www.") { d = String(d.dropFirst(4)) }
        return d
    }

    static func isLikelyDomain(_ d: String) -> Bool {
        guard !d.isEmpty else { return false }
        guard d.contains(".") else { return false }
        guard d.count >= 4 else { return false }
        return true
    }

    static func primaryURL(domain: String) -> URL? {
        let d = normalizedDomain(domain)
        guard isLikelyDomain(d) else { return nil }
        return URL(string: "https://logo.clearbit.com/\(d)?size=128")
    }

    static func fallbackURL(domain: String) -> URL? {
        let d = normalizedDomain(domain)
        guard isLikelyDomain(d) else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(d).ico")
    }

    static func cacheKey(domain: String) -> String { "brandicon:\(normalizedDomain(domain))" }
}

// MARK: - BrandIconLoader
final class BrandIconLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var hasFailed: Bool = false

    private var cancellable: AnyCancellable?
    private var currentDomainKey: String?

    func load(domain: String) {
        let key = BrandIconProvider.cacheKey(domain: domain)
        currentDomainKey = key
        hasFailed = false

        if let cached = ImageMemoryCache.shared.get(key) {
            self.image = cached
            return
        }

        guard
            let primary = BrandIconProvider.primaryURL(domain: domain),
            let fallback = BrandIconProvider.fallbackURL(domain: domain)
        else {
            self.image = nil
            self.hasFailed = true
            return
        }

        cancellable?.cancel()
        image = nil

        cancellable = fetchImage(url: primary)
            .flatMap { [weak self] img -> AnyPublisher<NSImage?, Never> in
                if img != nil { return Just(img).eraseToAnyPublisher() }
                return self?.fetchImage(url: fallback) ?? Just(nil).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] img in
                guard let self else { return }
                guard self.currentDomainKey == key else { return }

                if let img {
                    self.image = img
                    self.hasFailed = false
                    ImageMemoryCache.shared.set(img, for: key)
                } else {
                    self.image = nil
                    self.hasFailed = true
                }
            }
    }

    func cancel() {
        cancellable?.cancel()
        cancellable = nil
    }

    private func fetchImage(url: URL) -> AnyPublisher<NSImage?, Never> {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6 // Relaxed from 3
        request.cachePolicy = .returnCacheDataElseLoad
        request.addValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        return NetworkSessions.icon.dataTaskPublisher(for: request)
            .map { (data, response) -> NSImage? in
                return NSImage(data: data)
            }
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }
}

// MARK: - Google favicon URL strategy
enum GoogleFaviconProvider {
    static func normalizedDomain(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "" }

        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            if let url = URL(string: s), let host = url.host { s = host }
        } else {
            if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        }

        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func isLikelyDomain(_ d: String) -> Bool {
        guard !d.isEmpty else { return false }
        guard d.contains(".") else { return false }
        guard d.count >= 4 else { return false }
        return true
    }

    static func url(domain raw: String, size: Int = 128) -> URL? {
        let d = normalizedDomain(raw)
        guard isLikelyDomain(d) else { return nil }
        return URL(string: "https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://\(d)&size=\(size)")
    }

    static func cacheKey(domain raw: String, size: Int = 128) -> String {
        let d = normalizedDomain(raw)
        return "googlefavicon:\(d):\(size)"
    }
}

// MARK: - Shared favicon store
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    @Published private(set) var images: [String: NSImage] = [:]

    private var inFlight = Set<String>()
    private var cancellables: [String: AnyCancellable] = [:]

    private init() {}

    func image(for domain: String, size: Int = 128) -> NSImage? {
        let key = GoogleFaviconProvider.cacheKey(domain: domain, size: size)
        if let img = images[key] { return img }
        if let cached = ImageMemoryCache.shared.get(key) {
            images[key] = cached
            return cached
        }
        return nil
    }

    func load(domain: String, size: Int = 128) {
        let key = GoogleFaviconProvider.cacheKey(domain: domain, size: size)

        if images[key] != nil { return }
        if let cached = ImageMemoryCache.shared.get(key) {
            images[key] = cached
            return
        }

        if inFlight.contains(key) { return }
        inFlight.insert(key)

        guard let url = GoogleFaviconProvider.url(domain: domain, size: size) else {
            inFlight.remove(key)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8 // Relaxed from 4
        request.cachePolicy = .returnCacheDataElseLoad
        request.addValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let pub = NetworkSessions.icon.dataTaskPublisher(for: request)
            .map { (data, response) -> NSImage? in
                guard let img = NSImage(data: data) else { return nil }
                // Reject low-res fallback globes if we asked for high-res
                if size > 32 {
                    if let rep = img.representations.first, rep.pixelsWide <= 16 {
                        return nil
                    }
                }
                return img
            }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)

        cancellables[key] = pub.sink { [weak self] img in
            guard let self else { return }
            self.inFlight.remove(key)
            self.cancellables[key] = nil
            
            guard let img else { return }
            self.images[key] = img
            ImageMemoryCache.shared.set(img, for: key)
        }
    }

    func prewarm(domains: [String], size: Int = 128) {
        for d in domains { load(domain: d, size: size) }
    }
}

// MARK: - RemoteImage
final class ImageLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var hasFailed = false
    private var cancellable: AnyCancellable?

    func load(url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12 // Relaxed from 6
        request.cachePolicy = .returnCacheDataElseLoad
        request.addValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        cancellable = NetworkSessions.media.dataTaskPublisher(for: request)
            .map { (data, response) -> NSImage? in
                return NSImage(data: data)
            }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loadedImage in
                self?.image = loadedImage
                if loadedImage == nil { self?.hasFailed = true }
            }
    }

    func cancel() { cancellable?.cancel() }
}

struct RemoteImage: View {
    @StateObject private var loader = ImageLoader()
    let url: URL?

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if loader.hasFailed {
                EmptyView()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .onAppear {
            if let validURL = url { loader.load(url: validURL) }
            else { loader.hasFailed = true }
        }
        .onDisappear { loader.cancel() }
    }
}

// MARK: - OG Image Enrichment
final class OGImageEnricher {
    private let session: URLSession = NetworkSessions.media
    private let queue = DispatchQueue(label: "ogimage.enricher.queue")

    private var inFlight = Set<String>()
    private var cache = [String: URL]()

    private let maxInFlight = 6

    func enqueue(item: TickerItem, onUpdate: @escaping (TickerItem) -> Void) {
        let key = item.articleURL.absoluteString

        queue.async {
            if let cached = self.cache[key] {
                let updated = TickerItem(
                    text: item.text,
                    type: item.type,
                    value: item.value,
                    score: item.score,
                    sourceDomain: item.sourceDomain,
                    sourceName: item.sourceName,
                    mediaURL: cached,
                    isVideo: item.isVideo,
                    articleURL: item.articleURL,
                    publishedAt: item.publishedAt
                )
                DispatchQueue.main.async { onUpdate(updated) }
                return
            }

            if self.inFlight.contains(key) { return }
            if self.inFlight.count >= self.maxInFlight { return }
            self.inFlight.insert(key)

            Task {
                defer { self.queue.async { self.inFlight.remove(key) } }

                guard let img = await self.fetchOGImage(from: item.articleURL) else { return }
                self.queue.async { self.cache[key] = img }

                let updated = TickerItem(
                    text: item.text,
                    type: item.type,
                    value: item.value,
                    score: item.score,
                    sourceDomain: item.sourceDomain,
                    sourceName: item.sourceName,
                    mediaURL: img,
                    isVideo: item.isVideo,
                    articleURL: item.articleURL,
                    publishedAt: item.publishedAt
                )
                DispatchQueue.main.async { onUpdate(updated) }
            }
        }
    }

    private func fetchOGImage(from url: URL) async -> URL? {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12 // Relaxed from 6
            req.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            req.setValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )

            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            guard let html = String(data: data, encoding: .utf8) else { return nil }

            if let s = firstMetaContent(html, property: "og:image") ?? firstMetaContent(html, name: "twitter:image") {
                let normalized = normalizeImageURL(s, base: url)
                return URL(string: normalized)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func firstMetaContent(_ html: String, property: String? = nil, name: String? = nil) -> String? {
        let pattern: String
        if let property {
            pattern = #"<meta[^>]+property\s*=\s*["']\#(property)["'][^>]+content\s*=\s*["']([^"']+)["']"#
        } else if let name {
            pattern = #"<meta[^>]+name\s*=\s*["']\#(name)["'][^>]+content\s*=\s*["']([^"']+)["']"#
        } else {
            return nil
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html)
        else { return nil }

        return String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
    }

    private func normalizeImageURL(_ raw: String, base: URL) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("/") {
            let host = base.host ?? ""
            s = "https://\(host)" + s
        }
        return s
    }
}
