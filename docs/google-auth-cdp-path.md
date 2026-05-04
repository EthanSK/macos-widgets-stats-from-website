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
- Element selection now has a bounded Chrome/CDP path from the visible browser:
  `Identify in CDP Browser` opens the page in the persistent profile, injects
  the existing picker into that CDP target, polls `window.__statsWidgetPicked`,
  validates the selector over CDP, and returns the same preview/save payload as
  the `WKWebView` picker.

## Safest next implementation path

1. Make Chrome/CDP the primary sign-in and scraping path for Google-authenticated
   trackers. Avoid new `WKWebView` OAuth workarounds.
2. Keep the current CDP Identify path intentionally small: inject the picker
   script, store the clicked payload on `window`, and poll it with
   `Runtime.evaluate` so no full `Runtime.enable` event stream is required.
3. For a deeper native inspector later, use CDP DOM/Overlay calls such as
   `DOM.getNodeForLocation`, `Overlay.highlightNode`, and
   `DOM.describeNode`/attributes. That needs event handling in
   `ChromeCDPClient`, so keep it as a later iteration.
4. Route Google-account pages through the Chrome profile: open/sign in in CDP
   browser → use `Identify in CDP Browser` → validate selector via CDP → save
   tracker with the existing `browserProfile`.
5. Keep `WKWebView` available for non-Google/local pages where a bundled system
   browser is valuable and App Store constraints matter.

## Small groundwork already applied

`InspectOverlayJS` now has a non-WebKit fallback: when no
`webkit.messageHandlers` bridge exists, successful picks are stored on
`window.__statsWidgetPicked` and errors on `window.__statsWidgetInspectError`.
The script clears those fallback globals at startup so CDP polling cannot read a
stale pick from a previous identify session.
