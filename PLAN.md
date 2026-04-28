# macOS Stats Widget — Plan

> Living design document. Implementation begins at v0.1 once this is signed
> off. v0.0.3 consolidates seven prior open questions into resolved decisions
> and folds in a follow-up batch of requirements (terminology cleanup, render
> mode rename, multi-widget configurations, embedded MCP server, quick-setup
> skill installer, first-launch wizard). Concrete > comprehensive.

---

## 1. Vision & problem statement

I keep refreshing the Codex usage page, the Claude Code spend page, the OpenAI
dashboard, and a couple of other "what's my number right now" pages. Each one
is a tab, a cookie, a sign-in, and twenty seconds of friction. The numbers
themselves are tiny — one to four digits — but the act of fetching them
breaks flow several times a day.

A widget on the desktop is the right surface for this:

- **App** is overkill. I don't want to launch anything; I want the number to
  already be there when I glance at it.
- **Menu-bar status item** is too cramped for multiple trackers and doesn't
  compose well visually. SF Symbols + a single number is fine for one stat,
  but I want four to eight.
- **Browser extension** doesn't show on my desktop and dies when the browser
  is closed.
- **Widget** is the native macOS surface for "passive number on screen", has
  WidgetKit's timeline + Intents API for refresh, and supports SwiftUI for
  rich rendering (gauges, sparklines, cropped images).

The product is therefore: **a macOS WidgetKit widget that displays scraped
content from any logged-in web page** — text values *or* live element
snapshots — **configured once via a click-to-pick element flow, refreshing on
a per-tracker schedule, with a self-healing fallback when sites change their
layout**.

LLM-spend pages are the canonical example. The widget is **not** specific to
metrics, money, or AI usage: any text node, number, percentage, status badge,
or visual region on any web page you can sign into is fair game. "Tracker" is
the term we use throughout — a tracker is one (URL, selector, render mode)
triple plus its display config.

It is a personal tool first and a public open-source project second. The
public artefact has to clear App Store review (so the **app + widget**
clear) and ship via Homebrew for the **CLI** (which would not clear App
Store review).

## 2. Architecture overview

Three components share a single App Group, plus an embedded MCP server that
exposes the data plane to local AI CLIs:

| Component | Type | Responsibility | Ships via |
|---|---|---|---|
| **Main app** | `.app` (AppKit shell + SwiftUI) | Preferences UI, in-app browser, element-capture flow, login persistence, **scheduled scraping via NSBackgroundActivityScheduler**, embedded MCP server, manual scrape trigger | Mac App Store |
| **Widget extension** | WidgetKit extension inside the `.app` | Reads tracker readings from App Group on each timeline tick, renders Text or Snapshot mode | Mac App Store (bundled) |
| **CLI scraper** | Standalone executable | Power-user adjunct: custom schedules, headless server use, automated self-heal without GUI confirm, scriptable bulk operations | Homebrew tap |
| **MCP server** | Embedded inside the main app | Exposes tracker CRUD + scrape + selector-pack tools to Codex CLI / Claude Code | Bundled with `.app` |

```
   ┌────────────────────────────────────────────────────────┐
   │  Main App (sandbox)                                    │
   │  - Preferences UI                                      │
   │  - In-app browser                                      │
   │  - Element capture                                     │
   │  - Background scrape (NSBackgroundActivityScheduler)   │
   │  - Embedded MCP server (UNIX socket / stdio)           │
   │  - Manual "scrape now"                                 │
   └────────────┬─────────────────────────────┬─────────────┘
                │                             │
                │   reads & writes            │   exposes via MCP
                │                             │
                ▼                             ▼
        ┌────────────────────────┐    ┌──────────────────────┐
        │  App Group container   │    │  Codex CLI / Claude  │
        │  ~/Library/Group       │    │  Code (over MCP)     │
        │  Containers/<group-id>/│    └──────────────────────┘
        │  ├─ trackers.json      │
        │  ├─ readings.json      │              ▲
        │  ├─ snapshots/<id>.png │              │
        │  ├─ widget-configs.json│              │
        │  └─ schema-version     │              │  power-user mode
        └────────┬───────────────┘              │
                 │                              │
                 │  reads only                  │
                 ▼                              │
       ┌────────────────────────┐    ┌──────────┴───────────┐
       │  Widget Extension      │    │  CLI scraper          │
       │  - Text / Snapshot     │    │  - WKWebView headless │
       │  - Sparkline           │    │  - launchd schedule   │
       │  - Animated transitions│    │  - Codex self-heal    │
       └────────────────────────┘    │  - HTML snapshot dump │
                                      └───────────────────────┘
```

**Data flow.** The main app owns the *config*, *readings*, and *scheduling*.
The widget only *reads*. The CLI is an optional second writer for
power users; when both run, the file lock + schema version guard against
corruption. The MCP server is a thin wrapper over the same shared store.

**Process boundaries (App Store sandbox implications):**

- The widget extension runs sandboxed and has *no* network entitlement. It
  only reads local files in the App Group container. This is critical for
  App Store acceptance.
- The main app has the network-client entitlement (so the in-app browser
  + MCP socket work) but does **not** spawn the Codex CLI for self-heal.
  Spawning external binaries from a sandboxed app is brittle and a review
  risk. Self-heal that requires `codex exec` lives in the Homebrew CLI.
- The main app's *scheduled scraping* runs through
  `NSBackgroundActivityScheduler`, which is sandbox-safe and is the
  canonical Apple-blessed surface for "rerun this every N minutes while the
  app is alive (or wake it)". This guarantees standalone functionality —
  the app + widget refresh on their own without the CLI installed.
- The CLI is a regular macOS executable, unsandboxed, Homebrew-shipped. It
  has full disk access (via user-granted TCC) and can spawn `codex` /
  `claude`. It writes into the App Group container path; the directory is
  shared because the App Group ID is declared in both the app's
  entitlements and the CLI's runtime config.

## 3. Tech stack & rationale

- **Swift 5.9+**, targeting macOS 14+ (Sonoma). WidgetKit on macOS got
  significantly better in 14, and 14+ covers ~95% of active Macs by ship.
- **SwiftUI** for Preferences UI and the widget itself. **AppKit** shell for
  the main app window (window-management features SwiftUI still doesn't
  cover well: hidden-when-closed dock icon, window restoration, menu-bar
  niceties).
- **WidgetKit** with `TimelineProvider` + `IntentTimelineProvider` (so users
  can configure which tracker / which widget configuration a given widget
  instance shows).
- **NSBackgroundActivityScheduler** for in-app scheduled scraping. Sandbox
  safe; runs while the app is alive or wakes it from suspended state. No
  LaunchAgent required for the standalone path; the CLI path keeps its
  LaunchAgent for headless / power-user setups.
