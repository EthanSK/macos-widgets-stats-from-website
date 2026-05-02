//
//  ProfileManager.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Shared WebKit profile configuration for visible and headless web views.
//

import Foundation
import WebKit

final class WebViewProfile {
    static let shared = WebViewProfile()
    static let name = Tracker.defaultBrowserProfile

    // WebKit's macOS 14 named data-store API is keyed by UUID. This stable UUID
    // is the backing identifier for the "macos-widgets-stats-from-website" browser profile.
    private static let dataStoreIdentifier = UUID(uuidString: "7d8f7d6c-829b-4f6d-9c13-0e8a6e8f9e44")!

    // Phase-0 UA-spoof for OAuth-blocking sites (Google etc.). Replace with bundled Chromium engine in Phase-1. See /tmp/widget-engine-research-2026-05-01.md.
    // String matches current-stable Safari 17.5 on macOS 14.5 (Sonoma). Empirically flips Google's
    // OAuth flow classification from `flowName=GeneralOAuthLite` (restricted) to
    // `flowName=GeneralOAuthFlow` (full), matching what real Safari receives.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    let processPool: NSObject = {
        guard let processPoolClass = NSClassFromString("WKProcessPool") as? NSObject.Type else {
            fatalError("WKProcessPool is unavailable.")
        }

        return processPoolClass.init()
    }()

    var websiteDataStore: WKWebsiteDataStore {
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier)
        }

        // macOS 13 does not expose WKWebsiteDataStore(forIdentifier:), so the
        // app falls back to the shared persistent default store on that OS.
        return WKWebsiteDataStore.default()
    }

    private init() {}

    // FedCM-rejection polyfill: Google's OAuth consent page calls
    // navigator.credentials.get({identity:...}) and stalls in WKWebView
    // because FedCM isn't implemented. Force-rejecting the call lets
    // Google fall back to its non-FedCM flow, which renders normally.
    // If this works, the consent-URL deflection in InAppBrowserView.swift
    // (commit eef38b1) becomes redundant.
    private static let fedCMRejectionPolyfillSource = """
    (function() {
      try {
        if (!location.hostname.endsWith('accounts.google.com')) return;
        if (!navigator.credentials || typeof navigator.credentials.get !== 'function') return;
        var origGet = navigator.credentials.get.bind(navigator.credentials);
        navigator.credentials.get = function(options) {
          if (options && options.identity) {
            return Promise.reject(new DOMException('FedCM not supported', 'NotSupportedError'));
          }
          return origGet(options);
        };
      } catch (e) { /* swallow — never break the page */ }
    })();
    """

    private static let fedCMRejectionPolyfillScript: WKUserScript = WKUserScript(
        source: fedCMRejectionPolyfillSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    func makeConfiguration(userContentController: WKUserContentController = WKUserContentController()) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        userContentController.addUserScript(Self.fedCMRejectionPolyfillScript)
        configuration.userContentController = userContentController

        // Keep one shared process pool for the visible browser and future
        // headless scrapers. The typed API is deprecated on modern macOS, but
        // the Obj-C property remains available and is harmless where no-op.
        configuration.setValue(processPool, forKey: "processPool")

        // === Phase-0 "make WKWebView feel like Safari" feature flags ===

        // JavaScript: opening windows automatically (popups during OAuth flows etc.)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // JavaScript: allow content scripts to run (the modern replacement for
        // preferences.javaScriptEnabled, which has been deprecated since macOS 11).
        if #available(macOS 11.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        // Fraudulent / phishing site warning (Safe Browsing). On by default but
        // make the intent explicit so a future config refactor can't silently
        // drop user protection.
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        // HTML5 fullscreen API (video sites, dashboards with fullscreen toggles).
        if #available(macOS 12.3, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }

        // Inline media playback (video plays in-place rather than punting to a
        // standalone player). Already the macOS default but make it explicit.
        configuration.allowsAirPlayForMediaPlayback = true

        // Don't gate any media (audio/video) behind a user gesture — the
        // user already opted-in by adding the tracker, and most dashboards
        // autoplay charts/streams. Empty set = no media types require a tap.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Render incrementally as bytes arrive (faster perceived load).
        configuration.suppressesIncrementalRendering = false

        // Upgrades known-HTTP URLs to HTTPS where the host advertises it (HSTS-ish).
        if #available(macOS 11.0, *) {
            configuration.upgradeKnownHostsToHTTPS = true
        }

        return configuration
    }

    /// Build a `WKWebView` with the shared profile configuration and the Phase-0
    /// Safari UA-spoof pre-applied. Always prefer this over constructing
    /// `WKWebView` directly so every visible/headless browser inherits the spoof.
    func makeWebView(frame: CGRect, userContentController: WKUserContentController = WKUserContentController()) -> WKWebView {
        let webView = WKWebView(frame: frame, configuration: makeConfiguration(userContentController: userContentController))
        // Phase-0 UA-spoof for OAuth-blocking sites (Google etc.). Replace with bundled Chromium engine in Phase-1. See /tmp/widget-engine-research-2026-05-01.md.
        webView.customUserAgent = Self.safariUserAgent

        // 3D Touch / force-touch link previews on the visible browser. No-op on
        // headless scrapers since they're never user-interactive, but harmless.
        webView.allowsLinkPreview = true

        // Standard navigation gestures (back/forward swipe on trackpad). Useful
        // in the visible InAppBrowserView; harmless when the view is offscreen.
        webView.allowsBackForwardNavigationGestures = true

        // Magnification gesture (pinch-to-zoom). On by default but make it explicit.
        webView.allowsMagnification = true

        // Web Inspector — Debug builds only. macOS 13.3+ requires opt-in via
        // isInspectable; without this Safari's Develop menu can't attach.
        // Skipped on Release so production users don't see "Inspect Element".
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        return webView
    }
}
