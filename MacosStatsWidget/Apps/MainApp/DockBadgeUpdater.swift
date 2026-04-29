//
//  DockBadgeUpdater.swift
//  MacosStatsWidget
//
//  Mirrors broken tracker count into the Dock badge.
//

import AppKit

enum DockBadgeUpdater {
    static func update() {
        let brokenCount = AppGroupStore.loadReadings().readings.values.filter { $0.status == .broken }.count
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = brokenCount > 0 ? "\(brokenCount)" : nil
        }
    }
}
