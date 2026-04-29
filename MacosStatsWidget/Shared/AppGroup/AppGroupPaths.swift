//
//  AppGroupPaths.swift
//  MacosStatsWidgetShared
//
//  Typed paths for canonical and App Group configuration files.
//

import Foundation

enum AppGroupPaths {
    static let identifier = "group.com.ethansk.macos-stats-widget"
    static let applicationSupportDirectoryName = "macOS Stats Widget"
    static let trackersFileName = "trackers.json"
    static let readingsFileName = "readings.json"
    static let snapshotsDirectoryName = "snapshots"

    static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func canonicalApplicationSupportURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    static func canonicalTrackersURL() -> URL {
        canonicalApplicationSupportURL().appendingPathComponent(trackersFileName, isDirectory: false)
    }

    static func appGroupTrackersURL() -> URL? {
        sharedContainerURL()?.appendingPathComponent(trackersFileName, isDirectory: false)
    }

    static func appGroupReadingsURL() -> URL? {
        sharedContainerURL()?.appendingPathComponent(readingsFileName, isDirectory: false)
    }

    static func snapshotsDirectoryURL() -> URL? {
        sharedContainerURL()?.appendingPathComponent(snapshotsDirectoryName, isDirectory: true)
    }

    static func snapshotURL(for trackerID: UUID) -> URL? {
        snapshotsDirectoryURL()?.appendingPathComponent("\(trackerID.uuidString).png", isDirectory: false)
    }

    static func relativeSnapshotPath(for trackerID: UUID) -> String {
        "\(snapshotsDirectoryName)/\(trackerID.uuidString).png"
    }
}
