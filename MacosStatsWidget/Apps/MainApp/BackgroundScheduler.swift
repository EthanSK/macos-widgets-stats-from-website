//
//  BackgroundScheduler.swift
//  MacosStatsWidget
//
//  NSBackgroundActivityScheduler wrapper for app-owned scraping.
//

import Foundation
import WidgetKit

final class BackgroundScheduler: ObservableObject {
    private let store: AppGroupStore
    private var schedulers: [UUID: NSBackgroundActivityScheduler] = [:]
    private var activeTrackerIDs: Set<UUID> = []

    init(store: AppGroupStore) {
        self.store = store
    }

    func sync() {
        let trackers = store.trackers
        let trackerIDs = Set(trackers.map(\.id))

        for removedID in activeTrackerIDs.subtracting(trackerIDs) {
            schedulers[removedID]?.invalidate()
            schedulers[removedID] = nil
        }

        for tracker in trackers {
            schedule(tracker)
        }

        activeTrackerIDs = trackerIDs
    }

    func triggerScrapeNow(trackerID: UUID) {
        guard let tracker = store.trackers.first(where: { $0.id == trackerID }) else {
            return
        }

        scrape(tracker)
    }

    private func schedule(_ tracker: Tracker) {
        let identifier = "com.ethansk.macos-stats-widget.scrape.\(tracker.id.uuidString)"
        let scheduler = schedulers[tracker.id] ?? NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.invalidate()
        scheduler.interval = TimeInterval(max(60, tracker.refreshIntervalSec))
        scheduler.tolerance = TimeInterval(max(30, tracker.refreshIntervalSec / 5))
        scheduler.repeats = true
        schedulers[tracker.id] = scheduler

        scheduler.schedule { [weak self] completion in
            guard let self,
                  let currentTracker = store.trackers.first(where: { $0.id == tracker.id }) else {
                completion(.finished)
                return
            }

            scrape(currentTracker) {
                completion(.finished)
            }
        }
    }

    private func scrape(_ tracker: Tracker, completion: (() -> Void)? = nil) {
        WKWebViewScraper.scrape(tracker: tracker) { result in
            do {
                switch result {
                case .success(let reading):
                    try AppGroupStore.record(reading: reading, for: tracker)
                case .failure(let error):
                    try AppGroupStore.recordFailure(message: error.localizedDescription, for: tracker)
                }
                WidgetCenter.shared.reloadTimelines(ofKind: "MacosStatsWidget")
            } catch {
                // The Preferences UI surfaces configuration persistence errors;
                // scrape write failures are transient and retried by the scheduler.
            }
            completion?()
        }
    }
}
