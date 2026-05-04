# Google-authenticated pages: Chrome/CDP path

_Last assessed on 2026-05-04 from the Mac Mini implementation state._

## Decision

Use a real Chrome/Chromium profile controlled over the Chrome DevTools Protocol
for Google-authenticated pages. Keep the embedded `WKWebView` browser as a
secondary path for non-Google pages, simple local pages, and fallback browsing.

Google sign-in inside embedded macOS `WKWebView` is intentionally unsupported
for OAuth/sign-in flows and remains brittle even with Safari user-agent,
process-pool, data-store, FedCM, or passkey tweaks. Do not spend more product
time trying to make Google OAuth reliable inside `WKWebView`.

## Current implementation inventory

- Background/app-owned scraping already uses `ChromeCDPScraper` from
  `BackgroundScheduler`, and MCP `trigger_scrape` uses `ChromeCDPScraper` in
  the main app target.
- `ChromeBrowserProfile` launches a persistent Chrome/Chromium profile with a
  local CDP port and per-profile user-data directory.
- `ChromeCDPClient` intentionally avoids `Runtime.enable` and uses
  `Runtime.evaluate` directly for selector extraction, matching the safer
  Google-login-compatible control style.
- The remaining weak link is element selection: `Identify Element` still runs
  through `InAppBrowserView` + `IdentifyElementCoordinator`, which are
  `WKWebView`-based. The UI can open the same page in the CDP browser, but it
  does not yet attach a picker to that Chrome target.

## Safest next implementation path

1. Make Chrome/CDP the primary sign-in and scraping path for Google-authenticated
   trackers. Avoid new `WKWebView` OAuth workarounds.
2. Port `Identify Element` to CDP before doing more Google-specific UI work.
   Prefer one of these approaches, in order:
   - Inject a picker script into the selected Chrome target, reuse the existing
     selector synthesis logic, store the clicked payload on `window`, and poll
     it with `Runtime.evaluate` so no full `Runtime.enable` event stream is
     required.
   - For a deeper native inspector later, use CDP DOM/Overlay calls such as
     `DOM.getNodeForLocation`, `Overlay.highlightNode`, and
     `DOM.describeNode`/attributes. That needs event handling in
     `ChromeCDPClient`, so keep it as the second step rather than the first.
3. Once CDP Identify Element exists, route Google-account pages directly through
   the Chrome profile: open target → user signs in/picks element → validate
   selector via CDP → save tracker with the existing `browserProfile`.
4. Keep `WKWebView` available for non-Google/local pages where a bundled system
   browser is valuable and App Store constraints matter.

## Small groundwork already applied

`InspectOverlayJS` now has a non-WebKit fallback: when no
`webkit.messageHandlers` bridge exists, successful picks are stored on
`window.__statsWidgetPicked` and errors on `window.__statsWidgetInspectError`.
That preserves the current WKWebView behavior while making the existing picker
script reusable by a future CDP polling coordinator.
