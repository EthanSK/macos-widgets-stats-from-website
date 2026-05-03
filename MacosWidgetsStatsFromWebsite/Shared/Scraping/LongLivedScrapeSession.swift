//
//  LongLivedScrapeSession.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Long-lived WKWebView sessions for Snapshot-mode polling.
//

import AppKit
import Foundation
import WebKit

final class SnapshotSessionManager {
    private var sessions: [UUID: LongLivedScrapeSession] = [:]
    private var lastRenderedAt: [UUID: Date] = [:]

    private let onReading: (Tracker, TrackerReading) -> Void
    private let onFailure: (Tracker, Error) -> Void

    init(
        onReading: @escaping (Tracker, TrackerReading) -> Void,
        onFailure: @escaping (Tracker, Error) -> Void
    ) {
        self.onReading = onReading
        self.onFailure = onFailure
    }

    func sync(trackers: [Tracker], concurrencyCap: Int) {
        DispatchQueue.main.async {
            let snapshotTrackers = trackers.filter { $0.renderMode == .snapshot }
            let snapshotIDs = Set(snapshotTrackers.map(\.id))

            for id in self.sessions.keys where !snapshotIDs.contains(id) {
                self.stopSession(id: id)
            }

            let cap = self.normalizedCap(concurrencyCap)
            let activeIDs = Set(snapshotTrackers.prefix(cap).map(\.id))
            for id in self.sessions.keys where !activeIDs.contains(id) {
                self.stopSession(id: id)
            }

            for tracker in snapshotTrackers.prefix(cap) {
                self.startOrUpdate(tracker)
            }
        }
    }

    func triggerSnapshotNow(tracker: Tracker, concurrencyCap: Int) {
        DispatchQueue.main.async {
            self.evictIfNeeded(concurrencyCap: self.normalizedCap(concurrencyCap), protectedID: tracker.id)
            self.startOrUpdate(tracker)
            self.sessions[tracker.id]?.snapshotNow()
        }
    }

    func stop(trackerID: UUID) {
        DispatchQueue.main.async {
            self.stopSession(id: trackerID)
        }
    }

    func stopAll() {
        DispatchQueue.main.async {
            for id in Array(self.sessions.keys) {
                self.stopSession(id: id)
            }
        }
    }

    private func startOrUpdate(_ tracker: Tracker) {
        if let session = sessions[tracker.id] {
            session.update(tracker: tracker)
            return
        }

        let session = LongLivedScrapeSession(
            tracker: tracker,
            onReading: { [weak self] tracker, reading in
                self?.lastRenderedAt[tracker.id] = Date()
                self?.onReading(tracker, reading)
            },
            onFailure: onFailure
        )
        sessions[tracker.id] = session
        session.start()
    }

    private func evictIfNeeded(concurrencyCap: Int, protectedID: UUID) {
        guard sessions.count >= concurrencyCap else {
            return
        }

        let evictionCandidate = sessions.keys
            .filter { $0 != protectedID }
            .min { lhs, rhs in
                (lastRenderedAt[lhs] ?? .distantPast) < (lastRenderedAt[rhs] ?? .distantPast)
            }

        if let evictionCandidate {
            stopSession(id: evictionCandidate)
        }
    }

    private func stopSession(id: UUID) {
        sessions[id]?.stop()
        sessions[id] = nil
        lastRenderedAt[id] = nil
        SnapshotSharedCache.shared.remove(for: id)
    }

    private func normalizedCap(_ concurrencyCap: Int) -> Int {
        max(1, min(8, concurrencyCap))
    }
}

final class LongLivedScrapeSession: NSObject, WKNavigationDelegate {
    private var tracker: Tracker
    private let onReading: (Tracker, TrackerReading) -> Void
    private let onFailure: (Tracker, Error) -> Void

    private var webView: WKWebView?
    private var snapshotTimer: Timer?
    private var heartbeatTimer: Timer?
    private var loadTimeout: Timer?
    private var cachedRect: CGRect?
    private var snapshotInFlight = false
    private var isLoaded = false
    private var pendingSnapshot = false

    init(
        tracker: Tracker,
        onReading: @escaping (Tracker, TrackerReading) -> Void,
        onFailure: @escaping (Tracker, Error) -> Void
    ) {
        self.tracker = tracker
        self.onReading = onReading
        self.onFailure = onFailure
        if let bbox = tracker.elementBoundingBox {
            cachedRect = CGRect(x: bbox.x, y: bbox.y, width: bbox.width, height: bbox.height)
        }
    }

    deinit {
        stop()
    }

    func start() {
        runOnMain { [weak self] in
            self?.loadInitialPage()
        }
    }

    func update(tracker newTracker: Tracker) {
        runOnMain { [weak self] in
            guard let self else {
                return
            }

            let previousURL = tracker.url
            let previousSnapshotInterval = snapshotInterval(for: tracker)
            tracker = newTracker
            if let bbox = newTracker.elementBoundingBox {
                cachedRect = CGRect(x: bbox.x, y: bbox.y, width: bbox.width, height: bbox.height)
            }

            if previousURL != newTracker.url {
                loadInitialPage()
            } else if previousSnapshotInterval != snapshotInterval(for: newTracker) {
                snapshotTimer?.invalidate()
                snapshotTimer = nil
                if isLoaded {
                    scheduleTimers()
                }
            }
        }
    }

