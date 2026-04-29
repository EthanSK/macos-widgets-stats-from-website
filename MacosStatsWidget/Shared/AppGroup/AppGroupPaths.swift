//
//  AppGroupPaths.swift
//  MacosStatsWidgetShared
//
//  v0.1 stub — see PLAN.md §4 for the full design.
//

import Foundation

enum AppGroupPaths {
    static let identifier = "group.com.ethansk.macos-stats-widget"

    static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
