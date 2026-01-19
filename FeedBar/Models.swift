import Foundation
import SwiftUI

// MARK: - 1. SENTIMENT MODEL
struct NewsSentiment: Codable {
    enum Level: String, Codable {
        case green, amber, red
    }
    let level: Level
    let threeWordSummary: String
    let computedAt: Date
}

// MARK: - 2. FEEDS BRAND KIT
struct FeedsTheme {
    static let background = Color(hex: "0E0F11")
    static let primaryText = Color(hex: "F4F5F7")
    static let secondaryText = Color(hex: "8A8F98")
    static let divider = Color(hex: "1A1C1F")

    static let news = Color(hex: "5E6B8A")
    static let futurism = Color(hex: "7A6FF0")
    static let ai = Color(hex: "4C7DFF")
    static let trends = Color(hex: "4FA3A5")
    static let utility = Color(hex: "C9A24D")

    static func categoryColor(for category: String) -> Color {
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if c.contains("AI") || c.contains("RESEARCH") { return FeedsTheme.ai }
        if c.contains("TECH") || c.contains("PROGRAMMING") { return FeedsTheme.futurism }
        if c.contains("BUSINESS") || c.contains("FINANCE") || c.contains("MARKET") { return FeedsTheme.trends }
        if c.contains("WEATHER") || c.contains("UTILITY") { return FeedsTheme.utility }
        return FeedsTheme.news
    }
}

// MARK: - 3. CUSTOM FEED MODELS (Missing Types Restored)
struct CustomFeed: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let url: String
    let category: String?
    let domain: String
    
    init(id: UUID = UUID(), name: String, url: String, category: String? = nil, domain: String) {
        self.id = id
        self.name = name
        self.url = url
        self.category = category
        self.domain = domain
    }
}

struct CustomFeedStorage: RawRepresentable {
    var feeds: [CustomFeed]
    public init(feeds: [CustomFeed]) { self.feeds = feeds }
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([CustomFeed].self, from: data)
        else { return nil }
        self.feeds = result
    }
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(feeds),
              let result = String(data: data, encoding: .utf8)
        else { return "[]" }
        return result
    }
}

struct FeedSource: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let url: String
    let domain: String
    let defaultEnabled: Bool
    let category: String?
    let icon_url: String? // 👈 ADDED: To capture the server icon
    
    enum CodingKeys: String, CodingKey {
        case id, name, url, domain, category
        case defaultEnabled = "default_enabled"
        case icon_url // 👈 ADDED: To map the JSON key
    }
    
    // Using ID prevents collisions between sources with same domain
    var settingKey: String { "source_\(id.uuidString)" }
}

// MARK: - 5. TICKER ITEM MODEL
struct TickerItem: Identifiable, Hashable, Equatable, Codable {
    var id = UUID()
    let text: String
    let type: TickerType
    let value: String?
    let score: String?
    let sourceDomain: String
    let sourceName: String
    let sourceIcon: URL?
    let mediaURL: URL?
    let isVideo: Bool
    let articleURL: URL
    let publishedAt: Date?
    // Helper for the UI to show "CATEGORY • 10:00 AM"
        var signalLabelWithDate: String {
            let label = value?.uppercased() ?? "NEWS"
            guard let date = publishedAt else { return label }
            
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a" // e.g. "10:00 AM"
            let timeStr = formatter.string(from: date)
            
            return "\(label) • \(timeStr)"
        }
    // Manual Initializer
    init(text: String, type: TickerType, value: String?, score: String?, sourceDomain: String, sourceName: String, sourceIcon: URL?, mediaURL: URL?, isVideo: Bool, articleURL: URL, publishedAt: Date?) {
        self.id = UUID()
        self.text = text
        self.type = type
        self.value = value
        self.score = score
        self.sourceDomain = sourceDomain
        self.sourceName = sourceName
        self.sourceIcon = sourceIcon
        self.mediaURL = mediaURL
        self.isVideo = isVideo
        self.articleURL = articleURL
        self.publishedAt = publishedAt
    }

    // Decoding Bridge (For Supabase/Netlify JSON)
        enum CodingKeys: String, CodingKey {
            case text = "title"
            case value = "category"
            case mediaURL = "image_url"
            case articleURL = "url"
            case publishedAt = "published_at"
            case sourceName = "source_name"
            case sourceDomain = "source_domain"
            case sourceIcon = "source_icon"
            case type, score, isVideo
        }

    // Aggressive Data Scrubbing Initializer
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            // 1. Clean Text Fields (Fixes layout breaking newlines)
            let rawText = try container.decode(String.self, forKey: .text)
            self.text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let rawName = try container.decode(String.self, forKey: .sourceName)
            self.sourceName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let rawDomain = try container.decode(String.self, forKey: .sourceDomain)
            self.sourceDomain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let rawValue = try container.decodeIfPresent(String.self, forKey: .value) {
                self.value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                self.value = nil
            }
            
            if let rawScore = try container.decodeIfPresent(String.self, forKey: .score) {
                self.score = rawScore.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                self.score = nil
            }

            // 2. Clean URLs (Fixes crashers)
            let rawArticle = try container.decode(String.self, forKey: .articleURL)
            let cleanArticle = rawArticle.trimmingCharacters(in: .whitespacesAndNewlines)
            if let valid = URL(string: cleanArticle) {
                self.articleURL = valid
            } else if let escaped = cleanArticle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let validEscaped = URL(string: escaped) {
                self.articleURL = validEscaped
            } else {
                self.articleURL = URL(string: "https://feeds.bar/invalid")!
            }
            
            if let rawMedia = try container.decodeIfPresent(String.self, forKey: .mediaURL) {
                let clean = rawMedia.trimmingCharacters(in: .whitespacesAndNewlines)
                self.mediaURL = (clean.hasPrefix("http")) ? URL(string: clean) : nil
            } else {
                self.mediaURL = nil
            }
            
            if let rawIcon = try container.decodeIfPresent(String.self, forKey: .sourceIcon) {
                let clean = rawIcon.trimmingCharacters(in: .whitespacesAndNewlines)
                self.sourceIcon = (clean.hasPrefix("http")) ? URL(string: clean) : nil
            } else {
                self.sourceIcon = nil
            }

            // 3. Standard Types
            self.publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
            self.type = try container.decodeIfPresent(TickerType.self, forKey: .type) ?? .news
            self.isVideo = try container.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
            self.id = UUID()
        }

    var accentColor: Color {
        if let v = value { return FeedsTheme.categoryColor(for: v) }
        return FeedsTheme.news
    }

    var signalLabel: String { value?.uppercased() ?? "NEWS" }

    private var stableIdentity: String { "\(sourceName)|\(articleURL.absoluteString)|\(text)" }
    static func == (lhs: TickerItem, rhs: TickerItem) -> Bool { lhs.stableIdentity == rhs.stableIdentity }
    func hash(into hasher: inout Hasher) { hasher.combine(stableIdentity) }
}

enum TickerType: String, Codable, Hashable {
    case news, trend, prediction
}

// MARK: - 6. HELPERS
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (1, 1, 1)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}

// MARK: - AI DISCOVERY MODELS
struct AIResponse: Codable {
    let feeds: [AIFeedItem]
}

struct AIFeedItem: Codable {
    let name: String
    let url: String
    let category: String?
}
