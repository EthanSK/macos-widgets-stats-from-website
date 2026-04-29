//
//  AppDelegate.swift
//  MacosStatsWidget
//
//  v0.1 stub — see PLAN.md §4 for the full design.
//

import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        HealNotifier.shared.configure()
        MCPServer.shared.startSocketServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPServer.shared.stopSocketServer()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let trackerIDString = response.notification.request.content.userInfo["trackerID"] as? String,
           let trackerID = UUID(uuidString: trackerIDString) {
            NSApp.activate(ignoringOtherApps: true)
            AppNavigationEvents.openTrackerSettings(trackerID: trackerID)
        }

        completionHandler()
    }
}
