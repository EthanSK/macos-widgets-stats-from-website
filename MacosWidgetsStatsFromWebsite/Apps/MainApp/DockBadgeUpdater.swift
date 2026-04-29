//
//  DockBadgeUpdater.swift
//  MacosWidgetsStatsFromWebsite
//
//  Mirrors broken tracker count into the Dock badge.
//

import AppKit

enum DockBadgeUpdater {
    static func update() {
        let activeTrackerIDs = Set(AppGroupStore.loadSharedConfiguration().trackers.map { $0.id.uuidString })
        let brokenCount = AppGroupStore.loadReadings().readings.filter { id, reading in
            activeTrackerIDs.contains(id) && reading.status == .broken
        }.count

        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = brokenCount > 0 ? "\(brokenCount)" : nil
        }
    }
}
