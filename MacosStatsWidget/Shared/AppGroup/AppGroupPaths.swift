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
    static let auditLogFileName = "audit-log.json"
    static let mcpSocketFileName = "mcp.sock"

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

    static func appGroupAuditLogURL() -> URL? {
        sharedContainerURL()?.appendingPathComponent(auditLogFileName, isDirectory: false)
    }

    static func mcpApplicationSupportURL() -> URL {
        if let sharedContainerURL = sharedContainerURL() {
            return sharedContainerURL
        }

        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent("MacosStatsWidget", isDirectory: true)
    }

    static func mcpSocketURL() -> URL {
        mcpApplicationSupportURL().appendingPathComponent(mcpSocketFileName, isDirectory: false)
    }
}
