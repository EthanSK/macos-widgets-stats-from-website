//
//  WKWebViewScraper.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Headless WKWebView scraper for Text and one-shot Snapshot mode.
//

import AppKit
import Foundation
import WebKit

enum WKWebViewScraperError: LocalizedError {
    case invalidURL
    case navigationFailed(String)
    case selectorDidNotMatch
    case selectedElementHasNoText
    case selectedElementHasNoVisibleRect
    case snapshotEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Tracker URL is not a valid http or https URL."
        case .navigationFailed(let message):
            return message
        case .selectorDidNotMatch:
            return "Selector did not match any element."
        case .selectedElementHasNoText:
            return "Selected element has no text."
        case .selectedElementHasNoVisibleRect:
            return "Selected element has no visible rect."
        case .snapshotEncodingFailed:
            return "Snapshot image could not be encoded as PNG."
        }
    }
}

final class WKWebViewScraper: NSObject, WKNavigationDelegate {
    typealias Completion = (Result<TrackerReading, Error>) -> Void

    private static var activeScrapers: [UUID: WKWebViewScraper] = [:]

    private let scrapeID = UUID()
    private let tracker: Tracker
    private let completion: Completion
    private var webView: WKWebView?
    private var timeout: Timer?
    private var didComplete = false

    static func scrape(tracker: Tracker, completion: @escaping Completion) {
        DispatchQueue.main.async {
            let scraper = WKWebViewScraper(tracker: tracker, completion: completion)
            activeScrapers[scraper.scrapeID] = scraper
            scraper.start()
        }
    }

    private init(tracker: Tracker, completion: @escaping Completion) {
        self.tracker = tracker
        self.completion = completion
    }

    private func start() {
        guard let url = validatedURL(from: tracker.url) else {
            finish(.failure(WKWebViewScraperError.invalidURL))
            return
        }

        let frame = initialFrame(for: tracker)
        let webView = WebViewProfile.shared.makeWebView(frame: frame)
        webView.navigationDelegate = self
        self.webView = webView
        timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.finish(.failure(WKWebViewScraperError.navigationFailed("Timed out loading \(url.host ?? url.absoluteString).")))
        }
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeout?.invalidate()

        SelectorRunner.waitForSelector(in: webView, selector: tracker.selector) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success(let status):
                switch self.tracker.renderMode {
                case .text:
                    self.scrapeText(from: status)
                case .snapshot:
                    self.scrapeSnapshot(in: webView)
                }
            case .failure(let error):
                self.finish(.failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WKWebViewScraperError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WKWebViewScraperError.navigationFailed(error.localizedDescription)))
    }

    private func scrapeText(from status: [String: Any]) {
        let value = (status["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            finish(.failure(WKWebViewScraperError.selectedElementHasNoText))
            return
        }

        let reading = TrackerReading(
            currentValue: value,
            currentNumeric: tracker.valueParser.parseNumeric(from: value),
            lastUpdatedAt: Date(),
            status: .ok
        )
        finish(.success(reading))
    }

    private func scrapeSnapshot(in webView: WKWebView) {
        webView.evaluateJavaScript(SelectorExtractionJS.snapshotRectScript(for: tracker.selector, hideElements: tracker.hideElements)) { [weak self] result, error in
            guard let self else {
                return
            }

            if let error {
                finish(.failure(error))
                return
            }

            let resolvedRect = SelectorExtractionJS.rect(from: result)
            let fallbackRect = tracker.elementBoundingBox.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            guard let rect = resolvedRect ?? fallbackRect,
                  rect.width > 0,
                  rect.height > 0 else {
                finish(.failure(WKWebViewScraperError.selectedElementHasNoVisibleRect))
                return
            }

            takeSnapshot(of: rect, in: webView)
        }
    }

    private func takeSnapshot(of rect: CGRect, in webView: WKWebView) {
        let clampedRect = rect.intersection(webView.bounds)
        guard !clampedRect.isNull, clampedRect.width > 0, clampedRect.height > 0 else {
            finish(.failure(WKWebViewScraperError.selectedElementHasNoVisibleRect))
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = clampedRect.integral
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self else {
                return
            }

            if let error {
                finish(.failure(error))
                return
            }

            guard let image, let data = pngData(from: image) else {
                finish(.failure(WKWebViewScraperError.snapshotEncodingFailed))
                return
            }

            do {
                let cacheKey = try SnapshotSharedCache.shared.store(data, for: tracker.id)
                let now = Date()
                let reading = TrackerReading(
                    snapshotCacheKey: cacheKey,
                    snapshotCapturedAt: now,
                    lastUpdatedAt: now,
                    status: .ok
                )
                finish(.success(reading))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<TrackerReading, Error>) {
        guard !didComplete else {
            return
        }

        didComplete = true
        timeout?.invalidate()
        webView?.navigationDelegate = nil
        webView = nil
        completion(result)
        Self.activeScrapers[scrapeID] = nil
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

    private func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

}