- **WKWebView** as the scraping engine (both in the in-app browser and the
  CLI's headless path). Reasons over Chromium-portable / Playwright:
  - Size: WKWebView is the system framework, zero added MB.
  - App Store risk: bundling Chromium in a sandboxed app is a non-starter.
  - Updates: WebKit is patched by the OS; we never ship a stale browser.
  - Cookie persistence: `WKWebsiteDataStore(forIdentifier:)` gives us a
    named persistent profile out of the box.
- **WKWebsiteDataStore(forIdentifier: "macos-stats-widget")** — single
  named persistent profile shared between the in-app browser, the embedded
  scraper, and (where the App Group lets the CLI reach in) the headless
  CLI. Cookies, IndexedDB, localStorage, service worker registrations all
  persist across launches.
- **Keychain Services API** — for any user-entered credentials. In practice
  rare: most tracked sites use OAuth / SSO, so cookies in
  `WKWebsiteDataStore` cover the case. Keychain entries are scoped to the
  app's bundle ID with the `kSecAttrAccessGroup` set to the App Group so
  the widget can read tokens if it ever needs to (it currently doesn't).
- **AuthenticationServices framework** — passkey + `ASWebAuthenticationSession`
  support for sites that publish a passkey-friendly sign-in path. The
  in-app browser falls back to standard form login when passkeys aren't
  offered.
- **App Group** over UserDefaults / iCloud / Keychain (for the data plane):
  - UserDefaults: scoped to a single bundle ID by default; cross-process
    sharing requires `suiteName` which is exactly what App Group provides
    *for plists*, but we want JSON + PNG too.
  - iCloud: latency, conflict resolution, and offline behaviour are wrong
    for a refresh-every-30-min widget.
  - Keychain: only for credentials, not for readings.
- **xcodegen** (`project.yml`) for the Xcode project so we never commit
  `.xcodeproj` to git — it's a regenerated artefact. Keeps diffs sane.
- **launchd LaunchAgent** (CLI only) for headless scheduling. Standalone
  app+widget does *not* require it.
- **MCP server (embedded in main app)** — see §13. Stdio transport when
  invoked as a child process by Codex / Claude Code; UNIX domain socket at
  `~/Library/Group Containers/<group-id>/mcp.sock` for the always-on case.

## 4. Module structure

```
MacosStatsWidget/
  Apps/
    MainApp/
      MacosStatsWidgetApp.swift       — app entry, scene wiring
      AppDelegate.swift               — menu bar / dock icon control
      PreferencesWindow.swift         — main preferences container
      TrackersListView.swift          — list of configured trackers
      TrackerEditorView.swift         — add/edit tracker form
      WidgetConfigsView.swift         — list of widget configurations
      WidgetConfigEditorView.swift    — add/edit a widget composition
      InAppBrowserView.swift          — WKWebView host with Identify Element
      InspectOverlayJS.swift          — JS string for hover/click overlay
      OnboardingView.swift            — first-launch wizard
      CLIDetectionView.swift          — onboarding step 1: detect codex/claude
      QuickSetupView.swift            — Preferences pane: install Claude/Codex skills
      SignInPrefsView.swift           — Sign in / Re-sign in / Reset Browser
      BackgroundScheduler.swift       — NSBackgroundActivityScheduler wrapper
    WidgetExtension/
      MacosStatsWidgetBundle.swift    — registers the widget
      StatsWidget.swift               — TimelineProvider + entry view
      TextWidgetView.swift            — Text-mode rendering
      SnapshotWidgetView.swift        — Snapshot-mode rendering
      MultiTrackerWidgetView.swift    — composed dashboard widget
      SparklineView.swift             — last-N reading sparkline
      WidgetIntent.swift              — IntentDefinition for widget config picking
    CLI/
      main.swift                      — argument parsing (Codable args)
      ScrapeCommand.swift             — `scrape` subcommand
      SelfHealCommand.swift           — `self-heal` subcommand
      Scheduler.swift                 — top-level loop, throttle, jitter
      LaunchdInstaller.swift          — install/remove LaunchAgent plist
    MCPServer/
      MCPServer.swift                 — entry point, transport selection
      StdioTransport.swift            — JSON-RPC over stdin/stdout
      SocketTransport.swift           — JSON-RPC over UNIX domain socket
      Tools/
        ListTrackersTool.swift
        GetTrackerTool.swift
        AddTrackerTool.swift
        UpdateTrackerTool.swift
        DeleteTrackerTool.swift
        UpdateSelectorTool.swift
        TriggerScrapeTool.swift
        IdentifyElementTool.swift
        ListWidgetConfigsTool.swift
        UpdateWidgetConfigTool.swift
        ExportSelectorPackTool.swift
        ImportSelectorPackTool.swift
      Auth/
        SocketAuth.swift              — UNIX-perm / shared-secret check
  Shared/
    Models/
      Tracker.swift                   — Tracker struct (config row)
      TrackerResult.swift             — last reading + history
      RenderMode.swift                — .text | .snapshot
      TrackerStatus.swift             — .ok | .stale | .broken
      WidgetConfiguration.swift       — name, size, [trackerID], layout
      SelectorPack.swift              — exportable JSON shape
    AppGroup/
      AppGroupPaths.swift             — typed paths into the container
      AppGroupStore.swift             — atomic JSON read/write helpers
      SchemaVersion.swift             — current version + migrators
    Scraping/
      HeadlessScraper.swift           — WKWebView wrapper (used by app+CLI)
      LongLivedScrapeSession.swift    — kept-alive page for snapshot polling
      ProfileManager.swift            — WKWebsiteDataStore identifier mgmt
      SelectorRunner.swift            — runs a CSS selector, returns text
      ElementSnapshotter.swift        — element bbox -> PNG via takeSnapshot(of:rect)
    SelectorHeal/
      AICLIInvoker.swift              — spawns codex/claude per priority order
      RegexFallback.swift             — final-fallback numeric/$-amount/% extractor
      HealPrompt.swift                — prompt template constants
      HealValidator.swift             — sanity-check proposed selector
      HealNotifier.swift              — macOS native notification + webhook POST
    Notifications/
      UNUserNotificationCenterClient.swift — macOS native notifications
      WebhookClient.swift             — generic webhook POST (Slack/Discord/etc.)
  Tests/
    SharedTests/                      — unit tests for pure types
    ScrapingTests/                    — fixture-HTML based selector tests
    HealTests/                        — mock AICLIInvoker tests
    MCPServerTests/                   — JSON-RPC tool dispatch tests
  scripts/
    bootstrap.sh                      — one-shot dev setup
    package-cli.sh                    — produces a Homebrew-ready tarball
  project.yml                         — xcodegen project definition
```

One-line responsibility per file is the discipline we keep — if a file
needs more than one line to describe, it's doing too much and we split it.

## 5. Configuration schema

Stored at `~/Library/Application Support/macOS Stats Widget/trackers.json`
(the **canonical config** — the App Group container holds a *copy* the
widget reads, written atomically by the main app):

```jsonc
{
  "schemaVersion": 3,
  "trackers": [
    {
      "id": "8c1b2e6e-…",                 // UUID, immutable — the "tracker ID"
      "name": "Codex weekly spend",
      "url": "https://platform.openai.com/usage",
      "browserProfile": "macos-stats-widget", // WKWebsiteDataStore identifier
      "renderMode": "text",               // "text" | "snapshot"
      "selector": "div[data-testid=\"weekly-cost\"] span",
      "elementBoundingBox": {              // captured at Identify Element time
        "x": 480, "y": 312, "width": 96, "height": 28,
        "viewportWidth": 1280, "viewportHeight": 800,
        "devicePixelRatio": 2
      },
      "refreshIntervalSec": 1800,         // text default 30 min, snapshot default 2 sec
      "label": "Codex",                   // display label override
      "icon": "dollarsign.circle.fill",    // SF Symbol name
      "accentColorHex": "#10a37f",
      "valueParser": {                     // text mode only
        "type": "currencyOrNumber",       // "currencyOrNumber" | "percent" | "raw"
        "stripChars": ["$", ",", " "]
      },
      "history": {
        "retentionPolicy": "days",        // "count" | "days"
        "retentionValue": 7,               // 7 days default; max 30 days
        "displayWindow": 24                // sparkline shows last 24 readings (~12h at 30 min)
      },
      "hideElements": [                    // optional CSS selectors hidden before snapshot
        ".cookie-banner",
        "#trial-prompt"
      ],
      "lastHealedAt": null,
      "selectorHistory": []               // {selector, replacedAt} entries
    }
  ],
  "widgetConfigurations": [
    {
      "id": "9d2f1a8b-…",
      "name": "AI Spend Dashboard",
      "size": "large",                    // "small" | "medium" | "large"
      "layout": "grid",                   // "grid" | "stack" | "single"
      "trackerIDs": [
        "8c1b2e6e-…",
        "f4a3c2d1-…",
        "b1e8d7f5-…",
        "5c3a9b2e-…"
      ],
      "showSparklines": true,
      "showLabels": true
    },
    {
      "id": "1a4c6b9e-…",
      "name": "Codex Only",
      "size": "small",
      "layout": "single",
      "trackerIDs": ["8c1b2e6e-…"],
      "showSparklines": true,
      "showLabels": true
    }
  ],
  "preferences": {
    "selfHealCLIPriority": ["codex", "claude", "regex"],
    "notificationChannels": {
      "macosNative": true,
      "webhook": null                     // optional URL string
    },
    "detectedCLIs": {                      // populated by First-Launch detection
      "codex": { "installed": true,  "version": "0.42.0" },
      "claude": { "installed": true, "version": "1.4.0" }
    }
  }
}
```

Readings live in a separate file (App Group only, never in user docs):

```jsonc
// readings.json
{
  "schemaVersion": 3,
  "readings": {
    "<tracker-id>": {
      "currentValue": "$42.18",          // text mode: extracted innerText
      "currentNumeric": 42.18,           // text mode: parsed value (for sparkline)
      "snapshotPath": "snapshots/8c1b2e6e.png", // snapshot mode: latest PNG path
      "snapshotCapturedAt": "2026-04-28T14:02:13Z",
      "lastUpdatedAt": "2026-04-28T14:02:13Z",
      "status": "ok",
      "sparkline": [38.4, 39.1, 40.0, 42.0, 42.18],
      "lastError": null
    }
  }
}
```

**Versioning strategy.** `schemaVersion` is a monotonic integer. The
v0.0.1 plan baselined at `schemaVersion = 1` (single `metrics` array, no
widget configurations, no MCP). v0.0.3 introduces:

- `schemaVersion = 2` migration: rename `metrics` → `trackers`, rename
  `mode` → `renderMode`, rename `"number"` → `"text"` and
  `"screenshot"` → `"snapshot"`. Pure key rename, no data loss.
- `schemaVersion = 3` migration: add `widgetConfigurations`, `preferences`,
  and the per-tracker `history` block; collapse legacy `cropRegion` into
  `elementBoundingBox`.

On app launch we read both files, compare against `currentSchemaVersion`,
and run forward migrators (`Migrator_1_to_2`, `Migrator_2_to_3` …).
Migrators are pure functions. We never delete fields; we add an optional
`deprecated` flag and stop reading them. Backward migration is not
supported — once upgraded, downgrade requires restoring the prior
`trackers.json` from the last `trackers.json.bak`. The app keeps three
rotating backups.

## 6. Element-capture UX flow

```
[Preferences]
   ├─ user clicks "+ Add tracker"
   ▼
[New Tracker — Step 1: Browse]
   ├─ embedded WKWebView, full chrome (back/forward/reload/url-bar)
   ├─ user signs in (cookies persisted via WKWebsiteDataStore identifier
   ├─  "macos-stats-widget"; passkey path used when site supports it)
   ├─ user navigates to the page that has the value/region they want
   ▼
[New Tracker — Step 2: Identify Element]
   ├─ user clicks "Identify Element" toolbar button
   ├─ JS injects an InspectOverlay (mouseover outline, click trap)
   ├─ user hovers — element under cursor gets 2px solid outline
   ├─ user clicks — element selected, inspect mode exits
   ▼
[New Tracker — Step 3: Choose Render Mode]
   ├─ shows extracted innerText + element snapshot side-by-side
   ├─ user picks "Text mode" (extract innerText) or "Snapshot mode"
   │   (capture the element's bounding rect as an image)
   ├─ if Snapshot, user can optionally tick CSS selectors to hide
   │   from the captured frame (cookie banners, trial prompts)
   ▼
[New Tracker — Step 4: Polish]
   ├─ user names the tracker, picks SF Symbol + accent colour
   ├─ user picks refresh interval (slider; defaults: 30 min Text / 2 sec Snapshot)
   ├─ user picks which widget configuration(s) the tracker belongs to
   │   (or chooses "Create new widget configuration")
   ▼
[Save] → writes trackers.json, schedules background scrape, reload widget timeline
```

**Sign-in persistence UX (Preferences → Browser).** A dedicated panel
lets the user manage logged-in state without going back to the
Identify Element flow:

```
┌─ Browser & Sign-in ─────────────────────────────────────────┐
│  Profile: macos-stats-widget (WKWebsiteDataStore)           │
│                                                              │
│  [ Sign in to a site ]   opens the in-app browser            │
│  [ Re-sign in to … ▾  ]   pick a site we have cookies for    │
│  [ Reset browser data ]   wipes cookies, IndexedDB, caches   │
│                                                              │
│  Stored credentials (Keychain): 0 entries                    │
│  Passkeys available: AuthenticationServices framework        │
└──────────────────────────────────────────────────────────────┘
```

`Reset browser data` is destructive — it wipes the entire profile and
forces re-login on every tracked site. Confirmation dialog. The button
exists so users can recover from "I logged into the wrong account once
and now everything is wrong" without nuking the whole app.

**JS injection for inspect overlay** — sketch:

```js
(() => {
  const outline = document.createElement('div');
  outline.style.cssText = 'position:fixed;border:2px solid #2997ff;' +
    'pointer-events:none;z-index:2147483647;';
  document.body.appendChild(outline);
  const onMove = e => {
    const el = e.target;
    const r = el.getBoundingClientRect();
    Object.assign(outline.style,
      { left: r.left+'px', top: r.top+'px',
        width: r.width+'px', height: r.height+'px' });
    window.__statsWidgetHover = el;
  };
  const onClick = e => {
    e.preventDefault(); e.stopPropagation();
    const el = window.__statsWidgetHover;
    const r = el.getBoundingClientRect();
    const sel = synthesiseSelector(el); // attribute > class > nth-child fallback
    webkit.messageHandlers.elementPicked.postMessage({
      selector: sel, text: el.innerText.trim(),
      bbox: { x:r.left, y:r.top, width:r.width, height:r.height,
              viewportWidth: innerWidth, viewportHeight: innerHeight,
              devicePixelRatio: devicePixelRatio }
    });
    cleanup();
  };
  document.addEventListener('mousemove', onMove, true);
  document.addEventListener('click', onClick, true);
  function cleanup() { /* remove listeners + outline */ }
})();
```

The Swift side receives the message, validates the selector against the
current DOM (does it return *exactly one* match? for Text mode, is the
text non-empty? for Snapshot mode, is the bounding rect non-zero?), then
commits.

## 7. Scraping strategy

Two render modes, two scrape strategies — same captured selector either
way.

### 7.1 Text mode

- **Headless WKWebView per scrape.** Open page, wait for `selector` to
  match, run `document.querySelector(selector).innerText`, write result,
  tear down.
- **Schedule.** Per-tracker `refreshIntervalSec`. Default 30 min, min 5
  min (anything under that is asking for a 429), max 24 hours.
- **Driven by NSBackgroundActivityScheduler** in the main app for the
  standalone case, or by the CLI's launchd agent for power users.

### 7.2 Snapshot mode (long-lived session)

Snapshot mode is designed for **live-updating visual elements**, e.g.
spinners, animated bars, multi-line dashboards. Default polling cadence
is **every 2 seconds**.

The naive approach — reload the page from scratch every 2 s — is hostile
to the target site (hammers their CDN, racks up 429s, looks like a bot)
and slow (full page load + auth + render takes longer than the polling
interval). Instead:

- **Long-lived page session.** When a snapshot tracker is added, the
  scrape engine opens the URL in a hidden WKWebView and *keeps it open*.
  The page stays loaded; cookies, JS state, and auth tokens stay live.
- **Re-snapshot only.** Every 2 s the scheduler calls
  `webView.takeSnapshot(of: cachedRect, into: …)`, where
  `cachedRect` is the element bounding rect we captured at Identify time
  (re-resolved each tick if the element has moved).
- **In-memory only.** The PNG is written to
  `App Group/snapshots/<tracker-id>.png` (same fixed path, atomic
  replace). Older PNGs are not retained — old in-memory snapshots are
  discarded as the new one overwrites. No file history.
- **Wake-from-sleep handling.** When the app suspends, the long-lived
  session pauses. On wake, we run one `webView.reload()` to pick up
  whatever has changed since the last frame, then resume snapshotting.
- **Reload heartbeat.** Every 30 min the long-lived session does a
  background `webView.reload()` so we don't drift on long-running pages.
- **Cap on concurrent snapshot trackers.** Each open page costs ~50 MB of
  memory. The app caps simultaneous snapshot sessions at 8; beyond that,
  trackers cycle (active → suspended) on a least-recently-rendered
  basis.

### 7.3 Shared knobs

- **Browser profile.** `WKWebViewConfiguration` with
  `websiteDataStore = WKWebsiteDataStore(forIdentifier: "macos-stats-widget")`.
  Same identifier in app, embedded scraper, and (where reachable) the CLI.
  Cookies, IndexedDB, localStorage, service worker registrations, passkey
  state — all persistent.
- **Throttle + jitter (text mode only).** ±20% jitter on every scheduled
  run, smeared across the interval window. Single in-flight scrape at any
  time across the whole app process. 30-second minimum gap between
  scrapes, even if two trackers are due at the same second. Snapshot mode
  is exempt because each tracker has its own long-lived session.
- **Backoff.** Exponential on HTTP 429 / 503: 5 min → 15 → 45 → 2h, cap
  at 2h. Reset on next success.
- **Login flow.** User signs in via the in-app browser; we never touch
  credentials directly. Cookies persist via
  `WKWebsiteDataStore(forIdentifier:)`. Where the site offers passkeys we
  use `ASWebAuthenticationSession`.
- **Inspired by caut's fallback chain** (see Acknowledgments): for
  supported sites we can later add OAuth / direct-API strategies as
  preferred sources, demoting browser scraping to the last-resort tier.
  v1 is browser-only.

## 8. Self-heal flow

**Trigger conditions** (any one fires the heal pipeline):

- Selector returns `null` / empty.
- Selector matches but text doesn't parse as a number / currency /
  percent per the tracker's `valueParser` (text mode only).
- For snapshot mode, the captured rect resolves to a 0×0 area, or the
  cached element node disappears from the DOM.

**Pipeline:**

1. **Snapshot.** App / CLI dumps the current page HTML + the tracker's
   history of selectors + the last good value to
   `~/Library/Application Support/macOS Stats Widget/heal-snapshots/<tracker-id>-<ts>.html`.
2. **Run priority chain.** Try each AI CLI in order according to
   `preferences.selfHealCLIPriority` (default `[codex, claude, regex]`):
   - **Codex CLI** (`codex exec`) — primary because it's free for ChatGPT
     Plus subscribers Ethan already pays for.
   - **Claude Code** (`claude -p`) — fallback when Codex isn't installed
     or returns `NO_MATCH`.
   - **Regex final fallback** — pure-Swift regex over the page HTML
     looking for numeric / `$amount` / percentage tokens near the prior
     selector's text. Doesn't require any CLI.
   The user can override the priority order in Preferences.
3. **Validate.** Parse the response, expect a single CSS selector. Run
   it on the cached HTML via WKWebView. Confirm:
   - exactly one element matches,
   - extracted text parses per `valueParser` (text mode),
   - the magnitude is within ~2 orders of the last good value,
   - or for snapshot mode, the bounding rect is non-zero.
4. **Commit.** Write the new selector into `trackers.json`, push the old
   one onto `selectorHistory`, set `lastHealedAt`, write the next reading
   normally.
5. **Notify.** macOS native notification (UNUserNotificationCenter) +
   optional generic webhook POST (configured in Preferences). Webhook
   payload: `{ "title": "...", "body": "...", "severity": "info|warn|error", "trackerId": "..." }`.
   That payload format is intentionally generic — it works with Slack,
   Discord, Pushover, ntfy, n8n, or any custom endpoint. **No
   Telegram-specific code anywhere in the app.**
6. **Fail-safe.** If three consecutive heal attempts on the same tracker
   fail, mark the tracker `status = .broken` in `readings.json`. The
   widget renders a red label + "?" SF Symbol. Auto-heal stops on that
   tracker until the user opens the app and re-runs Identify Element.

**Prompt template (full text):**

```
You are a CSS selector recovery assistant. Below is the HTML of a webpage.
The previous selector was:

    {OLD_SELECTOR}

It used to match an element with text "{LAST_GOOD_TEXT}". The page changed
and the selector now returns nothing.

Find the element on the new page that contains the same kind of value
(a number, currency amount, or percentage) and is in a similar visual
position. Return ONLY a CSS selector that uniquely identifies that element.
No prose, no code fences, no quotes — one line of CSS.

If you cannot find a confident replacement, output exactly:

    NO_MATCH

HTML:
---
{PAGE_HTML}
```

The Codex / Claude binary is invoked from the **CLI** only, never from
the sandboxed `.app`. The app instead invokes its own bundled regex
fallback for self-heal events that fire while the CLI isn't installed.
This keeps the App Store target clean.

## 9. Widget UI

The widget can render two render modes (Text / Snapshot) at three sizes
(small / medium / large), and supports two top-level shapes:

- **Single-tracker widget** — one tracker, full-bleed.
- **Multi-tracker dashboard widget** — a composed widget showing several
  trackers from a chosen *widget configuration*.

Both shapes are first-class. A user typically has one or two big
multi-tracker widgets *plus* a handful of small single-tracker ones for
the most-checked stats.

### 9.1 Text mode rendering

| Size | Layout |
|---|---|
| Small (155×155) | Big `Text` (with `contentTransition(.numericText())`); label below; SF Symbol top-right. `Gauge` instead of `Text` if `valueParser.type == "percent"`. |
| Medium (329×155) | Number left + sparkline right; label + last-updated under |
| Large (329×345) | 2×2 multi-tracker grid (up to 4) **or** single big number with sparkline + a 7-day history table. Selection is per *widget configuration*. |

### 9.2 Snapshot mode rendering

| Size | Layout |
|---|---|
| Small (155×155) | Cropped image fills, label overlaid bottom-left |
| Medium (329×155) | Cropped image left, side panel right with label + last-updated |
| Large (329×345) | Single cropped image, full-bleed |

`Image(...).interpolation(.high)` for resampling. The widget reads the
PNG produced by the long-lived snapshot session out of
`App Group/snapshots/<tracker-id>.png`.

### 9.3 Multi-tracker dashboard widget

A `WidgetConfiguration` row in `trackers.json` defines:

- a name,
- a chosen size,
- an ordered list of `trackerIDs`,
- a layout style (`grid`, `stack`, `single`).

The `IntentTimelineProvider` for the dashboard widget exposes
`widgetConfigurationID` as the configurable parameter. The user adds
the widget, picks a configuration from the picker, and the widget
renders that composition.

**Preferences UX for managing widget configurations.**

```
┌─ Widget Configurations ─────────────────────────────────────┐
│  + New configuration                                         │
│                                                              │
│  AI Spend Dashboard          [Large · Grid · 4 trackers] >   │
│  Codex Only                  [Small · Single · 1 tracker] >  │
│  Bills & Bank                [Medium · Stack · 2 trackers] > │
└──────────────────────────────────────────────────────────────┘
```

Editing a row opens the picker UI: name, size, layout, drag-to-reorder
list of trackers. Saving regenerates the composition; widgets bound to
that configuration update on next timeline tick.

### 9.4 Empty state (first run)

When no trackers exist, every widget renders an empty state:

```
   "macOS Stats Widget"
   "No trackers configured"
   [Open App ➜]
```

Tapping the deep-link button opens the main app's first-launch wizard
(see §15). No silent default scrape — the user is always in control of
what data the app pulls.

### 9.5 Configurable accents & status states

Each tracker carries an SF Symbol name, a hex accent colour, and a
label override. The widget reads these from `trackers.json`. Defaults
are sensible per-vendor (OpenAI green, Anthropic orange, etc., supplied
at first-run as part of the wizard's pre-filled templates).

- `.ok` — black/white text per appearance, accent on icon only.
- `.stale` — value still rendered but with 50% opacity + "stale" tag.
- `.broken` — red label, "?" icon, last-known value crossed out.

## 10. App Store path & entitlements

| Entitlement | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Required for App Store. |
| `com.apple.security.network.client` | `true` | In-app browser, embedded scraper, MCP socket, webhook POSTs all need outbound. |
| `com.apple.security.files.user-selected.read-write` | `true` | Export / import selector packs from a Finder picker. |
| `com.apple.security.application-groups` | `group.com.ethansk.macos-stats-widget` | Shared container with widget extension. |
| `com.apple.security.network.server` | *unset* | The MCP server uses stdio or a UNIX-socket path — neither needs the server entitlement. |
| `com.apple.security.device.audio-input` etc. | *unset* | We touch no AV devices. |

The widget extension's entitlements are a **subset**: only `app-sandbox`
and `application-groups`. No network. No file access outside the group.

**Review risks (and mitigations):**

1. *In-app browser scraping third-party sites.* App Store has accepted
   this pattern for password managers, Read Later apps, archive tools,
   and so on. We mirror their framing: "the widget acts on your behalf,
   with your credentials, on pages you can already see in your own
   browser."
2. *Persistent third-party cookies via `WKWebsiteDataStore`.* Standard
   API, well-precedented. No extra disclosure beyond a privacy-policy
   line.
3. *Embedded MCP server.* Uses stdio (no network) or a UNIX socket
   inside the App Group container (sandbox-permitted). No
   `network.server` entitlement required. The MCP surface is local to
   the user's machine — we explain this in the privacy disclosure.
4. *No private APIs in the widget extension.* Verified by automated
   lint pre-submission.
5. *No CLI in the App Store build.* The CLI is a **separate target**
   excluded from the App Store archive. Homebrew tap publishes the
   CLI artefact (separate repo: `homebrew-macos-stats-widget`).

The App Store submission is the *app + widget extension only* and is
**fully functional standalone**: it scrapes via
`NSBackgroundActivityScheduler`, self-heals via the bundled regex
fallback, and exposes its MCP server. The Homebrew CLI is a power-user
adjunct (custom schedules, headless server use, automated Codex
self-heal without user-confirm). Users who never install it get a
complete product.

## 11. Phased rollout

| Version | Deliverable |
|---|---|
| **v0.0.x** | Scaffold (PLAN.md, README, LICENSE, .gitignore). v0.0.3 = full requirements consolidation. No code. |
| **v0.1** | `project.yml` → xcodegen → Xcode project → empty app + empty widget extension + empty CLI all build green. CI smoke. |
| **v0.2** | Main app with Preferences UI; trackers list, add/edit form, no scraping yet. Local persistence to `trackers.json`. |
| **v0.3** | Element-capture flow working in the in-app browser. JS overlay, selector synthesis, preview pane, save round-trip. Sign-in / Re-sign-in / Reset Browser panel. |
| **v0.4** | App-internal scraping: NSBackgroundActivityScheduler firing per-tracker scrapes; Text mode write-out. App Group `readings.json` round-trip. |
| **v0.5** | Widget reads from App Group; Text mode renders with sparkline; configurable per-instance via Intent. Single-tracker widget shipped. |
| **v0.6** | Snapshot mode rendering on all three sizes. Long-lived session pattern, 2 s polling, takeSnapshot(of:rect). Cropper validated against fixture pages. |
| **v0.7** | Multi-tracker dashboard widget + WidgetConfigurations editor. Layouts: grid / stack / single. |
| **v0.8** | Self-heal: bundled regex fallback in the app. CLI integration for Codex / Claude when present. macOS native notification + generic webhook. |
| **v0.9** | Embedded MCP server (§13). Tools list + auth + transport selection. |
| **v0.10** | Quick-Setup Integration (§14): Claude / Codex skill installer buttons. |
| **v0.11** | First-Launch Flow (§15): CLI detection wizard, sign-in step, Identify Element, first widget. |
| **v0.12** | Selector packs (§7 of decisions): JSON export / import, Open-With + drag-drop in main app. |
| **v0.13** | Error states / fail-safe / `.broken` status / re-Identify flow. CLI scheduling polish (LaunchAgent installer). |
| **v1.0** | Polish, screenshots, GitHub Pages site, README setup walkthrough filled in. Codex-reviewed plan for any v1.x deltas (§16). |
| **v1.1** | App Store submission (app + widget extension only). |
| **v1.2** | Homebrew tap published (`homebrew-macos-stats-widget`). |
| **v1.3** | Public selector pack gallery (community contributions). |
| **v2.x** | Cross-browser support: Chrome via CDP, Firefox via Marionette. Same selector / capture flow, different transport. Optional, only if the WKWebView path proves limiting. |

Each minor version is a working, demoable build. We ship dogfood builds
between every two minors.

## 12. Resolved decisions

The seven open questions in the v0.0.1 plan, plus the follow-up
requirements raised in voice notes, are recorded here as resolved
decisions. Each entry: question / requirement → resolution → one-line
reasoning.

### Original 7 questions

**12.1 Notification path.**
*Question:* Telegram via dot-claude bot, or dedicated bot, or something
else?
*Resolution:* macOS native (`UNUserNotificationCenter`) by default,
*plus* an optional generic webhook (POST `{title, body, severity,
trackerId}` to any URL — Slack, Discord, Pushover, ntfy, n8n). **No
Telegram-specific code anywhere.**
*Reason:* Native notifications are zero-config and work for 90% of
users; the generic webhook covers the other 10% without locking us to
a single chat platform. §10 adds `com.apple.security.network.client`.

**12.2 Widget refresh budget.**
*Question:* Share WidgetKit's 40–72/day budget across trackers, or one
widget per tracker?
*Resolution:* Decouple. **Scrape schedule** is owned by the main app's
background helper (`NSBackgroundActivityScheduler`). **Widget timeline
reload** governs visual refresh only. Multi-tracker dashboard widget
*and* single-tracker widget are both first-class.
*Reason:* The two concerns have different cadences (scraping is
per-tracker, rendering is per-widget). Conflating them was the source
of the original constraint.

**12.3 Self-heal CLI order.**
*Question:* Codex first, Claude first, or user choice?
*Resolution:* **Codex primary** (`codex exec`, free for ChatGPT Plus
subscribers), **Claude Code fallback** (`claude -p`), **regex final
fallback** (numeric / $-amount / percentage tokens). User config
override available in Preferences.
*Reason:* Codex is the cheapest path for the user (already a Plus
subscriber). Claude Code is a high-quality fallback when Codex misses.
Regex covers the case where neither CLI is installed (App Store-only
users).

**12.4 Sparkline retention.**
*Question:* Last 24, last 7 days, last 30 days?
*Resolution:* Display last 24 readings (~12h at 30 min cadence). Retain
**7 days default** (336 points), **30 days max**. Per-tracker
configurable in Preferences.
*Reason:* Display window stays small for visual clarity; retention is
generous-but-bounded so power users can scroll a longer history without
ballooning the App Group file size.

**12.5 First-run experience.**
*Question:* Empty-state CTA, or silent default scrape?
*Resolution:* **Layered.** Widget empty-state CTA (deep-links into
main app). Main app first-launch wizard with **pre-filled templates**
(Codex `platform.openai.com/usage`; Claude `console.anthropic.com/settings/usage`).
User signs in + runs Identify Element themselves. **No silent default
scrape.**
*Reason:* Privacy-respecting, user-in-control, but with the fast path
(pre-filled templates) so the first tracker takes <60 s. Silent scrape
without user input is exactly the dark-pattern surface we want to
avoid.

**12.6 App Store + Homebrew.**
*Question:* Is App Store-only acceptable without auto-refresh?
*Resolution:* **Yes — main `.app` does its own scheduled scraping** via
sandbox-safe `NSBackgroundActivityScheduler`. App+widget standalone
fully functional. CLI = **power-user adjunct** (custom schedules,
headless server use, automated Codex self-heal without user-confirm).
*Reason:* `NSBackgroundActivityScheduler` is the right Apple-blessed
surface for "rerun this every N minutes" inside a sandboxed app. We
should never have made the CLI a hard dependency for basic operation.

**12.7 Selector packs.**
*Question:* Shareable JSON export?
*Resolution:* Yes — at v1.0. Format:
`{schemaVersion, name, url, mode, selector, cropRegion, label, icon,
hideElements}`. **Strictly no scripts** in the JSON (safe import — pure
data). Open-With + drag-drop into the main app. Export from each
tracker's settings. v1.1+ adds a public selector-pack gallery.
*Reason:* Users want to share "I tracked the Codex page like this";
forcing every user to repeat Identify Element for the same site is
silly. No-scripts policy guards against import-as-attack.

### Follow-up requirements (voice notes)

**12.8 Terminology cleanup.**
*Requirement:* The product is **not specifically about metrics** — it
tracks any text or visual region on a webpage. LLM usage is just the
canonical example.
*Resolution:* "metric" / "metrics" → **"tracker" / "trackers"**
throughout PLAN.md, the schema, variable names, and README. "Metric ID"
→ "tracker ID". "Metric history" → "tracker history". "Metric mode" →
"render mode". Any code module name change is folded into §4.
*Reason:* Naming the product around its narrow first use case
constrains everyone's mental model later. "Tracker" is generic and
honest about what the thing actually does.

**12.9 Render mode terminology.**
*Requirement:* Drop "Number mode" / "Screenshot mode" framing.
*Resolution:* Use **"Text mode"** (extracts `element.innerText` via JS,
renders as SwiftUI Gauge / Text in widget) and **"Snapshot mode"**
(captures screenshot of element's bounding rect via
`WKWebView.takeSnapshot(of:rect)`, renders as `Image()` in widget).
Both modes use the **same captured selector** — mode is render-time
behaviour, not capture-time behaviour. §5 schema, §6 capture flow, §9
widget UI all updated.
*Reason:* "Number" was a lie because text-mode handles non-numeric
text too. "Screenshot" implied a full-page capture, but we only ever
capture the element rect. Text/Snapshot is the accurate framing.

**12.10 Snapshot polling cadence.**
*Requirement:* Snapshot mode = **every 2 seconds** for live updates.
*Resolution:* Default 2 s for Snapshot mode; mechanism is a
**long-lived WKWebView session** that keeps the page loaded and only
re-snapshots the element rect each tick. Old snapshots are
overwritten in memory; **no file persistence** for snapshot history.
30 min reload heartbeat keeps the session fresh. Text mode default
stays 30 min. §7 fully details the long-lived pattern.
*Reason:* 2 s reload-from-scratch would be hostile to target sites
(429s, CDN load) and slower than the polling interval. Long-lived
session is cheap (one open page per tracker, capped at 8 concurrent)
and gives near-realtime visuals.

**12.11 Sign-in persistence APIs.**
*Requirement:* Use the proper macOS APIs for session persistence.
*Resolution:*
- `WKWebsiteDataStore(forIdentifier: "macos-stats-widget")` for the
  named persistent cookie / IndexedDB / localStorage profile.
- **Keychain Services API** for any user-entered credentials (rare,
  since most tracked sites are OAuth/SSO).
- **Passkey APIs** (`AuthenticationServices` framework,
  `ASWebAuthenticationSession`) where the site supports passkeys.
- Preferences panel: "Sign in / Re-sign in / Reset Browser" — clear
  cookies, switch profile, re-login any tracked site.
§3 (tech stack) + §6 (capture flow) + §9 (Preferences UX) reflect this.
*Reason:* Apple has correct primitives for each layer; we should use
them rather than rolling our own cookie store / credential storage.
Passkeys in particular are the future and we want first-class support
on day one.

**12.12 Multiple widget configurations.**
*Requirement:* A user can have **many distinct widget instances**, each
with its own composition.
*Resolution:* `widgetConfigurations` array in `trackers.json` with
shape `{id, name, size, [trackerIDs], layout, showSparklines,
showLabels}`. §5 schema reflects this. §9 widget UI describes the
prefs UX for creating / editing widget configurations and the
`IntentTimelineProvider` parameter for picking a configuration when
adding a widget.
*Reason:* Different parts of the desktop want different views (small
"just Codex spend" near the menu bar, large "AI Spend Dashboard" on a
secondary monitor). One config per widget instance is the right
granularity.

**12.13 Embedded MCP server.**
*Requirement:* The main `.app` exposes an MCP server so Codex CLI and
Claude Code can hook into it (list trackers, add trackers, kick off
Identify Element remotely, etc.).
*Resolution:* New §13 specifies the full tool set, transport choice
(stdio for sandboxed App Store path, UNIX socket for always-on local
use), and security model. The user's AI agent can say "add a tracker
for `https://example.com/balance`" and the app pops the in-app
browser, prompts the user for sign-in + Identify Element, then commits.
*Reason:* The whole product becomes much more useful when the user's
agents can manage it without the user clicking through Preferences.
This is the natural endpoint for "tracker as a generic concept".

**12.14 Quick-Setup buttons for Claude / Codex.**
*Requirement:* In Preferences, one-click buttons that install a SKILL.md
(Claude) and equivalent global instructions (Codex) teaching the agent
how to use the MCP server.
*Resolution:* New §14 specifies the skill content template, install
path resolution, idempotency, and the macOS notification on success.
*Reason:* Removes the "I need to manually wire up my CLI agent"
friction. The user installs the app, taps two buttons, and now their
local agents can talk to the widget.

**12.15 First-launch flow with CLI detection.**
*Requirement:* Detect which AI CLIs are installed and offer to install
the missing ones. If both are installed, let the user pick a default.
If neither, offer install links + "Skip for now" (self-heal degrades
to regex-only).
*Resolution:* New §15 specifies the four-step wizard ordering: CLI
detection → browser sign-in → Identify Element → widget add.
Re-runnable from Preferences via "Detect AI CLIs".
*Reason:* The product has nontrivial dependencies on the AI CLIs for
self-heal. Surfacing that on first launch is honest about the trade-off
and gives the user a path to a fully-functional install.

**12.16 No agent chat panel.**
*Requirement:* Confirm there is **no agent chat panel UI** in the app.
*Resolution:* Confirmed. The MCP server (§13) is the agent surface;
the agent runs in the user's existing CLI session (Codex / Claude
Code), not inside our app. We render no chat UI.
*Reason:* Building a chat surface is a huge product decision and well
outside the "quiet number on the desktop" scope. The MCP integration
covers the same intent (agent can manage trackers) without us shipping
a chat client.

## 13. MCP Server

The main `.app` ships an embedded MCP server. AI CLIs (Codex, Claude
Code, anything else that speaks MCP) connect to it and operate the
tracker fleet.

### 13.1 Transport

Two transports, picked at startup based on caller context:

- **Stdio.** When invoked as a child process (`open -a "macOS Stats
  Widget" --args --mcp-stdio` or, more commonly, the agent's MCP
  config points to the `.app/Contents/MacOS/macos-stats-widget-mcp`
  binary). JSON-RPC 2.0 over stdin / stdout. **App Store-safe** — no
  socket, no listener, no network entitlement.
- **UNIX domain socket.** When the main app is already running, it
  binds a socket at
  `~/Library/Group Containers/<group-id>/mcp.sock` and serves the same
  JSON-RPC. CLIs can connect without re-launching the app. Sandbox
  permits sockets inside the App Group container.

The agent picks one — typically stdio when the agent's MCP config
defines a server, socket for power users who run the app full-time.

### 13.2 Tools (initial set)

| Tool | Signature | Description |
|---|---|---|
| `list_trackers` | `() → [Tracker]` | Return all trackers with current values, status, last-updated. |
| `get_tracker` | `(id: string) → Tracker & {history}` | Current value + sparkline history + full config. |
| `add_tracker` | `(name, url, renderMode, selector, …) → {id}` | Add a new tracker. Selector required if known; if absent, agent should call `identify_element` instead. |
| `update_tracker` | `(id, fields…) → Tracker` | Modify name, label, icon, refresh interval, etc. |
| `delete_tracker` | `(id) → {ok}` | Remove a tracker (also removes from any `widgetConfigurations`). |
| `update_selector` | `(id, newSelector) → Tracker` | Apply a self-healed selector. Used by external Codex / Claude to commit a fix. |
| `trigger_scrape` | `(id) → TrackerResult` | Force-refresh one tracker now. |
| `identify_element` | `(url) → {trackerId, status: "awaiting_user"}` | Open the in-app browser at `url`, prompt the user for sign-in + Identify Element. Returns immediately; the agent can poll `get_tracker` until status flips. |
| `list_widget_configurations` | `() → [WidgetConfiguration]` | All widget compositions. |
| `update_widget_configuration` | `(id, fields…) → WidgetConfiguration` | Rename, resize, reorder trackers, change layout. |
| `export_selector_pack` | `(trackerId) → SelectorPackJSON` | Serialize one tracker as a sharable selector pack. |
| `import_selector_pack` | `(json) → {trackerId}` | Add a tracker from a selector pack. |

Future tools (post-v1, listed here for visibility): `pause_tracker`,
`resume_tracker`, `get_heal_history`, `attach_webhook`,
`bulk_export`, `bulk_import`.

### 13.3 Authentication

- **Stdio** transport requires no auth — the parent process spawned
  us, file-system permissions are already enforced.
- **UNIX socket** transport uses two layers:
  1. **File permissions.** The socket is created mode `0600` owned by
     the user. Only the user's own processes can connect.
  2. **Shared-secret handshake.** On `initialize`, the client must send
     a token stored in Keychain under
     `mcp-secret/macos-stats-widget`. The token is regenerated on each
     app launch and exposed to the user via Preferences → Quick Setup
     (§14) so the SKILL.md / global-instructions install can write it
     into the agent's MCP config.

### 13.4 Security considerations

- `identify_element` always requires a **human in the loop** — the
  agent cannot silently add a tracker; the user must complete the
  capture flow. This prevents an agent (compromised or otherwise)
  from quietly tracking new pages.
- `delete_tracker` and `update_widget_configuration` are
  destructive; the app rate-limits them (max 10 per minute per
  session) and surfaces an undo toast.
- All scrape URLs are validated as `https://` only (or `http://localhost`
  for testing). No `file://`, no `javascript:`.
- The MCP server logs every tool invocation to
  `~/Library/Logs/macOS Stats Widget/mcp.log` with timestamp, tool
  name, argument fingerprint (no sensitive values). Users can audit
  what their agents have done.

## 14. Quick-Setup Integration

Preferences → Quick Setup pane has two big buttons that wire the user's
local AI agents into the MCP server with a single click each.

### 14.1 "Set up Claude Code"

Writes a `SKILL.md` to `~/.claude/skills/macos-stats-widget/SKILL.md`.
Idempotent — re-running just overwrites the file with the latest
template. On success, posts a macOS native notification:
"Claude skill installed at `~/.claude/skills/macos-stats-widget/SKILL.md`".

**Skill template (sketch):**

```markdown
---
name: macos-stats-widget
description: Manage trackers and widget configurations in the macOS
  Stats Widget app. Use when the user asks to add, edit, or remove a
  tracker; check current values; trigger a manual refresh; or share a
  selector pack.
---

# macOS Stats Widget skill

This skill connects to the MCP server embedded in the macOS Stats
Widget app. The MCP socket is at
`~/Library/Group Containers/<group-id>/mcp.sock` and the auth token is
in Keychain under `mcp-secret/macos-stats-widget`.

## Tools available

- `list_trackers` — see what's being tracked.
- `get_tracker(id)` — current value + history + config.
- `add_tracker(name, url, renderMode, selector, …)` — add one.
- `identify_element(url)` — kick off the in-app browser; user picks the
  element. Use when the user gives you a URL and asks you to track it.
- `trigger_scrape(id)` — force a refresh now.
- `update_selector(id, newSelector)` — apply a self-heal fix.
- `list_widget_configurations`, `update_widget_configuration` —
  manage dashboard widget compositions.
- `export_selector_pack(trackerId)` / `import_selector_pack(json)`
  — share configs across machines.

## Examples

- "Track my AWS bill" → call `identify_element("https://console.aws.amazon.com/billing/")`.
- "What's my Codex spend?" → `list_trackers`, find the Codex one,
  `get_tracker(id)`.
- "Add a small widget for my GPU temp tracker" →
  `update_widget_configuration` to create a new small / single
  config containing that tracker.
```

### 14.2 "Set up Codex"

Writes the equivalent global instruction file at the path Codex CLI
looks up for global custom instructions. As of writing, the canonical
location is one of:

- `~/.codex/instructions/macos-stats-widget.md`
- `~/.config/codex/instructions/macos-stats-widget.md`
- `~/.codex/AGENTS.md` (appended block)

The button resolves the path at install time by checking which of
these exist and which Codex picks up (running `codex --print-config` if
available). If ambiguous, the install panel shows a dropdown so the
user can pick. Same content as the Claude skill, reformatted for
Codex's instruction style. Same idempotency, same success
notification.

> Open item: confirm Codex CLI's global-instructions path before v0.10
> ships. If both paths are valid, write to both.

### 14.3 Post-install notification

After either install completes:

```
[macOS Stats Widget]
Skill installed at /Users/ethan/.claude/skills/macos-stats-widget/SKILL.md
Your Claude Code sessions can now manage trackers via MCP.
```

The notification has an action button: "Open SKILL.md" (reveal in
Finder). Re-running the install replaces the file in place; no version
bumps required (the skill is content-addressed, not versioned).

### 14.4 Auth-token rotation

The MCP shared secret regenerates on each app launch (§13.3). The
Quick-Setup install flow writes the *current* token into the SKILL.md
front-matter or a sibling `.env` file. If the user restarts the app,
they must re-run Quick Setup. Future enhancement (§v0.11+): a
launchd-survivable token, or "trust this skill installation" toggle
that pins the token until manually invalidated.

## 15. First-Launch Flow

A four-step wizard the user sees on first app launch. Each step is
skippable; skipping degrades the experience but never blocks the
install.

### Step 1 — Detect AI CLIs

```
┌─ Welcome to macOS Stats Widget ────────────────────────────────┐
│  Self-heal works best with an AI CLI installed.                 │
│                                                                 │
│  ✓ codex   v0.42.0    detected via `which codex`                │
│  ✓ claude  v1.4.0     detected via `which claude`               │
│                                                                 │
│  Both are installed. Self-heal will use Codex first, Claude as  │
│  fallback. You can change this in Preferences → Self-Heal.      │
│                                                                 │
│              [ Skip ]              [ Next ➜ ]                    │
└─────────────────────────────────────────────────────────────────┘
```

Detection mechanics:

1. `which codex` → if found, run `codex --version` to confirm it's a
   real binary, capture version string.
2. `which claude` → same.
3. Outcomes:
   - **Both found** → user picks preferred / fallback order. Default
     is Codex primary.
   - **One found** → silently configure that one as default; surface
     in settings.
   - **Neither found** → step shows install links (Codex docs, Claude
     Code download), plus a "Skip for now" option (self-heal degrades
     to regex-only).
4. Result is written to `preferences.detectedCLIs` and
   `preferences.selfHealCLIPriority` in `trackers.json`.

Re-runnable from Preferences → Self-Heal → "Detect AI CLIs".

### Step 2 — Sign in to first tracked site

```
┌─ Sign in ──────────────────────────────────────────────────────┐
│  Pick a starter template or pick your own URL:                  │
│                                                                 │
│   [ Codex usage          (platform.openai.com/usage)        ]   │
│   [ Claude Code spend    (console.anthropic.com/settings/…) ]   │
│   [ Custom URL …                                            ]   │
│                                                                 │
│  The in-app browser will open. Sign in with your usual method   │
│  (Google, passkey, email/password — we use the standard         │
│  WebKit profile so SSO just works).                             │
│                                                                 │
│              [ Skip ]              [ Open browser ]              │
└─────────────────────────────────────────────────────────────────┘
```

Picking a starter pre-fills the URL but the user still signs in
themselves. We never store credentials; cookies persist via
`WKWebsiteDataStore(forIdentifier: "macos-stats-widget")`. Passkey
flows route through `ASWebAuthenticationSession`.

### Step 3 — Identify Element

The standard capture flow from §6, walked through with inline
guidance: "Hover the value you want to track. Click to select. We'll
preview the result on the next screen."

The user picks render mode (Text / Snapshot), names the tracker, sets
SF Symbol + accent. Save commits to `trackers.json`.

### Step 4 — Add a widget

```
┌─ Drop a widget on your desktop ────────────────────────────────┐
│  We just made your first widget configuration:                  │
│                                                                 │
│   "Codex Only" — Small — single tracker                         │
│                                                                 │
│  How to add it:                                                 │
│   1. Right-click the desktop ➜ Edit Widgets                     │
│   2. Search "macOS Stats Widget"                                │
│   3. Drag the small one onto your desktop                       │
│   4. Pick "Codex Only" from the configuration picker            │
│                                                                 │
│              [ I'll do this later ]    [ Done ]                  │
└─────────────────────────────────────────────────────────────────┘
```

The wizard ends. The user can re-open it any time from Help → "Show
First-Launch Wizard".

## 16. Pre-implementation TODO

Before implementation kickoff (i.e. before tagging v0.1 and writing the
first line of Swift), run the **full PLAN.md** through Codex review:

```
codex review PLAN.md
```

…or, if running inside Claude Code, invoke the `pre-commit-codex-review`
skill against the staged plan diff. Codex reads the plan, flags
ambiguities, missing-piece risks, and contradictions. Claude applies
the fixes / clarifications. Loop until LGTM.

If the review surfaces material changes — new sections, schema bumps,
flow rewrites — bump the tag (v0.0.4, v0.0.5, …) before implementation
starts. Final pre-code tag is whatever Codex signs off on, not v0.0.3
by default.

Specific things to validate in that review:

- Are the schema migrations (1 → 2 → 3) actually safe / lossless?
- Is `NSBackgroundActivityScheduler` the right surface, or should we
  also consider `BGAppRefreshTask`-style alternatives on macOS 14+?
- Does the long-lived snapshot session interact poorly with
  `WKProcessPool` reuse?
- Are the MCP tool signatures stable enough to not break agents on
  v1.0?
- Is the Quick-Setup auth-token rotation good UX, or is it a footgun?
- Is "App Store + Homebrew" framing legally clean (no implication that
  the App Store version *requires* Homebrew)?

Post-review, this section gets either ticked off or replaced with a
"Codex review highlights" sub-section before we cut v0.1.
