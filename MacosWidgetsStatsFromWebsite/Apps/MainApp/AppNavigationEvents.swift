//
//  AppNavigationEvents.swift
//  MacosWidgetsStatsFromWebsite
//
//  Lightweight routing for notification-driven tracker editing.
//

import Foundation

enum AppNavigationEvents {
    static let openTrackerSettingsNotification = Notification.Name("AppNavigationEvents.openTrackerSettings")
    private static var pendingTrackerID: UUID?

    static func openTrackerSettings(trackerID: UUID) {
        pendingTrackerID = trackerID
        NotificationCenter.default.post(
            name: openTrackerSettingsNotification,
            object: nil,
            userInfo: ["trackerID": trackerID]
        )
    }

    static func consumePendingTrackerID() -> UUID? {
        let trackerID = pendingTrackerID
        pendingTrackerID = nil
        return trackerID
    }
}
