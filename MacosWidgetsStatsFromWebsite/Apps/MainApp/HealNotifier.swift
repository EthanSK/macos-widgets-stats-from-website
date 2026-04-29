//
//  HealNotifier.swift
//  MacosWidgetsStatsFromWebsite
//
//  Native notifications for broken trackers.
//

import Foundation
import UserNotifications

final class HealNotifier {
    static let shared = HealNotifier()

    static let categoryIdentifier = "TRACKER_NEEDS_ATTENTION"
    static let reidentifyActionIdentifier = "REIDENTIFY_TRACKER"

    private init() {}

    func configure() {
        let action = UNNotificationAction(
            identifier: Self.reidentifyActionIdentifier,
            title: "Re-identify Element",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyBrokenTracker(_ tracker: Tracker, failureCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(tracker.name.isEmpty ? "Tracker" : tracker.name) needs attention"
        content.body = "The selector has failed \(failureCount) times. Open the app to re-identify the element."
        content.categoryIdentifier = Self.categoryIdentifier
        content.sound = .default
        content.userInfo = ["trackerID": tracker.id.uuidString]
        content.threadIdentifier = "tracker-\(tracker.id.uuidString)"

        let request = UNNotificationRequest(
            identifier: "tracker-broken-\(tracker.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
