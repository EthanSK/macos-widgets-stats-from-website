//
//  InAppBrowserView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Visible WKWebView browser used for sign-in and element capture.
//

import AppKit
import SwiftUI
import WebKit

struct InAppBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: InAppBrowserController

    private let allowsElementIdentification: Bool
    private let onElementCaptured: ((ElementPick) -> Void)?

    init(
        initialURL: URL? = nil,
        renderMode: RenderMode = .text,
        allowsElementIdentification: Bool = true,
        onElementCaptured: ((ElementPick) -> Void)? = nil
    ) {
        _controller = StateObject(wrappedValue: InAppBrowserController(initialURL: initialURL, renderMode: renderMode))
        self.allowsElementIdentification = allowsElementIdentification
        self.onElementCaptured = onElementCaptured
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let inlineError = controller.inlineError {
                Text(inlineError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            if let siteCompatibilityMessage = controller.siteCompatibilityMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(siteCompatibilityMessage)
                    Spacer()
                    Button("Open in Browser") {
                        controller.openCurrentURLInDefaultBrowser()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            Divider()
            WebViewHost(webView: controller.webView)
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(item: $controller.preview) { preview in
            ElementCapturePreviewSheet(
                preview: preview,
                onUse: {
                    controller.preview = nil
                    onElementCaptured?(preview.pick)
                    dismiss()
                },
                onRetry: {
                    controller.preview = nil
                    controller.startIdentifying()
                }
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                controller.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!controller.canGoBack)
            .help("Back")

            Button {
                controller.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!controller.canGoForward)
            .help("Forward")

            Button {
                controller.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")

            TextField("https://example.com", text: $controller.urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    controller.loadURLFromBar()
                }

            Button {
                controller.loadURLFromBar()
            } label: {
                Image(systemName: "arrow.right")
            }
            .help("Go")

            Button {
                controller.openCurrentURLInDefaultBrowser()
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .disabled(controller.currentURLForExternalOpen == nil)
            .help("Open the current page in your default browser")

            if allowsElementIdentification {
                Button {
                    if controller.isIdentifying {
                        controller.cancelIdentifying()
                    } else {
                        controller.startIdentifying()
                    }
                } label: {
                    Label(
                        controller.isIdentifying ? "Cancel Identify" : "Identify Element",
                        systemImage: controller.isIdentifying ? "xmark.circle" : "viewfinder"
                    )
                }
                .help(controller.isIdentifying ? "Cancel Identify Element" : "Identify Element")
            }
        }
        .padding(8)
    }
}

private final class InAppBrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView

    @Published var urlText: String
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var isIdentifying = false
    @Published var inlineError: String?
    @Published var siteCompatibilityMessage: String?
    @Published var preview: ElementCapturePreview?

    var currentURLForExternalOpen: URL? {
        webView.url ?? URL(string: urlText)
    }

    private let userContentController: WKUserContentController
    private let identifyCoordinator: IdentifyElementCoordinator
    private var observations: [NSKeyValueObservation] = []

    init(initialURL: URL?, renderMode: RenderMode) {
        urlText = initialURL?.absoluteString ?? ""
        userContentController = WKUserContentController()
        identifyCoordinator = IdentifyElementCoordinator(
            renderMode: renderMode,
            onPreviewReady: { _ in },
            onError: { _ in }
        )

        userContentController.add(identifyCoordinator, name: "elementPicked")
        userContentController.add(identifyCoordinator, name: "inspectError")
        webView = WebViewProfile.shared.makeWebView(frame: .zero, userContentController: userContentController)

        super.init()

        identifyCoordinator.webView = webView
        identifyCoordinator.renderMode = renderMode
        identifyCoordinator.setCallbacks(
            onPreviewReady: { [weak self] preview in
                self?.isIdentifying = false
                self?.inlineError = nil
                self?.preview = preview
            },
            onError: { [weak self] message in
                self?.inlineError = message
                self?.isIdentifying = true
            }
        )

        webView.navigationDelegate = self
        webView.uiDelegate = self
        installObservers()

        if let initialURL {
            load(initialURL)
        }
    }

    deinit {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        userContentController.removeScriptMessageHandler(forName: "elementPicked")
        userContentController.removeScriptMessageHandler(forName: "inspectError")
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        if webView.url == nil {
            loadURLFromBar()
        } else {
            webView.reload()
        }
    }

    func loadURLFromBar() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inlineError = "Enter a URL to load."
            return
        }

        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            inlineError = "Enter a valid http or https URL."
            return
        }

        load(url)
    }

    func load(_ url: URL) {
        inlineError = nil
        urlText = url.absoluteString
        updateSiteCompatibilityMessage(for: url)
        webView.load(URLRequest(url: url))
    }

    func openCurrentURLInDefaultBrowser() {
        guard let url = currentURLForExternalOpen else {
            inlineError = "Load a page before opening it in your browser."
            return
        }

        openExternalURL(url)
    }

    func startIdentifying() {
        guard webView.url != nil else {
            inlineError = "Load a page before identifying an element."
            return
        }

        inlineError = nil
        preview = nil
        isIdentifying = true
        webView.evaluateJavaScript(InspectOverlayJS.inspectOverlayJS) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let error else {
                    return
                }
                self?.isIdentifying = false
                self?.inlineError = "Identify Element could not start: \(error.localizedDescription)"
            }
        }
    }

    func cancelIdentifying() {
        isIdentifying = false
        webView.evaluateJavaScript("window.__statsWidgetInspectCleanup && window.__statsWidgetInspectCleanup();", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        inlineError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if let url = webView.url {
            urlText = url.absoluteString
            updateSiteCompatibilityMessage(for: url)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        guard !isBenignNavigationCancellation(error) else {
            return
        }
        inlineError = browserErrorMessage(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        guard !isBenignNavigationCancellation(error) else {
            return
        }
        inlineError = browserErrorMessage(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        inlineError = "The web content process quit unexpectedly. Reloading the page…"
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "data", "blob"].contains(scheme) {
            openExternalURL(url)
            decisionHandler(.cancel)
            return
        }

        if shouldOpenExternallyForProviderCompatibility(url) {
            siteCompatibilityMessage = "Google sign-in was opened in your default browser because Google blocks embedded app browsers. Finish the sign-in there, then return here; if the provider does not sync cookies back to this app, use a non-Google sign-in path for this tracker."
            openExternalURL(url)
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        updateSiteCompatibilityMessage(for: url)
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website message"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website confirmation"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website prompt"
        alert.informativeText = prompt
        let textField = NSTextField(string: defaultText ?? "")
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = textField
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? textField.stringValue : nil)
    }

    private func updateSiteCompatibilityMessage(for url: URL) {
        guard let host = url.host?.lowercased() else {
            siteCompatibilityMessage = nil
            return
        }

        if isGoogleSignInHost(host) {
            siteCompatibilityMessage = "Google sign-in cannot run inside this embedded browser, so the app opens it in your default browser instead of showing Google's unsupported embedded-browser error."
        } else if host == "claude.ai" || host.hasSuffix(".claude.ai") || host == "anthropic.com" || host.hasSuffix(".anthropic.com") {
            siteCompatibilityMessage = "Claude/Anthropic sign-in may reject embedded browsers or require OAuth/passkey steps in your default browser. Google sign-in is automatically handed off to your default browser to avoid Google's unsupported embedded-browser error."
        } else {
            siteCompatibilityMessage = nil
        }
    }

    private func shouldOpenExternallyForProviderCompatibility(_ url: URL) -> Bool {
        // 2026-05-02: deflection retired now that the Phase-0 Safari UA-spoof (commit da26be2)
        // flips Google's classifier from WebLiteSignIn to GlifWebSignIn. If Google tightens
        // detection later, restore this gating.
        _ = url
        return false
    }

    private func isGoogleSignInHost(_ host: String) -> Bool {
        host == "accounts.google.com"
            || host.hasSuffix(".accounts.google.com")
            || host == "signin.google.com"
            || host.hasSuffix(".signin.google.com")
            || host == "accounts.youtube.com"
            || host.hasSuffix(".accounts.youtube.com")
    }

    private func openExternalURL(_ url: URL) {
        guard ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_SUPPRESS_EXTERNAL_BROWSER_OPEN"] != "1" else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func browserErrorMessage(_ error: Error) -> String {
        "Page load failed: \(error.localizedDescription)"
    }

    private func isBenignNavigationCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func installObservers() {
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                self?.publishOnMain {
                    self?.canGoBack = webView.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                self?.publishOnMain {
                    self?.canGoForward = webView.canGoForward
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                self?.publishOnMain {
                    self?.isLoading = webView.isLoading
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                guard let url = webView.url else {
                    return
                }
                self?.publishOnMain {
                    self?.urlText = url.absoluteString
                }
            }
        ]
    }

    private func publishOnMain(_ update: @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct ElementCapturePreviewSheet: View {
    let preview: ElementCapturePreview
    let onUse: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Element captured — preview")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extracted text")
                        .font(.headline)
                    ScrollView {
                        Text(preview.pick.text.isEmpty ? "No text captured." : preview.pick.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(width: 280, height: 180)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Snapshot")
                        .font(.headline)
                    Group {
                        if let snapshot = preview.snapshot {
                            Image(nsImage: snapshot)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Text("Snapshot unavailable.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: 280, height: 180)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CSS selector")
                    .font(.headline)
                TextField("Selector", text: .constant(preview.pick.selector))
                    .textFieldStyle(.roundedBorder)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Re-identify", action: onRetry)
                Button("Use Element", action: onUse)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}
