import Foundation
import SwiftUI
import Combine
import AppKit

// MARK: - Debug Logging Helper
enum LogLevel: String {
    case info = "INFO", warn = "WARN", error = "ERROR"
}

@inline(__always)
func dbg(_ message: String, level: LogLevel = .info, file: String = #file, line: Int = #line) {
    #if DEBUG
    let fileName = (file as NSString).lastPathComponent
    print("FEEDBAR [\(level.rawValue)] \(fileName):\(line) – \(message)")
    #endif
}

// MARK: - Network Sessions
enum NetworkSessions {
    static let icon: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.waitsForConnectivity = false
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.urlCache = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    static let media: URLSession = {
        let c = URLSessionConfiguration.ephemeral
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
    // Explicitly nonisolated to allow use in background parsing
    nonisolated var decodedHTML: String {
        guard let data = self.data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string) ?? self
    }
}

// MARK: - Thread-Safe Image Cache
final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.countLimit = 500 }

    func get(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func set(_ image: NSImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

// MARK: - Brand Icon Strategy
enum BrandIconProvider {
    // ✅ FIXED: Marked all as nonisolated for background thread use
    nonisolated static func normalizedDomain(_ raw: String) -> String {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        d = d.replacingOccurrences(of: "https://", with: "")
        d = d.replacingOccurrences(of: "http://", with: "")
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        if d.hasPrefix("www.") { d = String(d.dropFirst(4)) }
        return d
    }

    nonisolated static func isLikelyDomain(_ d: String) -> Bool {
        guard !d.isEmpty, d.contains("."), d.count >= 4 else { return false }
        return true
    }

    nonisolated static func primaryURL(domain: String) -> URL? {
        let d = normalizedDomain(domain)
        guard isLikelyDomain(d) else { return nil }
        return URL(string: "https://logo.clearbit.com/\(d)?size=128")
    }

    nonisolated static func fallbackURL(domain: String) -> URL? {
        let d = normalizedDomain(domain)
        guard isLikelyDomain(d) else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(d).ico")
    }

    nonisolated static func cacheKey(domain: String) -> String { "brandicon:\(normalizedDomain(domain))" }
}

// MARK: - Google Favicon Strategy
enum GoogleFaviconProvider {
    // ✅ FIXED: Marked all as nonisolated for background thread use
    nonisolated static func normalizedDomain(_ raw: String) -> String {
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

    nonisolated static func url(domain raw: String, size: Int = 128) -> URL? {
        let d = normalizedDomain(raw)
        guard !d.isEmpty, d.contains(".") else { return nil }
        return URL(string: "https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://\(d)&size=\(size)")
    }

    nonisolated static func cacheKey(domain raw: String, size: Int = 128) -> String {
        return "googlefavicon:\(normalizedDomain(raw)):\(size)"
    }
}

// MARK: - Shared Favicon Store
// Drives UI components, so it remains MainActor isolated
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()
    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight = Set<String>()
    private var cancellables: [String: AnyCancellable] = [:]

    private init() {}
    
    func inject(image: NSImage, for domain: String) {
        let key = GoogleFaviconProvider.cacheKey(domain: domain)
        self.images[key] = image
        ImageMemoryCache.shared.set(image, for: key)
    }

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
        if images[key] != nil || inFlight.contains(key) { return }
        if let cached = ImageMemoryCache.shared.get(key) {
            images[key] = cached
            return
        }

        guard let url = GoogleFaviconProvider.url(domain: domain, size: size) else { return }
        inFlight.insert(key)

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.addValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        cancellables[key] = NetworkSessions.icon.dataTaskPublisher(for: request)
            .map { (data, _) -> NSImage? in NSImage(data: data) }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] img in
                guard let self else { return }
                self.inFlight.remove(key)
                if let img {
                    self.images[key] = img
                    ImageMemoryCache.shared.set(img, for: key)
                }
                self.cancellables[key] = nil
            }
    }
}
