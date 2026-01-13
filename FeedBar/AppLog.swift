import Foundation
import os

nonisolated enum AppLog {
    
    // MARK: - Config
    
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "com.graemechard.FeedBar"
    nonisolated static let logger = Logger(subsystem: subsystem, category: "app")
    
    nonisolated private static let fileURL = URL(fileURLWithPath: "/tmp/feedbar_debug.log")
    nonisolated private static let rotatedURL = URL(fileURLWithPath: "/tmp/feedbar_debug.log.1")
    
    nonisolated private static let queue = DispatchQueue(label: "feedbar.log.queue", qos: .utility)
    
    /// Max size before we rotate the log file (bytes). Default 5 MB.
    nonisolated(unsafe) static var maxFileBytes: Int = 5 * 1024 * 1024
    
    /// Controls which messages are emitted.
    nonisolated(unsafe) static var level: Level = .info
    
    /// Mirror to stderr. Useful when Xcode console is working.
    /// Defaults to true in DEBUG, false in Release.
    nonisolated(unsafe) static var mirrorToStderr: Bool = {
    #if DEBUG
        return true
    #else
        return false
    #endif
    }()
    
    enum Level: Int, Comparable {
        case error = 0
        case warn  = 1
        case info  = 2
        case debug = 3
        
        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}

extension AppLog {
    nonisolated static func info(_ msg: String)  { log(.info,  "INFO",  msg) }
    nonisolated static func warn(_ msg: String)  { log(.warn,  "WARN",  msg) }
    nonisolated static func error(_ msg: String) { log(.error, "ERROR", msg) }
    nonisolated static func debug(_ msg: String) { log(.debug, "DEBUG", msg) }

    nonisolated private static func log(_ levelValue: Level, _ label: String, _ msg: String) {
        guard levelValue.rawValue <= level.rawValue else { return }

        let timestamp = ISO8601DateFormatter.withFractionalSeconds.string(from: Date())
        let line = "\(timestamp) [\(label)] pid=\(getpid()) \(msg)\n"

        // Write to file on background queue
        queue.async {
            do {
                try rotateIfNeeded()
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let fh = try FileHandle(forWritingTo: fileURL)
                    try fh.seekToEnd()
                    try fh.write(contentsOf: Data(line.utf8))
                    try fh.close()
                } else {
                    try Data(line.utf8).write(to: fileURL)
                }
            } catch {
                // ignore file write errors for logging
            }
        }

        // Mirror to unified logger
        switch levelValue {
        case .error:
            logger.error("\(msg, privacy: .public)")
        case .warn:
            logger.warning("\(msg, privacy: .public)")
        case .info:
            logger.info("\(msg, privacy: .public)")
        case .debug:
            logger.debug("\(msg, privacy: .public)")
        }

        if mirrorToStderr {
            fputs(line, stderr)
            fflush(stderr)
        }
    }

    nonisolated static func rotateIfNeeded() throws {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64 else { return }
        if size < UInt64(maxFileBytes) { return }

        // Rotate
        try? fm.removeItem(at: rotatedURL)
        try fm.moveItem(at: fileURL, to: rotatedURL)
    }
}

private extension ISO8601DateFormatter {
    nonisolated static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
