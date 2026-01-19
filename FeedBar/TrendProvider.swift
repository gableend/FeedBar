import Foundation

// MARK: - DATA MODELS
struct GlobalTrendItem: Codable {
    let title: String
    let rank: Int?
    let source: String
    let volume: String
    let url: String
    let score: Int
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

// PythonTrendAdapter is IO-bound and safe to use across concurrency domains, mark as unchecked Sendable
extension PythonTrendAdapter: @unchecked Sendable {}

// MARK: - PYTHON ADAPTER
class PythonTrendAdapter: TrendProvider {
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
                
                // PRESERVED: Exact working path logic for folder references
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
                task.standardError = FileHandle.nullDevice
                
                do {
                    try task.run()
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    
                    if let outputString = String(data: data, encoding: .utf8),
                       let startRange = outputString.range(of: "---DATA_START---"),
                       let endRange = outputString.range(of: "---DATA_END---") {
                        
                        let jsonString = outputString[startRange.upperBound..<endRange.lowerBound]
                        let jsonData = Data(jsonString.utf8)
                        let decoder = JSONDecoder()
                        let rawTrends = try decoder.decode([GlobalTrendItem].self, from: jsonData)
                        
                        let tickerItems = rawTrends
                            .filter { !$0.title.isEmpty && $0.title != "No Title" }
                            .map { trend in
                                
                                // 1. ICON LOGIC: Use Helpers.swift to get the real domain
                                var displayDomain = ""
                                
                                // A. Extract from URL (Priority: Shows destination icon like 'github.com')
                                if let urlObj = URL(string: trend.url), let host = urlObj.host {
                                    displayDomain = BrandIconProvider.normalizedDomain(host)
                                }
                                
                                // B. Fallback to Source Name if URL domain is invalid
                                if !BrandIconProvider.isLikelyDomain(displayDomain) {
                                    displayDomain = self.cleanDomain(from: trend.source)
                                }
                                
                                return TickerItem(
                                    text: trend.title,
                                    type: .news,               // Changed to .news to ensure UI loads favicon
                                    value: "TRENDS",           // Main Eyebrow
                                    score: trend.volume,       // "500K+" Badge
                                    sourceDomain: displayDomain,
                                    sourceName: trend.source,  // "Hacker News"
                                    sourceIcon: nil,           // ✅ FIXED: Added missing URL? parameter
                                    mediaURL: nil,
                                    isVideo: false,
                                    articleURL: URL(string: trend.url) ?? URL(string: "https://google.com")!,
                                    publishedAt: Date()
                                )
                            }
                        
                        AppLog.info("✅ Python Success: Parsed \(tickerItems.count) trends")
                        continuation.resume(returning: tickerItems)
                        
                    } else {
                        AppLog.warn("❌ Python Output Invalid")
                        continuation.resume(throwing: TrendError.invalidOutput)
                    }
                } catch {
                    AppLog.error("❌ Python Execution Error: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // HELPER: Fallback cleaner if URL extraction fails
    private func cleanDomain(from source: String) -> String {
        let lower = source.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Manual mapping for aggregators if URL is missing
        if lower == "hacker news" { return "news.ycombinator.com" }
        if lower == "wikipedia" { return "wikipedia.org" }
        if lower == "bbc" { return "bbc.co.uk" }
        
        let firstWord = lower.components(separatedBy: CharacterSet.whitespacesAndNewlines).first ?? lower
        
        if firstWord.contains(".") { return firstWord }
        return "\(firstWord).com"
    }
}