    func stop() {
        runOnMain { [weak self] in
            guard let self else {
                return
            }

            snapshotTimer?.invalidate()
            heartbeatTimer?.invalidate()
            loadTimeout?.invalidate()
            snapshotTimer = nil
            heartbeatTimer = nil
            loadTimeout = nil
            webView?.navigationDelegate = nil
            webView?.stopLoading()
            webView = nil
            isLoaded = false
            snapshotInFlight = false
            pendingSnapshot = false
        }
    }

    func snapshotNow() {
        runOnMain { [weak self] in
            guard let self else {
                return
            }

            guard isLoaded, let webView else {
                pendingSnapshot = true
                return
            }

            guard !snapshotInFlight else {
                pendingSnapshot = true
                return
            }

            snapshotInFlight = true
            pendingSnapshot = false
            resolveRect(in: webView)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadTimeout?.invalidate()
        SelectorRunner.waitForSelector(in: webView, selector: tracker.selector) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success:
                self.isLoaded = true
                self.scheduleTimers()
                self.snapshotNow()
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func loadInitialPage() {
        guard let url = validatedURL(from: tracker.url) else {
            fail(WKWebViewScraperError.invalidURL)
            return
        }

        snapshotTimer?.invalidate()
        heartbeatTimer?.invalidate()
        loadTimeout?.invalidate()
        isLoaded = false
        snapshotInFlight = false
        pendingSnapshot = false

        let frame = initialFrame(for: tracker)
        let webView = webView ?? WebViewProfile.shared.makeWebView(frame: frame)
        webView.frame = frame
        webView.navigationDelegate = self
        self.webView = webView

        loadTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.fail(WKWebViewScraperError.navigationFailed("Timed out loading \(url.host ?? url.absoluteString)."))
        }
        webView.load(URLRequest(url: url))
    }

    private func scheduleTimers() {
        if snapshotTimer == nil {
            let interval = snapshotInterval(for: tracker)
            snapshotTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.snapshotNow()
            }
            snapshotTimer?.tolerance = min(max(interval * 0.1, 0.2), 60)
        }

        if heartbeatTimer == nil {
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
                self?.reloadForHeartbeat()
            }
            heartbeatTimer?.tolerance = 60
        }
    }

    private func snapshotInterval(for tracker: Tracker) -> TimeInterval {
        TimeInterval(max(1, tracker.refreshIntervalSec))
    }

    private func reloadForHeartbeat() {
        guard let webView else {
            loadInitialPage()
            return
        }

        isLoaded = false
        snapshotInFlight = false
        pendingSnapshot = true
        webView.reload()
    }

    private func resolveRect(in webView: WKWebView) {
        webView.evaluateJavaScript(SelectorExtractionJS.snapshotRectScript(for: tracker.selector, hideElements: tracker.hideElements)) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    self.finishSnapshotFailure(error)
                    return
                }

                guard let rect = SelectorExtractionJS.rect(from: result),
                      rect.width > 0,
                      rect.height > 0 else {
                    self.finishSnapshotFailure(WKWebViewScraperError.selectedElementHasNoVisibleRect)
                    return
                }

                self.cachedRect = rect
                self.takeSnapshot(of: rect, in: webView)
            }
        }
    }

    private func takeSnapshot(of rect: CGRect, in webView: WKWebView) {
        let clampedRect = rect.intersection(webView.bounds)
        guard !clampedRect.isNull, clampedRect.width > 0, clampedRect.height > 0 else {
            finishSnapshotFailure(WKWebViewScraperError.selectedElementHasNoVisibleRect)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = clampedRect.integral
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    self.finishSnapshotFailure(error)
                    return
                }

                guard let image, let data = self.pngData(from: image) else {
                    self.finishSnapshotFailure(WKWebViewScraperError.snapshotEncodingFailed)
                    return
                }

                do {
                    let cacheKey = try SnapshotSharedCache.shared.store(data, for: self.tracker.id)
                    let now = Date()
                    let reading = TrackerReading(
                        snapshotCacheKey: cacheKey,
                        snapshotCapturedAt: now,
                        lastUpdatedAt: now,
                        status: .ok
                    )
                    self.snapshotInFlight = false
                    self.onReading(self.tracker, reading)
                    if self.pendingSnapshot {
                        self.snapshotNow()
                    }
                } catch {
                    self.finishSnapshotFailure(error)
                }
            }
        }
    }

    private func finishSnapshotFailure(_ error: Error) {
        snapshotInFlight = false
        pendingSnapshot = false
        fail(error)
    }

    private func fail(_ error: Error) {
        loadTimeout?.invalidate()
        onFailure(tracker, error)
    }

    private func validatedURL(from string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }

        return url
    }

    private func initialFrame(for tracker: Tracker) -> CGRect {
        if let bbox = tracker.elementBoundingBox {
            return CGRect(
                x: 0,
                y: 0,
                width: max(320, bbox.viewportWidth),
                height: max(240, bbox.viewportHeight)
            )
        }

        return CGRect(x: 0, y: 0, width: 1280, height: 800)
    }


    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

}
