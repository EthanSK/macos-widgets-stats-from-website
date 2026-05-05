//
//  ActivityLogger.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Small file-backed activity log shared by the app, CLI, MCP, and widget extension.
//

import Foundation

enum ActivityLogger {
    private static let queue = DispatchQueue(label: "com.ethansk.macos-widgets-stats-from-website.activity-log")
    private static let maximumLogBytes: UInt64 = 1_000_000
    private static let rotatedLogFileName = "activity.log.1"

    static func log(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metadataText = formattedMetadata(metadata)
        let line = "\(timestamp) [\(sanitized(category))] \(sanitized(message))\(metadataText)\n"

        queue.async {
            write(line)
        }
    }

    static func logFileURL() -> URL {
        AppGroupPaths.activityLogURL()
    }

    static func logsDirectoryURL() -> URL {
        AppGroupPaths.logsDirectoryURL()
    }

    static func ensureLogFileExists() {
        queue.sync {
            ensureLogFileExistsUnlocked()
        }
    }

    static func recentLogText(lineLimit: Int = 250) -> String {
        queue.sync {
            ensureLogFileExistsUnlocked()
            guard let data = try? Data(contentsOf: logFileURL()),
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(max(1, lineLimit)).joined(separator: "\n")
        }
    }

    private static func write(_ line: String) {
        do {
            ensureLogFileExistsUnlocked()
            try rotateIfNeeded(addingBytes: UInt64(line.utf8.count))
            let handle = try FileHandle(forWritingTo: logFileURL())
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            // Logging must never affect app, widget, scraper, or MCP execution.
        }
    }

    private static func ensureLogFileExistsUnlocked() {
        do {
            try FileManager.default.createDirectory(at: logsDirectoryURL(), withIntermediateDirectories: true, attributes: nil)
            if !FileManager.default.fileExists(atPath: logFileURL().path) {
                try Data().write(to: logFileURL(), options: .atomic)
            }
        } catch {
            // Logging must never affect app, widget, scraper, or MCP execution.
        }
    }

    private static func rotateIfNeeded(addingBytes: UInt64) throws {
        let fileManager = FileManager.default
        let url = logFileURL()
        let size = ((try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value) ?? 0
        guard size + addingBytes > maximumLogBytes else {
            return
        }

        let rotatedURL = logsDirectoryURL().appendingPathComponent(rotatedLogFileName, isDirectory: false)
        if fileManager.fileExists(atPath: rotatedURL.path) {
            try fileManager.removeItem(at: rotatedURL)
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.moveItem(at: url, to: rotatedURL)
        }
        try Data().write(to: url, options: .atomic)
    }

    private static func formattedMetadata(_ metadata: [String: String]) -> String {
        guard !metadata.isEmpty else {
            return ""
        }

        let pairs = metadata
            .sorted { $0.key < $1.key }
            .map { "\(sanitized($0.key))=\(sanitized($0.value))" }
            .joined(separator: " ")
        return " \(pairs)"
    }

    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
