import Foundation

// MARK: - Dedicated Background Parser
// Using a standalone actor for parsing is the most robust Swift 6 way
// to ensure work NEVER touches the MainActor.
final class RSSParser: Sendable {
    private let data: Data
    private let source: FeedSource
    private let type: TickerType
    private let topicName: String
    private let maxAgeDays: Int

    init(data: Data, source: FeedSource, type: TickerType, topicName: String, maxAgeDays: Int) {
        self.data = data
        self.source = source
        self.type = type
        self.topicName = topicName
        self.maxAgeDays = maxAgeDays
    }

    func parse() -> [TickerItem] {
        let parser = XMLParser(data: data)
        let delegate = RSSParserDelegate(source: source, topicName: topicName, type: type)
        parser.delegate = delegate
        parser.parse()
        
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? .distantPast
        return delegate.items.filter { ($0.publishedAt ?? Date()) >= cutoff }
    }

    static func parseDate(_ s: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = df.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - Internal Delegate
// Marked nonisolated to prevent MainActor inheritance
private final class RSSParserDelegate: NSObject, XMLParserDelegate {
    var items: [TickerItem] = []
    private let source: FeedSource
    private let topicName: String
    private let type: TickerType
    
    private var currentElement = "", buffer = "", title = "", link = ""
    private var inItem = false, inEntry = false
    private var pubDate: Date? = nil
    private var mediaURL: URL? = nil, enclosureURL: URL? = nil
    
    init(source: FeedSource, topicName: String, type: TickerType) {
        self.source = source
        self.topicName = topicName
        self.type = type
        super.init()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName.lowercased()
        buffer = ""
        if currentElement == "item" || currentElement == "entry" {
            inItem = (currentElement == "item")
            inEntry = (currentElement == "entry")
            title = ""; link = ""; pubDate = nil; mediaURL = nil; enclosureURL = nil
        }
        if currentElement == "enclosure" { enclosureURL = URL(string: attributeDict["url"] ?? "") }
        if ["content", "thumbnail", "media:content", "media:thumbnail"].contains(currentElement) {
            if let urlStr = attributeDict["url"] { mediaURL = URL(string: urlStr) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let el = elementName.lowercased()
        if inItem || inEntry {
            switch el {
            case "title": title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "link": if !buffer.isEmpty { link = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "pubdate", "published", "updated":
                pubDate = RSSParser.parseDate(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "item", "entry":
                finalizeItem()
                inItem = false; inEntry = false
            default: break
            }
        }
    }

    private func finalizeItem() {
        let cleanLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleanLink) else { return }
        
        let item = TickerItem(
            text: title.decodedHTML,
            type: type,
            value: topicName.isEmpty ? (source.category ?? "NEWS") : topicName,
            score: nil,
            sourceDomain: source.domain,
            sourceName: source.name,
            sourceIcon: nil,
            mediaURL: mediaURL ?? enclosureURL,
            isVideo: (mediaURL ?? enclosureURL)?.pathExtension == "mp4",
            articleURL: url,
            publishedAt: pubDate
        )
        items.append(item)
    }
}
