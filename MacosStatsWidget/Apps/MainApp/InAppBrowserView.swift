//
//  InAppBrowserView.swift
//  MacosStatsWidget
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

private final class InAppBrowserController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    @Published var urlText: String
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var isIdentifying = false
    @Published var inlineError: String?
    @Published var preview: ElementCapturePreview?

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
        webView = WKWebView(frame: .zero, configuration: WebViewProfile.shared.makeConfiguration(userContentController: userContentController))

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
        installObservers()

        if let initialURL {
            load(initialURL)
        }
    }

    deinit {
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
        webView.load(URLRequest(url: url))
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
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        inlineError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        inlineError = error.localizedDescription
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
