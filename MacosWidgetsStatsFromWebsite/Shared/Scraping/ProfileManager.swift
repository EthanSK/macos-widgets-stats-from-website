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

    func makeConfiguration(userContentController: WKUserContentController = WKUserContentController()) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(macOS 11.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        // Keep one shared process pool for the visible browser and future
        // headless scrapers. The typed API is deprecated on modern macOS, but
        // the Obj-C property remains available and is harmless where no-op.
        configuration.setValue(processPool, forKey: "processPool")
        configuration.userContentController = userContentController
        return configuration
    }

    /// Build a `WKWebView` with the shared profile configuration and the Phase-0
    /// Safari UA-spoof pre-applied. Always prefer this over constructing
    /// `WKWebView` directly so every visible/headless browser inherits the spoof.
    func makeWebView(frame: CGRect, userContentController: WKUserContentController = WKUserContentController()) -> WKWebView {
        let webView = WKWebView(frame: frame, configuration: makeConfiguration(userContentController: userContentController))
        // Phase-0 UA-spoof for OAuth-blocking sites (Google etc.). Replace with bundled Chromium engine in Phase-1. See /tmp/widget-engine-research-2026-05-01.md.
        webView.customUserAgent = Self.safariUserAgent
        return webView
    }
}
