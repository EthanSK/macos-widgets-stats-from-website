//
//  AppNavigationEvents.swift
//  MacosWidgetsStatsFromWebsite
//
//  Lightweight routing for notification-driven tracker editing.
//

import Foundation

enum AppNavigationEvents {
    static let openTrackerSettingsNotification = Notification.Name("AppNavigationEvents.openTrackerSettings")
    /// Posted when the main app receives a deep link / URL nudge from the
    /// widget extension asking it to drain pending scrape requests. The
    /// app scene observes this and forwards to
    /// `BackgroundScheduler.drainPendingScrapeRequests()`. This is the
    /// fallback path for "user pressed refresh while the main app was
    /// not running" — the watcher inside BackgroundScheduler picks up
    /// new files immediately while the app IS running.
    static let drainPendingScrapeRequestsNotification = Notification.Name("AppNavigationEvents.drainPendingScrapeRequests")
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
