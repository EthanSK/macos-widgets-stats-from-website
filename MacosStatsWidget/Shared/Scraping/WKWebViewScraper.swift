//
//  WKWebViewScraper.swift
//  MacosStatsWidgetShared
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
    case snapshotWriteUnavailable

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
        case .snapshotWriteUnavailable:
            return "Snapshot path is unavailable."
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
        let webView = WKWebView(frame: frame, configuration: WebViewProfile.shared.makeConfiguration())
        webView.navigationDelegate = self
        self.webView = webView
        timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.finish(.failure(WKWebViewScraperError.navigationFailed("Timed out loading \(url.host ?? url.absoluteString).")))
        }
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeout?.invalidate()

        switch tracker.renderMode {
        case .text:
            scrapeText(in: webView)
        case .snapshot:
            scrapeSnapshot(in: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WKWebViewScraperError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WKWebViewScraperError.navigationFailed(error.localizedDescription)))
    }

    private func scrapeText(in webView: WKWebView) {
        webView.evaluateJavaScript(textExtractionScript(for: tracker.selector)) { [weak self] result, error in
            guard let self else {
                return
            }

            if let error {
                finish(.failure(error))
                return
            }

            guard let dictionary = result as? [String: Any] else {
                finish(.failure(WKWebViewScraperError.selectorDidNotMatch))
                return
            }

            if let ok = dictionary["ok"] as? Bool, ok == false {
                finish(.failure(WKWebViewScraperError.selectorDidNotMatch))
                return
            }

            let value = (dictionary["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    private func scrapeSnapshot(in webView: WKWebView) {
        webView.evaluateJavaScript(snapshotRectScript(for: tracker.selector, hideElements: tracker.hideElements)) { [weak self] result, error in
            guard let self else {
                return
            }

            if let error {
                finish(.failure(error))
                return
            }

            let resolvedRect = rect(from: result)
            let fallbackRect = tracker.elementBoundingBox.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            guard let rect = resolvedRect ?? fallbackRect,
                  rect.width > 0,
                  rect.height > 0 else {
                finish(.failure(WKWebViewScraperError.selectedElementHasNoVisibleRect))
                return
            }

            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect.integral
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

                guard let snapshotURL = AppGroupPaths.snapshotURL(for: tracker.id) else {
                    finish(.failure(WKWebViewScraperError.snapshotWriteUnavailable))
                    return
                }

                do {
                    try FileManager.default.createDirectory(
                        at: snapshotURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try data.write(to: snapshotURL, options: .atomic)
                    let now = Date()
                    let reading = TrackerReading(
                        snapshotPath: AppGroupPaths.relativeSnapshotPath(for: tracker.id),
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

    private func textExtractionScript(for selector: String) -> String {
        let selectorLiteral = javaScriptStringLiteral(selector)
        return """
        (() => {
          const element = document.querySelector(\(selectorLiteral));
          if (!element) {
            return { ok: false };
          }
          return {
            ok: true,
            text: String(element.innerText || element.textContent || '').trim()
          };
        })()
        """
    }

    private func snapshotRectScript(for selector: String, hideElements: [String]) -> String {
        let selectorLiteral = javaScriptStringLiteral(selector)
        let hideElementsLiteral = javaScriptArrayLiteral(hideElements)
        return """
        (() => {
          for (const selector of \(hideElementsLiteral)) {
            try {
              document.querySelectorAll(selector).forEach(element => {
                element.setAttribute('data-stats-widget-hidden', 'true');
                element.style.visibility = 'hidden';
              });
            } catch (_) {}
          }
          const element = document.querySelector(\(selectorLiteral));
          if (!element) {
            return null;
          }
          const rect = element.getBoundingClientRect();
          return {
            x: rect.left,
            y: rect.top,
            width: rect.width,
            height: rect.height
          };
        })()
        """
    }

    private func rect(from value: Any?) -> CGRect? {
        guard let dictionary = value as? [String: Any],
              let x = doubleValue(dictionary["x"]),
              let y = doubleValue(dictionary["y"]),
              let width = doubleValue(dictionary["width"]),
              let height = doubleValue(dictionary["height"]) else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }

        return literal
    }

    private func javaScriptArrayLiteral(_ value: [String]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return literal
    }
}
