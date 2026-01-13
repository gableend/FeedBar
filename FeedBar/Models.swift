 import Foundation
import SwiftUI

// MARK: - 1. FEEDS BRAND KIT
struct FeedsTheme {
    static let background = Color(hex: "0E0F11")
    static let primaryText = Color(hex: "F4F5F7")
    static let secondaryText = Color(hex: "8A8F98")
    static let divider = Color(hex: "1A1C1F")

    // Category Accents
    static let news = Color(hex: "5E6B8A")       // Slate Blue
    static let futurism = Color(hex: "7A6FF0")   // Desaturated Violet
    static let ai = Color(hex: "4C7DFF")         // Signal Blue
    static let trends = Color(hex: "4FA3A5")     // Muted Teal
    static let utility = Color(hex: "C9A24D")    // Soft Amber

    static func categoryColor(for category: String) -> Color {
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if c.contains("AI") || c.contains("RESEARCH") { return FeedsTheme.ai }
        if c.contains("TECH") || c.contains("PROGRAMMING") || c.contains("COMPANY") || c.contains("ENGINEERING") { return FeedsTheme.futurism }
        if c.contains("BUSINESS") || c.contains("FINANCE") || c.contains("MARKET") || c.contains("ECONOM") { return FeedsTheme.trends }
        if c.contains("SPORT") { return FeedsTheme.trends }
        if c.contains("TREND") { return FeedsTheme.trends }
        if c.contains("WEATHER") || c.contains("UTILITY") { return FeedsTheme.utility }
        if c.contains("FUTURE") { return FeedsTheme.futurism }
        if c.contains("TOPIC") || c.contains("TOPICS") { return FeedsTheme.ai }

        return FeedsTheme.news
    }
}

// MARK: - 2. TICKER ITEM MODEL
struct TickerItem: Identifiable, Hashable, Equatable, Codable {
    // Keep UUID for SwiftUI Identifiable, but DO NOT use it for equality/hash.
    // We override Hashable/Equatable below with a stable identity.
    var id = UUID()

    let text: String
    let type: TickerType

    // "value" is the main Eyebrow (e.g., "NEWS", "TRENDS", "Man Utd")
    let value: String?

    // "score" is the secondary data badge (e.g. "500K+", "98%")
    let score: String?

    let sourceDomain: String
    let sourceName: String
    let mediaURL: URL?
    let isVideo: Bool
    let articleURL: URL

    // NEW: publish date for dedupe + UI
    let publishedAt: Date?

    // Logic: Map Content -> Signal Colour
    var accentColor: Color {
        // Prefer a category-based color if available (value carries topicName or category)
        if let v = value, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FeedsTheme.categoryColor(for: v)
        }

        if sourceName == "Local Weather" { return FeedsTheme.utility }

        // Safety: If it's labeled TRENDS, always use the trends color
        if signalLabel == "TRENDS" { return FeedsTheme.trends }

        switch type {
        case .news: return FeedsTheme.news
        case .prediction: return FeedsTheme.futurism
        case .trend: return FeedsTheme.trends
        }
    }

    // Logic: Map Content -> Eyebrow Text (no date)
    var signalLabel: String {
        if sourceName == "Local Weather" { return "UTILITY" }

        if let val = value, !val.isEmpty {
            return val.uppercased()
        }
        return "NEWS"
    }

    // Use this in the UI for the eyebrow, so “duplicates” look distinct.
    // Example: "NEWS Jan 11"
    var signalLabelWithDate: String {
        guard let d = publishedAt else { return signalLabel }
        return "\(signalLabel) \(Self.shortDate(d))"
    }

    static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current

        let calendar = Calendar.current
        let now = Date()

        let sameYear = calendar.component(.year, from: d) == calendar.component(.year, from: now)
        f.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"

        return f.string(from: d)
    }


    // Stable key for Set dedupe. This is the important bit.
    // We do NOT include mediaURL because it changes when OG enrichment happens.
    private var stableIdentity: String {
        let url = articleURL.absoluteString
        let src = sourceName
        let pub = publishedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        let title = text.lowercased()
        return "\(src)|\(url)|\(pub)|\(title)"
    }

    static func == (lhs: TickerItem, rhs: TickerItem) -> Bool {
        lhs.stableIdentity == rhs.stableIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(stableIdentity)
    }
}

enum TickerType: String, Codable, Hashable {
    case news, trend, prediction
}

// MARK: - 3. DATA STRUCTURES
struct FeedSource: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let domain: String
    let defaultEnabled: Bool
    let category: String

    var settingKey: String {
        let safe = url
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
            .replacingOccurrences(of: "=", with: "_")
        return "source_\(domain)_\(safe)"
    }
}

struct CustomFeed: Identifiable, Codable, Hashable {
    var id: UUID
    let name: String
    let url: String
    let domain: String

    init(id: UUID = UUID(), name: String, url: String, domain: String) {
        self.id = id
        self.name = name
        self.url = url
        self.domain = domain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decode(String.self, forKey: .url)
        self.domain = try container.decode(String.self, forKey: .domain)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    }
}

struct CustomFeedStorage: RawRepresentable {
    var feeds: [CustomFeed]
    init(feeds: [CustomFeed]) { self.feeds = feeds }
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([CustomFeed].self, from: data) else { return nil }
        self.feeds = result
    }
    var rawValue: String {
        guard let data = try? JSONEncoder().encode(feeds),
              let result = String(data: data, encoding: .utf8) else { return "[]" }
        return result
    }
}

struct AIResponse: Codable {
    let feeds: [CustomFeed]
}

struct TrendData: Decodable, Identifiable {
    let id = UUID()
    let date: String
    let value: Int
    private enum CodingKeys: String, CodingKey { case date, value }
}

// MARK: - 4. HELPERS
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
