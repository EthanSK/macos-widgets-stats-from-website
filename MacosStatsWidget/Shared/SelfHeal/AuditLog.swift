//
//  AuditLog.swift
//  MacosStatsWidgetShared
//
//  Append-only audit log for selector-heal attempts.
//

import Foundation

struct AuditLogEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var timestamp: Date
    var trackerID: UUID
    var beforeSelector: String?
    var afterSelector: String?
    var outcome: String
    var source: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        trackerID: UUID,
        beforeSelector: String?,
        afterSelector: String?,
        outcome: String,
        source: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.trackerID = trackerID
        self.beforeSelector = beforeSelector
        self.afterSelector = afterSelector
        self.outcome = outcome
        self.source = source
    }
}

struct AuditLogFile: Codable, Equatable {
    var schemaVersion: Int
    var entries: [AuditLogEntry]

    static var empty: AuditLogFile {
        AuditLogFile(schemaVersion: currentSchemaVersion, entries: [])
    }
}

final class AuditLog {
    static func entries(for trackerID: UUID? = nil) -> [AuditLogEntry] {
        let file = load()
        guard let trackerID else {
            return file.entries
        }

        return file.entries.filter { $0.trackerID == trackerID }
    }

    static func record(
        trackerID: UUID,
        beforeSelector: String?,
        afterSelector: String?,
        outcome: String,
        source: String
    ) {
        var file = load()
        file.schemaVersion = currentSchemaVersion
        file.entries.append(
            AuditLogEntry(
                trackerID: trackerID,
                beforeSelector: beforeSelector,
                afterSelector: afterSelector,
                outcome: outcome,
                source: source
            )
        )

        file.entries = Array(file.entries.suffix(1_000))
        try? write(file)
    }

    private static func load() -> AuditLogFile {
        guard let url = AppGroupPaths.appGroupAuditLogURL(),
              let data = try? Data(contentsOf: url) else {
            return .empty
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(AuditLogFile.self, from: data)
            guard file.schemaVersion == currentSchemaVersion else {
                return .empty
            }
            return file
        } catch {
            return .empty
        }
    }

    private static func write(_ file: AuditLogFile) throws {
        guard let url = AppGroupPaths.appGroupAuditLogURL() else {
            return
        }

        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }
}
