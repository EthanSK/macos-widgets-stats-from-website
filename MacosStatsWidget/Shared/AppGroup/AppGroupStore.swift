//
//  AppGroupStore.swift
//  MacosStatsWidgetShared
//
//  Observable configuration store with atomic JSON persistence.
//

import Combine
import Foundation

final class AppGroupStore: ObservableObject {
    @Published private(set) var schemaVersion: Int
    @Published var trackers: [Tracker]
    @Published var widgetConfigurations: [WidgetConfiguration]
    @Published var preferences: AppPreferences
    @Published private(set) var lastPersistenceError: String?

    init() {
        let configuration = Self.loadConfiguration()
        schemaVersion = configuration.schemaVersion
        trackers = configuration.trackers
        widgetConfigurations = configuration.widgetConfigurations
        preferences = configuration.preferences
    }

    func addTracker(_ tracker: Tracker) {
        trackers.append(tracker)
        persist()
    }

    func updateTracker(_ tracker: Tracker) {
        guard let index = trackers.firstIndex(where: { $0.id == tracker.id }) else {
            addTracker(tracker)
            return
        }

        trackers[index] = tracker
        persist()
    }

    func upsertTracker(_ tracker: Tracker) {
        if trackers.contains(where: { $0.id == tracker.id }) {
            updateTracker(tracker)
        } else {
            addTracker(tracker)
        }
    }

    func duplicateTracker(_ tracker: Tracker) {
        var copy = tracker
        copy.id = UUID()
        copy.name = "\(tracker.name) Copy"
        trackers.append(copy)
        persist()
    }

    func deleteTracker(id: UUID) {
        trackers.removeAll { $0.id == id }
        persist()
    }

    func moveTrackers(fromOffsets source: IndexSet, toOffset destination: Int) {
        let sortedSource = source.sorted()
        guard !sortedSource.isEmpty else {
            return
        }

        let movedTrackers = sortedSource.map { trackers[$0] }
        var reordered = trackers
        for index in sortedSource.reversed() {
            reordered.remove(at: index)
        }

        let adjustment = sortedSource.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(destination - adjustment, reordered.count))
        reordered.insert(contentsOf: movedTrackers, at: adjustedDestination)
        trackers = reordered
        persist()
    }

    func persist() {
        do {
            let configuration = AppConfiguration(
                schemaVersion: currentSchemaVersion,
                trackers: trackers,
                widgetConfigurations: widgetConfigurations,
                preferences: preferences
            )
            try Self.write(configuration: configuration, to: AppGroupPaths.canonicalTrackersURL())

            if let appGroupURL = AppGroupPaths.appGroupTrackersURL() {
                try Self.write(configuration: configuration, to: appGroupURL)
            }

            schemaVersion = currentSchemaVersion
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    static func loadReadings() -> TrackerReadingsFile {
        guard let url = AppGroupPaths.appGroupReadingsURL(),
              let data = try? Data(contentsOf: url) else {
            return .empty
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(TrackerReadingsFile.self, from: data)
            guard file.schemaVersion == currentSchemaVersion else {
                return .empty
            }
            return file
        } catch {
            return .empty
        }
    }

    static func reading(for trackerID: UUID) -> TrackerReading? {
        loadReadings().readings[trackerID.uuidString]
    }

    static func record(reading newReading: TrackerReading, for tracker: Tracker) throws {
        var file = loadReadings()
        let key = tracker.id.uuidString
        let existingSparkline = file.readings[key]?.sparkline ?? []
        var reading = newReading

        if let numeric = reading.currentNumeric {
            let displayWindow = max(1, tracker.history.displayWindow)
            reading.sparkline = Array((existingSparkline + [numeric]).suffix(displayWindow))
        } else if reading.sparkline.isEmpty {
            reading.sparkline = existingSparkline
        }

        file.schemaVersion = currentSchemaVersion
        file.readings[key] = reading
        try write(readingsFile: file)
    }

    static func recordFailure(message: String, for tracker: Tracker) throws {
        let existing = reading(for: tracker.id)
        let failureCount = (existing?.status == .broken ? 3 : 1)
        let status: TrackerStatus = failureCount >= 3 ? .broken : .stale
        let reading = TrackerReading(
            currentValue: existing?.currentValue,
            currentNumeric: existing?.currentNumeric,
            snapshotPath: existing?.snapshotPath,
            snapshotCacheKey: existing?.snapshotCacheKey,
            snapshotCapturedAt: existing?.snapshotCapturedAt,
            lastUpdatedAt: existing?.lastUpdatedAt,
            status: status,
            sparkline: existing?.sparkline ?? [],
            lastError: message
        )
        try record(reading: reading, for: tracker)
    }

    private static func loadConfiguration() -> AppConfiguration {
        loadConfiguration(from: AppGroupPaths.canonicalTrackersURL())
    }

    static func loadAppGroupConfiguration() -> AppConfiguration {
        guard let url = AppGroupPaths.appGroupTrackersURL() else {
            return .empty
        }

        return loadConfiguration(from: url)
    }

    private static func loadConfiguration(from url: URL) -> AppConfiguration {

        guard let data = try? Data(contentsOf: url) else {
            return AppConfiguration.empty
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let configuration = try decoder.decode(AppConfiguration.self, from: data)
            guard configuration.schemaVersion == currentSchemaVersion else {
                return AppConfiguration.empty
            }
            return configuration
        } catch {
            return AppConfiguration.empty
        }
    }

    private static func write(configuration: AppConfiguration, to destinationURL: URL) throws {
        try writeJSON(configuration, to: destinationURL)
    }

    private static func write(readingsFile: TrackerReadingsFile) throws {
        guard let url = AppGroupPaths.appGroupReadingsURL() else {
            return
        }

        try writeJSON(readingsFile, to: url)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        let temporaryURL = directoryURL.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporaryURL, options: .atomic)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}

struct AppConfiguration: Codable {
    var schemaVersion: Int
    var trackers: [Tracker]
    var widgetConfigurations: [WidgetConfiguration]
    var preferences: AppPreferences

    static var empty: AppConfiguration {
        AppConfiguration(
            schemaVersion: currentSchemaVersion,
            trackers: [],
            widgetConfigurations: [],
            preferences: AppPreferences()
        )
    }
}

struct AppPreferences: Codable, Equatable {
    var selfHeal: SelfHealPreferences
    var notificationChannels: NotificationChannelPreferences
    var snapshotConcurrencyCap: Int

    init(
        selfHeal: SelfHealPreferences = SelfHealPreferences(),
        notificationChannels: NotificationChannelPreferences = NotificationChannelPreferences(),
        snapshotConcurrencyCap: Int = 8
    ) {
        self.selfHeal = selfHeal
        self.notificationChannels = notificationChannels
        self.snapshotConcurrencyCap = snapshotConcurrencyCap
    }
}

struct SelfHealPreferences: Codable, Equatable {
    var regexFallbackEnabled: Bool
    var externalAgentHealEnabled: Bool

    init(regexFallbackEnabled: Bool = true, externalAgentHealEnabled: Bool = true) {
        self.regexFallbackEnabled = regexFallbackEnabled
        self.externalAgentHealEnabled = externalAgentHealEnabled
    }
}

struct NotificationChannelPreferences: Codable, Equatable {
    var macosNative: Bool
    var webhook: String?

    init(macosNative: Bool = true, webhook: String? = nil) {
        self.macosNative = macosNative
        self.webhook = webhook
    }
}
