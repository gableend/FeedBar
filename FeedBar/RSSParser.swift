import Foundation

// Minimal RSS + Atom parser for FeedBar.
// Produces TickerItem objects with text/link/date and optional enclosure/media URL.
// Explicitly nonisolated and Sendable to permit background execution in Swift 6.
final class RSSParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let data: Data
    private let source: FeedSource
    private let type: TickerType
    private let topicName: String
    private let maxAgeDays: Int

    private var items: [TickerItem] = []

    // State
    private var currentElement: String = ""
    private var buffer: String = ""

    private var inItem = false          // RSS <item>
    private var inEntry = false         // Atom <entry>

    private var title: String = ""
    private var link: String = ""
    private var pubDate: Date? = nil
    private var enclosureURL: URL? = nil
    private var mediaURL: URL? = nil

    // Atom link rel="alternate"
    private var atomLinkRel: String? = nil
    private var atomLinkHref: String? = nil

    // MARK: - API
    
    // Explicitly nonisolated to allow calling from Task.detached
    nonisolated init(data: Data, source: FeedSource, type: TickerType, topicName: String, maxAgeDays: Int) {
        self.data = data
        self.source = source
        self.type = type
        self.topicName = topicName
        self.maxAgeDays = maxAgeDays
        super.init()
    }

    nonisolated func parse() -> [TickerItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()

        // Final prune by age (defensive)
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? .distantPast
        return items.filter { ($0.publishedAt ?? Date()) >= cutoff }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName.lowercased()
        buffer = ""

        if currentElement == "item" {
            inItem = true
            resetCurrent()
        }

        if currentElement == "entry" {
            inEntry = true
            resetCurrent()
        }

        // RSS media
        if inItem || inEntry {
            if currentElement == "enclosure" {
                if let urlStr = attributeDict["url"], let u = URL(string: urlStr) {
                    enclosureURL = u
                }
            }

            // media:content / media:thumbnail
            if currentElement == "content" || currentElement == "thumbnail" {
                if let urlStr = attributeDict["url"], let u = URL(string: urlStr) {
                    mediaURL = u
                }
            }

            // Atom <link rel="alternate" href="..."/>
            if inEntry && currentElement == "link" {
                atomLinkRel = attributeDict["rel"]
                atomLinkHref = attributeDict["href"]
                // If rel missing, many feeds default to alternate
                if (atomLinkRel == nil || atomLinkRel == "alternate"), let href = atomLinkHref {
                    link = href
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let el = elementName.lowercased()
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if inItem || inEntry {
            switch el {
            case "title":
                if !text.isEmpty { title = text }

            // RSS <link>...</link>
            case "link":
                // Atom often uses <link .../> not text nodes, so only set if we got text.
                if !text.isEmpty { link = text }

            // RSS dates
            case "pubdate", "published", "updated", "dc:date":
                if pubDate == nil, let d = Self.parseDate(text) {
                    pubDate = d
                }

            default:
                break
            }
        }

        if el == "item" && inItem {
            inItem = false
            finalizeCurrent()
        }

        if el == "entry" && inEntry {
            inEntry = false
            finalizeCurrent()
        }

        buffer = ""
    }

    // MARK: - Build item

    private func resetCurrent() {
        title = ""
        link = ""
        pubDate = nil
        enclosureURL = nil
        mediaURL = nil
        atomLinkRel = nil
        atomLinkHref = nil
    }

    private func finalizeCurrent() {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { return }

            let linkStr = link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let articleURL = URL(string: linkStr), !linkStr.isEmpty else { return }

            let domain = source.domain.isEmpty ? (articleURL.host ?? "unknown") : source.domain
            
            // ✅ FIX: Safely unwrap optional category with default "GENERAL"
            let safeCategory = source.category ?? "GENERAL"
            let topicValue = topicName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? safeCategory.uppercased() : topicName.uppercased()

            let candidateMedia = mediaURL ?? enclosureURL
            let isVideo = candidateMedia?.pathExtension.lowercased() == "mp4"

            let item = TickerItem(
                text: cleanTitle,
                type: self.type,
                value: topicValue,
                score: nil,
                sourceDomain: domain,
                sourceName: source.name,
                sourceIcon: nil,
                mediaURL: candidateMedia,
                isVideo: isVideo,
                articleURL: articleURL,
                publishedAt: pubDate
            )

            items.append(item)
        }

    // MARK: - Date parsing

    private static func parseDate(_ s: String) -> Date? {
        let str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !str.isEmpty else { return nil }

        // Common RSS: "Tue, 13 Jan 2026 17:18:43 GMT"
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.timeZone = TimeZone(secondsFromGMT: 0)
        rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = rfc822.date(from: str) { return d }

        // Variant: no weekday
        let rfc822b = DateFormatter()
        rfc822b.locale = Locale(identifier: "en_US_POSIX")
        rfc822b.timeZone = TimeZone(secondsFromGMT: 0)
        rfc822b.dateFormat = "dd MMM yyyy HH:mm:ss zzz"
        if let d = rfc822b.date(from: str) { return d }

        // Atom ISO 8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { return d }

        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        if let d = iso2.date(from: str) { return d }

        return nil
    }
}
