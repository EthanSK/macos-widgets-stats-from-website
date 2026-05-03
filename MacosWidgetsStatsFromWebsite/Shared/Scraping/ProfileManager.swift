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

    // Safari UA-spoof for OAuth-blocking sites (Google etc.).
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

    // FedCM-rejection shim: Google's OAuth flow can call
    // navigator.credentials.get({ identity: ... }) and stall in WKWebView
    // because FedCM is incomplete there. That call is not guaranteed to run
    // from accounts.google.com; relying-party pages can invoke Google Identity
    // Services before the browser reaches a Google-owned frame. Install the
    // shim globally, but only reject FedCM/federated requests so password and
    // passkey credentials keep using WebKit's native implementation.
    // The native method may also be installed/restored after atDocumentStart,
    // so keep re-applying the shim briefly.
    // This is best-effort only; InAppBrowserView still has a narrow external
    // deflection for the known-broken consent route.
    private static let fedCMRejectionPolyfillSource = """
    (function() {
      try {
        var originalGet = null;
        var attempts = 0;
        var timer = null;

        function isShim(fn) {
          return !!(fn && fn.__statsWidgetFedCMShim === true);
        }

        function credentialsPrototype() {
          try {
            if (window.CredentialsContainer && window.CredentialsContainer.prototype) {
              return window.CredentialsContainer.prototype;
            }
          } catch (_) {}
          return null;
        }

        function shouldRejectFedCM(options) {
          return !!(options && (Object.prototype.hasOwnProperty.call(options, 'identity') || options.identity || options.federated));
        }

        function rejected(message) {
          return Promise.reject(new DOMException(message || 'FedCM not supported in WKWebView', 'NotSupportedError'));
        }

        function rememberOriginal(fn) {
          if (!originalGet && typeof fn === 'function' && !isShim(fn)) {
            originalGet = fn;
          }
        }

        function shimmedGet(options) {
          if (shouldRejectFedCM(options)) {
            return rejected('FedCM not supported in WKWebView');
          }

          if (!originalGet) {
            var credentials = navigator.credentials;
            var proto = credentialsPrototype();
            rememberOriginal(proto && proto.get);
            rememberOriginal(credentials && credentials.get);
          }

          return originalGet ? originalGet.call(navigator.credentials, options) : rejected('Credentials API unavailable');
        }

        try {
          Object.defineProperty(shimmedGet, '__statsWidgetFedCMShim', {
            value: true,
            configurable: false
          });
        } catch (_) {}

        function installOn(target) {
          if (!target) return;
          rememberOriginal(target.get);
          if (isShim(target.get)) return;

          try {
            Object.defineProperty(target, 'get', {
              value: shimmedGet,
              configurable: true,
              enumerable: true,
              writable: true
            });
          } catch (_) {
            try { target.get = shimmedGet; } catch (_) {}
          }
        }

        function install() {
          attempts += 1;
          var credentials = navigator.credentials;
          var proto = credentialsPrototype();
          installOn(proto);
          installOn(credentials);

          if (attempts > 400 && timer) {
            clearInterval(timer);
            timer = null;
          }
        }

        install();
        document.addEventListener('readystatechange', install, true);
        window.addEventListener('DOMContentLoaded', install, true);
        window.addEventListener('load', install, true);
        timer = setInterval(install, 25);
      } catch (e) { /* swallow — never break the page */ }
    })();
    """

    private static var fedCMRejectionPolyfillScript: WKUserScript {
        if #available(macOS 11.0, *) {
            return WKUserScript(
                source: fedCMRejectionPolyfillSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
        }

        return WKUserScript(
            source: fedCMRejectionPolyfillSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

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

    /// Build a `WKWebView` with the shared profile configuration and the
    /// Safari UA-spoof pre-applied. Always prefer this over constructing
    /// `WKWebView` directly so every visible/headless browser inherits the spoof.
    func makeWebView(frame: CGRect, userContentController: WKUserContentController = WKUserContentController()) -> WKWebView {
        let webView = WKWebView(frame: frame, configuration: makeConfiguration(userContentController: userContentController))
        // Safari UA-spoof for OAuth-blocking sites (Google etc.).
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
