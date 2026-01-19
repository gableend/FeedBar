import Foundation

// MARK: - DATA MODELS
struct GlobalTrendItem: Codable {
    let title: String
    let rank: Int?
    let source: String
    let volume: String
    let url: String
    let image: String? // Added image support
    let score: Int?
}

enum TrendError: Error {
    case executableNotFound
    case invalidOutput
    case scriptError(String)
}

// MARK: - PROTOCOL
protocol TrendProvider: Sendable {
    func fetchGlobalTrends() async throws -> [TickerItem]
}

// MARK: - PYTHON ADAPTER
// ✅ FIXED: Marked final and used static helper to resolve isolation errors
final class PythonTrendAdapter: TrendProvider, @unchecked Sendable {
    private let folderName = "fetch_trends"
    private let binaryName = "fetch_trends"
    
    init() {}
    
    func fetchGlobalTrends() async throws -> [TickerItem] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: TrendError.scriptError("Self is nil"))
                    return
                }
                
                guard let path = Bundle.main.path(forResource: self.binaryName, ofType: nil, inDirectory: self.folderName) else {
                    AppLog.error("❌ Bundle Error: binary not found in \(self.folderName)")
                    continuation.resume(throwing: TrendError.executableNotFound)
                    return
                }
                
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.currentDirectoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
                let outputPipe = Pipe()
                task.standardOutput = outputPipe
                
                do {
                    try task.run()
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    
                    if let outputString = String(data: data, encoding: .utf8),
                       let startRange = outputString.range(of: "---DATA_START---"),
                       let endRange = outputString.range(of: "---DATA_END---") {
                        
                        let jsonString = outputString[startRange.upperBound..<endRange.lowerBound]
                        let jsonData = Data(jsonString.utf8)
                        let rawTrends = try JSONDecoder().decode([GlobalTrendItem].self, from: jsonData)
                        
                        let tickerItems = rawTrends
                            .filter { !$0.title.isEmpty && $0.title != "No Title" }
                            .map { trend in
                                var displayDomain = ""
                                if let host = URL(string: trend.url)?.host {
                                    displayDomain = BrandIconProvider.normalizedDomain(host)
                                }
                                
                                if !BrandIconProvider.isLikelyDomain(displayDomain) {
                                    // ✅ FIXED: Calling static nonisolated helper
                                    displayDomain = Self.cleanDomain(from: trend.source)
                                }
                                
                                // ✅ creation is safe because TickerItem.init is nonisolated
                                return TickerItem(
                                    text: trend.title,
                                    type: .news,
                                    value: "TRENDS",
                                    score: trend.volume,
                                    sourceDomain: displayDomain,
                                    sourceName: trend.source,
                                    sourceIcon: nil,
                                    mediaURL: URL(string: trend.image ?? ""),
                                    isVideo: false,
                                    articleURL: URL(string: trend.url) ?? URL(string: "https://google.com")!,
                                    publishedAt: Date()
                                )
                            }
                        
                        AppLog.info("✅ Python Success: Parsed \(tickerItems.count) trends")
                        continuation.resume(returning: tickerItems)
                    } else {
                        continuation.resume(throwing: TrendError.invalidOutput)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // ✅ FIXED: Marked static and nonisolated to allow background access
    nonisolated private static func cleanDomain(from source: String) -> String {
        let lower = source.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "hacker news" { return "news.ycombinator.com" }
        if lower == "wikipedia" { return "wikipedia.org" }
        if lower == "bbc" { return "bbc.co.uk" }
        
        let firstWord = lower.components(separatedBy: .whitespacesAndNewlines).first ?? lower
        return firstWord.contains(".") ? firstWord : "\(firstWord).com"
    }
}
