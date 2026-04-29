//
//  ProfileManager.swift
//  MacosStatsWidgetShared
//
//  Shared WebKit profile configuration for visible and headless web views.
//

import Foundation
import WebKit

final class WebViewProfile {
    static let shared = WebViewProfile()
    static let name = Tracker.defaultBrowserProfile

    // WebKit's macOS 14 named data-store API is keyed by UUID. This stable UUID
    // is the backing identifier for the "macos-stats-widget" browser profile.
    private static let dataStoreIdentifier = UUID(uuidString: "7d8f7d6c-829b-4f6d-9c13-0e8a6e8f9e44")!

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
        // Keep one shared process pool for the visible browser and future
        // headless scrapers. The typed API is deprecated on modern macOS, but
        // the Obj-C property remains available and is harmless where no-op.
        configuration.setValue(processPool, forKey: "processPool")
        configuration.userContentController = userContentController
        return configuration
    }
}
