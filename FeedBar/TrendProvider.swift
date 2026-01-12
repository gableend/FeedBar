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
protocol TrendProvider {
    func fetchGlobalTrends() async throws -> [TickerItem]
}

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
                
                guard let path = Bundle.main.path(forResource: self.binaryName, ofType: nil, inDirectory: self.folderName) else {
                    print("❌ Bundle Error: binary not found")
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
                                // 1. CLEAN THE DOMAIN for the Favicon
                                let cleanDom = self.cleanDomain(from: trend.source)
                                
                                return TickerItem(
                                    text: trend.title,
                                    type: .prediction,
                                    value: "TRENDS",          // Main Eyebrow
                                    score: trend.volume,      // "500K+" Badge
                                    sourceDomain: cleanDom,   // "cnbc.com" (For Favicon)
                                    sourceName: trend.source, // "cnbc business" (For Display)
                                    mediaURL: nil,
                                    isVideo: false,
                                    articleURL: URL(string: trend.url) ?? URL(string: "https://google.com")!,
                                    publishedAt: Date()       // ✅ NEW required param
                                )

                            }
                        
                        print("✅ Python Success: Parsed \(tickerItems.count) trends")
                        continuation.resume(returning: tickerItems)
                        
                    } else {
                        print("❌ Python Output Invalid")
                        continuation.resume(throwing: TrendError.invalidOutput)
                    }
                } catch {
                    print("❌ Python Execution Error: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // HELPER: Turns "cnbc business" -> "cnbc.com"
    private func cleanDomain(from source: String) -> String {
        let lower = source.lowercased()
        let firstWord = lower.components(separatedBy: CharacterSet.whitespacesAndNewlines).first ?? lower
        
        // Handle common edge cases
        if firstWord == "wikipedia" { return "wikipedia.org" }
        if firstWord == "bbc" { return "bbc.co.uk" }
        if firstWord.contains(".") { return firstWord }
        
        return "\(firstWord).com"
    }
}
