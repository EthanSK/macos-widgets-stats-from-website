//
//  BackgroundScheduler.swift
//  MacosWidgetsStatsFromWebsite
//
//  NSBackgroundActivityScheduler wrapper for app-owned scraping.
//

import Foundation
import WidgetKit

final class BackgroundScheduler: ObservableObject {
    private let store: AppGroupStore
    private var schedulers: [UUID: NSBackgroundActivityScheduler] = [:]
    private var activeTrackerIDs: Set<UUID> = []
    private var notifiedBrokenTrackerIDs: Set<UUID> = []
    private lazy var snapshotSessions = SnapshotSessionManager(
        onReading: { [weak self] tracker, reading in
            self?.record(result: .success(reading), for: tracker)
        },
        onFailure: { [weak self] tracker, error in
            self?.record(result: .failure(error), for: tracker)
        }
    )

    init(store: AppGroupStore) {
        self.store = store
    }

    func sync() {
        let trackers = store.trackers
        let textTrackers = trackers.filter { $0.renderMode == .text }
        let trackerIDs = Set(textTrackers.map(\.id))

        for removedID in activeTrackerIDs.subtracting(trackerIDs) {
            schedulers[removedID]?.invalidate()
            schedulers[removedID] = nil
        }

        for tracker in textTrackers {
            schedule(tracker)
        }

        activeTrackerIDs = trackerIDs
        snapshotSessions.sync(
            trackers: trackers,
            concurrencyCap: store.preferences.snapshotConcurrencyCap
        )
    }

    func triggerScrapeNow(trackerID: UUID) {
        guard let tracker = store.trackers.first(where: { $0.id == trackerID }) else {
            return
        }

        if tracker.renderMode == .snapshot {
            snapshotSessions.triggerSnapshotNow(
                tracker: tracker,
                concurrencyCap: store.preferences.snapshotConcurrencyCap
            )
        } else {
            scrape(tracker)
        }
    }

    private func schedule(_ tracker: Tracker) {
        let identifier = "com.ethansk.macos-widgets-stats-from-website.scrape.\(tracker.id.uuidString)"
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
            self.record(result: result, for: tracker)
            completion?()
        }
    }

    private func record(result: Result<TrackerReading, Error>, for tracker: Tracker) {
        do {
            let recordedReading: TrackerReading
            switch result {
            case .success(let reading):
                try AppGroupStore.record(reading: reading, for: tracker)
                recordedReading = reading
            case .failure(let error):
                recordedReading = try AppGroupStore.recordFailure(message: error.localizedDescription, for: tracker)
            }
            handlePostRecord(reading: recordedReading, tracker: tracker)
            DockBadgeUpdater.update()
            WidgetCenter.shared.reloadTimelines(ofKind: "MacosWidgetsStatsFromWebsite")
        } catch {
            // The Preferences UI surfaces configuration persistence errors;
            // scrape write failures are transient and retried by the scheduler.
        }
    }

    private func handlePostRecord(reading: TrackerReading, tracker: Tracker) {
        if reading.status == .ok {
            notifiedBrokenTrackerIDs.remove(tracker.id)
            return
        }

        let failureCount = reading.consecutiveFailureCount ?? 0
        guard failureCount >= 3, !notifiedBrokenTrackerIDs.contains(tracker.id) else {
            return
        }

        notifiedBrokenTrackerIDs.insert(tracker.id)
        HealNotifier.shared.notifyBrokenTracker(tracker, failureCount: failureCount)
    }
}
