//
//  TrackerResult.swift
//  MacosStatsWidgetShared
//
//  Last-known tracker reading persisted in App Group readings.json.
//

import Foundation

enum TrackerStatus: String, Codable, Equatable {
    case ok
    case stale
    case broken
}

struct TrackerReading: Codable, Equatable {
    var currentValue: String?
    var currentNumeric: Double?
    var snapshotPath: String?
    var snapshotCacheKey: String?
    var snapshotCapturedAt: Date?
    var lastUpdatedAt: Date?
    var status: TrackerStatus
    var sparkline: [Double]
    var lastError: String?
    var consecutiveFailureCount: Int?

    init(
        currentValue: String? = nil,
        currentNumeric: Double? = nil,
        snapshotPath: String? = nil,
        snapshotCacheKey: String? = nil,
        snapshotCapturedAt: Date? = nil,
        lastUpdatedAt: Date? = Date(),
        status: TrackerStatus = .ok,
        sparkline: [Double] = [],
        lastError: String? = nil,
        consecutiveFailureCount: Int? = 0
    ) {
        self.currentValue = currentValue
        self.currentNumeric = currentNumeric
        self.snapshotPath = snapshotPath
        self.snapshotCacheKey = snapshotCacheKey
        self.snapshotCapturedAt = snapshotCapturedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.status = status
        self.sparkline = sparkline
        self.lastError = lastError
        self.consecutiveFailureCount = consecutiveFailureCount
    }
}

struct TrackerReadingsFile: Codable, Equatable {
    var schemaVersion: Int
    var readings: [String: TrackerReading]

    static var empty: TrackerReadingsFile {
        TrackerReadingsFile(schemaVersion: currentSchemaVersion, readings: [:])
    }
}

extension ValueParser {
    func parseNumeric(from value: String) -> Double? {
        switch type {
        case .raw:
            return nil
        case .currencyOrNumber:
            var candidate = value
            stripChars.forEach { candidate = candidate.replacingOccurrences(of: $0, with: "") }
            return Double(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
        case .percent:
            let candidate = value
                .replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(candidate)
        }
    }
}
