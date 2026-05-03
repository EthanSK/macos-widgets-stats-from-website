//
//  IdentifyElementCoordinator.swift
//  MacosWidgetsStatsFromWebsite
//
//  WebKit script-message bridge for the Identify Element flow.
//

import AppKit
import Foundation
import WebKit

struct ElementPick: Equatable {
    var selector: String
    var text: String
    var bbox: ElementBoundingBox
}

struct ElementCapturePreview: Identifiable {
    let id = UUID()
    var pick: ElementPick
    var snapshot: NSImage?
}

final class IdentifyElementCoordinator: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var renderMode: RenderMode

    private var onPreviewReady: (ElementCapturePreview) -> Void
    private var onError: (String) -> Void
    private var isValidatingPick = false

    init(
        renderMode: RenderMode,
        onPreviewReady: @escaping (ElementCapturePreview) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.renderMode = renderMode
        self.onPreviewReady = onPreviewReady
        self.onError = onError
    }

    func setCallbacks(
        onPreviewReady: @escaping (ElementCapturePreview) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.onPreviewReady = onPreviewReady
        self.onError = onError
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.userContentController(userContentController, didReceive: message)
            }
            return
        }

        switch message.name {
        case "elementPicked":
            guard !isValidatingPick else {
                return
            }

            guard let pick = decodePick(from: message.body) else {
                failAndRearm("The selected element payload was not readable.")
                return
            }

            validate(pick)
        case "inspectError":
            onError(errorMessage(from: message.body))
            rearmOverlay()
        default:
            break
        }
    }

    private func validate(_ pick: ElementPick) {
        guard let webView else {
            onError("The browser is no longer available.")
            return
        }

        let selector = pick.selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else {
            failAndRearm("The selected element did not produce a CSS selector.")
            return
        }

        isValidatingPick = true
        webView.evaluateJavaScript(SelectorExtractionJS.validationScript(for: selector)) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handleValidationResult(result, error: error, originalPick: pick)
            }
        }
    }

    private func handleValidationResult(_ result: Any?, error: Error?, originalPick: ElementPick) {
        guard error == nil else {
            failAndRearm("The selector could not be validated: \(error?.localizedDescription ?? "Unknown error").")
            return
        }

        guard let validation = SelectorExtractionJS.dictionary(from: result) else {
            failAndRearm("The selector validation result was not readable.")
            return
        }

        if let scriptError = validation["error"] as? String, !scriptError.isEmpty {
            failAndRearm("The selector is invalid: \(scriptError)")
            return
        }

        let matchCount = SelectorExtractionJS.intValue(validation["count"]) ?? 0
        guard matchCount == 1 else {
            failAndRearm("The selector matches \(matchCount) elements; choose a more specific element.")
            return
        }

        var finalPick = originalPick
        if let validatedText = validation["text"] as? String {
            finalPick.text = validatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let bbox = SelectorExtractionJS.elementBoundingBox(from: validation["bbox"]) {
            finalPick.bbox = bbox
        }

        switch renderMode {
        case .text:
            guard !finalPick.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failAndRearm("The selected element has no text to extract.")
                return
            }
        case .snapshot:
            guard finalPick.bbox.width * finalPick.bbox.height > 0 else {
                failAndRearm("The selected element has no visible area to snapshot.")
                return
            }
        }

        isValidatingPick = false
        dismissOverlay()
        makePreview(for: finalPick)
    }

    private func makePreview(for pick: ElementPick) {
        guard let webView else {
            onPreviewReady(ElementCapturePreview(pick: pick, snapshot: nil))
            return
        }

        webView.evaluateJavaScript(SelectorExtractionJS.snapshotRectScript(for: pick.selector, hideElements: [])) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                let resolvedRect = SelectorExtractionJS.rect(from: result)
                let fallbackRect = self.snapshotRect(for: pick.bbox, in: webView)
                guard let rect = self.clampedSnapshotRect(resolvedRect ?? fallbackRect, in: webView) else {
                    self.onPreviewReady(ElementCapturePreview(pick: pick, snapshot: nil))
                    return
                }

                let configuration = WKSnapshotConfiguration()
                configuration.rect = rect.integral
                webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                    DispatchQueue.main.async {
                        self?.onPreviewReady(ElementCapturePreview(pick: pick, snapshot: image))
                    }
                }
            }
        }
    }

    private func clampedSnapshotRect(_ rect: CGRect?, in webView: WKWebView) -> CGRect? {
        guard let rect, rect.width > 0, rect.height > 0 else {
            return nil
        }

        let clamped = rect.intersection(webView.bounds)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            return nil
        }

        return clamped
    }

    private func snapshotRect(for bbox: ElementBoundingBox, in webView: WKWebView) -> CGRect? {
        let rect = CGRect(x: bbox.x, y: bbox.y, width: bbox.width, height: bbox.height)
        guard rect.width > 0, rect.height > 0 else {
            return nil
        }

        let bounds = webView.bounds
        let clamped = rect.intersection(bounds)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            return nil
        }

        return clamped
    }

    private func failAndRearm(_ message: String) {
        isValidatingPick = false
        onError(message)
        rearmOverlay()
    }

    private func rearmOverlay() {
        webView?.evaluateJavaScript(InspectOverlayJS.inspectOverlayJS) { [weak self] _, error in
            guard let error else {
                return
            }
            DispatchQueue.main.async {
                self?.onError("Identify Element could not restart: \(error.localizedDescription)")
            }
        }
    }

    private func dismissOverlay() {
        webView?.evaluateJavaScript("window.__statsWidgetInspectCleanup && window.__statsWidgetInspectCleanup();", completionHandler: nil)
    }


    private func errorMessage(from body: Any) -> String {
        if let dictionary = SelectorExtractionJS.dictionary(from: body), let message = dictionary["message"] as? String {
            return message
        }

        if let message = body as? String {
            return message
        }

        return "Identify Element reported an unknown error."
    }

    private func decodePick(from body: Any) -> ElementPick? {
        guard let dictionary = SelectorExtractionJS.dictionary(from: body),
              let selector = dictionary["selector"] as? String,
              let text = dictionary["text"] as? String,
              let bbox = SelectorExtractionJS.elementBoundingBox(from: dictionary["bbox"]) else {
            return nil
        }

        return ElementPick(selector: selector, text: text, bbox: bbox)
    }

}
