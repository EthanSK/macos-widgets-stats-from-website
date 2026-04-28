# macOS Stats Widget — Plan

> Living design document. Implementation begins at v0.1 once this is signed
> off. Word-budget target: 2,000–4,000. Concrete > comprehensive.

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
- **Menu-bar status item** is too cramped for multiple metrics and doesn't
  compose well visually. SF Symbols + a single number is fine for one stat,
  but I want four to eight.
- **Browser extension** doesn't show on my desktop and dies when the browser
  is closed.
- **Widget** is the native macOS surface for "passive number on screen", has
  WidgetKit's timeline + Intents API for refresh, and supports SwiftUI for
  rich rendering (gauges, sparklines, cropped images).

The product is therefore: **a macOS WidgetKit widget that displays scraped
numbers from any logged-in web page, configured once via a click-to-pick
element flow, refreshing on a per-metric schedule, with a self-healing
fallback when sites change their layout**.

It is a personal tool first and a public open-source project second. The
public artefact has to clear App Store review (so the **app + widget**
clear) and ship via Homebrew for the **CLI** (which would not clear App
Store review).

## 2. Architecture overview

Three components share a single App Group:

| Component | Type | Responsibility | Ships via |
|---|---|---|---|
| **Main app** | `.app` (AppKit shell + SwiftUI) | Preferences UI, in-app browser, element-capture flow, login persistence, manual scrape trigger | Mac App Store |
| **Widget extension** | WidgetKit extension inside the `.app` | Reads metrics from App Group on each timeline tick, renders Number or Screenshot | Mac App Store (bundled) |
| **CLI scraper** | Standalone executable | Headless WKWebView scrape, schedule + throttle, App Group writes, Codex CLI self-heal | Homebrew tap |

```
   ┌──────────────────────────┐         ┌────────────────────────┐
   │  Main App (sandbox)      │         │  CLI Scraper           │
   │  - Preferences UI        │         │  - WKWebView headless  │
   │  - In-app browser        │         │  - launchd schedule    │
   │  - Element capture       │         │  - Codex self-heal     │
   │  - Manual "scrape now"   │         │  - HTML snapshot dump  │
   └────────────┬─────────────┘         └───────────┬────────────┘
                │                                   │
                │   reads & writes                  │   writes only
                │                                   │
                ▼                                   ▼
        ┌────────────────────────────────────────────────┐
        │      App Group: group.com.ethansk.             │
        │             macos-stats-widget                 │
        │   ~/Library/Group Containers/<group-id>/       │
        │   ├─ metrics.json     (config; written by app) │
        │   ├─ readings.json    (latest values + sparklines) │
        │   ├─ screenshots/<metric-id>.png               │
        │   └─ schema-version                            │
        └─────────────────┬──────────────────────────────┘
                          │
                          │  reads only, on timeline tick
                          ▼
              ┌────────────────────────────┐
              │  Widget Extension          │
              │  - Number / Screenshot     │
              │  - Sparkline               │
              │  - Animated transitions    │
              └────────────────────────────┘
```

**Data flow is unidirectional from CLI to widget.** The main app owns the
*config*; the CLI owns the *readings*; the widget only *reads*. This keeps
each process's responsibilities clear and avoids races on the App Group.

**Process boundaries (App Store sandbox implications):**

- The widget extension runs sandboxed and has *no* network entitlement. It
  only reads local files in the App Group container. This is critical for
  App Store acceptance.
- The main app has the network-client entitlement (so the in-app browser
  works) but does **not** spawn the Codex CLI. Spawning external binaries
  from a sandboxed app is brittle and a review-risk; we keep self-heal in
  the CLI binary, which is unsandboxed Homebrew-shipped.
- The CLI is a regular macOS executable. It has full disk access (via
  user-granted TCC) and can spawn `codex` / `claude`. It writes into the
  App Group container path, which is shared because the App Group ID is
  declared in both the app's entitlements and the CLI's runtime
  configuration (the App Group path is just a directory; the CLI doesn't
  need entitlements to write there as long as it knows the path).

## 3. Tech stack & rationale

- **Swift 5.9+**, targeting macOS 14+ (Sonoma). WidgetKit on macOS got
  significantly better in 14, and 14+ covers ~95% of active Macs by the
  time we ship.
- **SwiftUI** for Preferences UI and the widget itself. **AppKit** shell for
  the main app window (window-management features SwiftUI still doesn't
  cover well: hidden-when-closed dock icon, window restoration, menu-bar
  niceties).
- **WidgetKit** with `TimelineProvider` + `IntentTimelineProvider` (so users
  can configure which metric a given widget instance shows).
- **WKWebView** as the scraping engine (both in the in-app browser and the
  CLI's headless path). Reasons over Chromium-portable / Playwright:
  - Size: WKWebView is the system framework, zero added MB.
  - App Store risk: bundling Chromium in a sandboxed app is a non-starter.
  - Updates: WebKit is patched by the OS; we never ship a stale browser.
  - Cookie persistence: `WKWebsiteDataStore(forIdentifier:)` gives us a
    named persistent profile out of the box.
- **App Group** over UserDefaults / iCloud / Keychain:
  - UserDefaults: scoped to a single bundle ID by default; cross-process
    sharing requires `suiteName` which is exactly what App Group provides
    *for plists*, but we want JSON + PNG too.
  - iCloud: latency, conflict resolution, and offline behaviour are wrong
    for a refresh-every-30-min widget.
  - Keychain: only for the few credentials we may eventually need (e.g.
    Telegram bot token); not the right surface for readings.
- **xcodegen** (`project.yml`) for the Xcode project so we never commit
  `.xcodeproj` to git — it's a regenerated artefact. Keeps diffs sane.
- **launchd LaunchAgent** for CLI scheduling (one user-level agent that runs
  the CLI binary, which then iterates metrics internally). Simpler and more
  reliable than each-metric-its-own-agent.

## 4. Module structure

```
MacosStatsWidget/
  Apps/
    MainApp/
      MacosStatsWidgetApp.swift       — app entry, scene wiring
      AppDelegate.swift               — menu bar / dock icon control
      PreferencesWindow.swift         — main preferences container
      MetricsListView.swift           — list of configured metrics
      MetricEditorView.swift          — add/edit metric form
      InAppBrowserView.swift          — WKWebView host with Identify Element
      InspectOverlayJS.swift          — JS string for hover/click overlay
      OnboardingView.swift            — first-run welcome
    WidgetExtension/
      MacosStatsWidgetBundle.swift    — registers the widget
      StatsWidget.swift               — TimelineProvider + entry view
      NumberWidgetView.swift          — Number-mode rendering
      ScreenshotWidgetView.swift      — Screenshot-mode rendering
      SparklineView.swift             — last-N reading sparkline
      WidgetIntent.swift              — IntentDefinition for metric picking
    CLI/
      main.swift                      — argument parsing (Codable args)
      ScrapeCommand.swift             — `scrape` subcommand
      SelfHealCommand.swift           — `self-heal` subcommand (manual run)
      Scheduler.swift                 — top-level loop, throttle, jitter
      LaunchdInstaller.swift          — install/remove LaunchAgent plist
  Shared/
    Models/
      Metric.swift                    — Metric struct (config row)
      MetricResult.swift              — last reading + history
      MetricMode.swift                — .number | .screenshot
      MetricStatus.swift              — .ok | .stale | .broken
    AppGroup/
      AppGroupPaths.swift             — typed paths into the container
      AppGroupStore.swift             — atomic JSON read/write helpers
      SchemaVersion.swift             — current version + migrators
    Scraping/
      HeadlessScraper.swift           — WKWebView wrapper (used by app+CLI)
      ProfileManager.swift            — WKWebsiteDataStore identifier mgmt
      SelectorRunner.swift            — runs a CSS selector, returns text
      ScreenshotCropper.swift         — element bbox -> PNG crop
    SelectorHeal/
      CodexCLIInvoker.swift           — spawns codex/claude, captures stdout
      HealPrompt.swift                — prompt template constants
      HealValidator.swift             — sanity-check proposed selector
      HealNotifier.swift              — Telegram + macOS notification
  Tests/
    SharedTests/                      — unit tests for pure types
    ScrapingTests/                    — fixture-HTML based selector tests
    HealTests/                        — mock CodexCLIInvoker tests
  scripts/
    bootstrap.sh                      — one-shot dev setup
    package-cli.sh                    — produces a Homebrew-ready tarball
  project.yml                         — xcodegen project definition
```

One-line responsibility per file is the discipline we keep — if a file
needs more than one line to describe, it's doing too much and we split it.

## 5. Configuration schema

Stored at `~/Library/Application Support/macOS Stats Widget/metrics.json`
(the **canonical config** — the App Group container holds a *copy* the CLI
reads, written atomically by the main app).

```jsonc
{
  "schemaVersion": 1,
  "metrics": [
    {
      "id": "8c1b2e6e-…",                 // UUID, immutable
      "name": "Codex weekly spend",
      "url": "https://platform.openai.com/usage",
      "browserProfile": "openai",         // WKWebsiteDataStore identifier
      "mode": "number",                   // "number" | "screenshot"
      "selector": "div[data-testid=\"weekly-cost\"] span",
      "cropRegion": null,                 // only set when mode == "screenshot"
      "elementBoundingBox": {              // captured for screenshot fallback
        "x": 480, "y": 312, "width": 96, "height": 28,
        "viewportWidth": 1280, "viewportHeight": 800,
        "devicePixelRatio": 2
      },
      "refreshIntervalSec": 1800,         // 30 min default
      "label": "Codex",                   // display label override
      "icon": "dollarsign.circle.fill",    // SF Symbol name
      "accentColorHex": "#10a37f",
      "valueParser": {
        "type": "currencyOrNumber",       // "currencyOrNumber" | "percent" | "raw"
        "stripChars": ["$", ",", " "]
      },
      "lastHealedAt": null,
      "selectorHistory": []               // {selector, replacedAt} entries
    }
  ]
}
```

Readings live in a separate file (App Group only, never in user docs):

```jsonc
// readings.json
{
  "schemaVersion": 1,
  "readings": {
    "<metric-id>": {
      "currentValue": "$42.18",
      "currentNumeric": 42.18,
      "lastUpdatedAt": "2026-04-28T14:02:13Z",
      "status": "ok",
      "sparkline": [38.4, 39.1, 40.0, 42.0, 42.18],
      "lastError": null
    }
  }
}
```

**Versioning strategy.** `schemaVersion` is a monotonic integer. On app
launch we read both files, compare against `currentSchemaVersion = N`, and
run forward migrators (`Migrator_1_to_2`, `Migrator_2_to_3` …). Migrators
are pure functions. We never delete fields; we add an optional `deprecated`
flag and stop reading them. Backward migration is not supported — once
upgraded, downgrade requires restoring the prior `metrics.json` from the
last `metrics.json.bak`. The CLI keeps three rotating backups.

## 6. Element-capture UX flow

```
[Preferences]
   ├─ user clicks "+ Add metric"
   ▼
[New Metric — Step 1: Browse]
   ├─ embedded WKWebView, full chrome (back/forward/reload/url-bar)
   ├─ user signs in (cookies persisted via WKWebsiteDataStore identifier)
   ├─ user navigates to the page that has the number
   ▼
[New Metric — Step 2: Identify Element]
   ├─ user clicks "Identify Element" toolbar button
   ├─ JS injects an InspectOverlay (mouseover outline, click trap)
   ├─ user hovers — element under cursor gets 2px solid outline
   ├─ user clicks — element selected, inspect mode exits
   ▼
[New Metric — Step 3: Preview]
   ├─ shows extracted text + screenshot crop side-by-side
   ├─ shows the synthesised CSS selector + bounding box
   ├─ user picks Number or Screenshot mode
   ├─ user names the metric, picks SF Symbol + colour
   ├─ user picks refresh interval (slider: 5min … 24h)
   ▼
[Save] → writes metrics.json, schedules CLI run, reload widget timeline
```

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
current DOM (does it return *exactly one* match? is the text non-empty?),
then commits.

## 7. Scraping strategy

- **Headless WKWebView.** `WKWebViewConfiguration` with
  `websiteDataStore = WKWebsiteDataStore(forIdentifier: profileUUID)`.
  Same profile UUID is used by both the in-app browser (when the user
  signs in) and the CLI (when it scrapes), so cookies just work.
- **Schedule.** Per-metric `refreshIntervalSec`. Default 30 min, min 5 min
  (anything under that is asking for a 429), max 24 hours.
- **Throttle + jitter.**
  - ±20% jitter on every scheduled run, smeared across the interval window.
  - Single in-flight scrape at any time across the whole CLI process. New
    scrapes queue.
  - 30-second minimum gap between scrapes — even if two metrics are due at
    the same second.
- **Backoff.** Exponential on HTTP 429 / 503: 5 min → 15 → 45 → 2h, cap at
  2h. Reset on next success.
- **Login flow.** User signs in via the in-app browser. We never touch
  credentials directly. Cookies persist via `WKWebsiteDataStore(forIdentifier:)`
  — same identifier in app and CLI ⇒ shared cookie jar.
- **Inspired by caut's fallback chain** (see Acknowledgments): the CLI
  doesn't *only* scrape. For supported sites we can later add OAuth /
  direct-API strategies as preferred sources, demoting browser scraping to
  the last-resort tier. v1 is browser-only.

## 8. Self-heal flow

**Trigger conditions** (any one fires the heal pipeline):

- Selector returns `null` / empty.
- Selector matches but text doesn't parse as a number / currency / percent
  per the metric's `valueParser`.
- Selector matches but the value is wildly out of range vs the last 5
  readings (configurable; off by default — too noisy).

**Pipeline:**

1. **Snapshot.** CLI dumps the current page HTML + the metric's history of
   selectors + the last good value to `~/Library/Application Support/macOS
   Stats Widget/heal-snapshots/<metric-id>-<ts>.html`.
2. **Spawn Codex.** `codex exec` (or `claude` if Codex unavailable) with
   the prompt template below. Working dir = the snapshot dir; stdin =
   prompt; stdout = response.
3. **Validate.** Parse Codex's response, expect a single CSS selector. Run
   it on the cached HTML via WKWebView. Confirm:
   - exactly one element matches,
   - extracted text parses as a number per `valueParser`,
   - the magnitude is within ~2 orders of the last good value.
4. **Commit.** Write the new selector into `metrics.json`, push the old
   one onto `selectorHistory`, set `lastHealedAt`, write the next reading
   normally.
5. **Notify.** macOS user notification + Telegram message via the
   dot-claude bot (open question — see §12). The Telegram message includes
   metric name, old selector, new selector, and a one-line heuristic
   diff ("text is now wrapped in `<span class="…-v2">`").
6. **Fail-safe.** If three consecutive heal attempts on the same metric
   fail, mark the metric `status = .broken` in `readings.json`. The widget
   renders a red label + "?" SF Symbol. The CLI stops auto-running heal on
   that metric until the user opens the app and re-runs Identify Element.

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

The Codex/Claude binary is invoked from the **CLI** only — never from the
sandboxed `.app`. This keeps the App Store target clean.

## 9. Widget UI

| Family | Size | Number mode | Screenshot mode |
|---|---|---|---|
| Small | 155×155 | Big number (Numeric `Text` with `contentTransition(.numericText())`); label below; SF Symbol top-right | Cropped image fills, label overlaid bottom-left |
| Medium | 329×155 | Number left + sparkline right; label + last-updated under | Cropped image left, side panel right with label + last-updated |
| Large | 329×345 | 2×2 multi-metric grid (up to 4) **or** single big metric with sparkline + history table | Single cropped image, full-bleed |

**Number mode** uses `Gauge` for percent-style metrics (where a sensible
0–100 mapping exists) and `Text` for free-form. Animated value transitions
via `.contentTransition(.numericText())` so updates don't pop.

**Screenshot mode** renders the cropped PNG produced by the CLI. The CLI
re-crops on every refresh so the bounding box can shift slightly with
content. `Image(...).interpolation(.high)` for resampling.

**Configurable accents.** Each metric carries an SF Symbol name, a hex
accent colour, and a label override. The widget reads these from
`metrics.json`. Defaults are sensible per-vendor (OpenAI green, Anthropic
orange, etc., supplied at first-run).

**Status states.**

- `.ok` — black/white text per appearance, accent on icon only.
- `.stale` — value still rendered but with 50% opacity + "stale" tag.
- `.broken` — red label, "?" icon, last-known value crossed out.

## 10. App Store path & entitlements

| Entitlement | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Required for App Store. |
| `com.apple.security.network.client` | `true` | In-app browser needs to load arbitrary URLs. |
| `com.apple.security.files.user-selected.read-write` | `true` | Export/import metrics config from a Finder picker. |
| `com.apple.security.application-groups` | `group.com.ethansk.macos-stats-widget` | Shared container with widget extension. |
| `com.apple.security.network.server` | *unset* | We don't run a server. |
| `com.apple.security.device.audio-input` etc. | *unset* | We touch no AV devices. |

The widget extension's entitlements are a **subset**: only `app-sandbox`
and `application-groups`. No network. No file access outside the group.

**Review risks (and mitigations):**

1. *In-app browser scraping third-party sites.* App Store has accepted this
   pattern for password managers, Read Later apps, archive tools, and so
   on. We mirror their framing: "the widget acts on your behalf, with your
   credentials, on pages you can already see in your own browser."
2. *Persistent third-party cookies via `WKWebsiteDataStore`.* Standard
   API, well-precedented. No extra disclosure beyond a privacy-policy
   line.
3. *No private APIs in the widget extension.* Verified by automated lint
   pre-submission.
4. *No CLI in the App Store build.* The CLI is a **separate target** that
   is **excluded** from the App Store archive. Homebrew tap publishes the
   CLI artefact (separate repo: `homebrew-macos-stats-widget`).

The App Store submission is the *app + widget extension only*. The CLI
ships via Homebrew. Some functionality (self-heal, scheduled scraping)
requires both the app *and* the CLI; the app's first-run UI tells the user
to `brew install` the CLI as part of setup. This is an explicit trade-off
and §12 raises it as a question.

## 11. Phased rollout

| Version | Deliverable |
|---|---|
| **v0.0.x** | Scaffold (this PLAN.md, README, LICENSE, .gitignore). No code. |
| **v0.1** | `project.yml` → xcodegen → Xcode project → empty app + empty widget extension + empty CLI all build green. CI smoke. |
| **v0.2** | Main app with Preferences UI; metrics list, add/edit form, no scraping yet. Local persistence to `metrics.json`. |
| **v0.3** | Element-capture flow working in the in-app browser. JS overlay, selector synthesis, preview pane, save round-trip. |
| **v0.4** | CLI `scrape` subcommand: takes a metric ID, runs one scrape, writes to App Group `readings.json`. Exits. |
| **v0.5** | Widget reads from App Group; Number mode renders with sparkline; configurable per-instance via Intent. |
| **v0.6** | Screenshot mode rendering on all three sizes. Cropper validated against fixture pages. |
| **v0.7** | Self-heal CLI integration. Codex spawn, prompt template, validator, commit, history. Telegram + macOS notification. |
| **v0.8** | Scheduling + throttling. LaunchAgent installed by the app's first-run flow. Jitter, backoff, single-flight. |
| **v0.9** | Error states / fail-safe / `.broken` status / re-Identify flow. |
| **v1.0** | Polish, screenshots, GitHub Pages site, README setup walkthrough filled in. |
| **v1.1** | App Store submission (app + widget extension only). |
| **v1.2** | Homebrew tap published (`homebrew-macos-stats-widget`). |
| **v2.x** | Cross-browser support: Chrome via CDP, Firefox via Marionette. Same selector / capture flow, different transport. Optional, only if the WKWebView path proves limiting. |

Each minor version is a working, demoable build. We ship dogfood builds
for myself between every two minors.

## 12. Open questions for Ethan

1. **Telegram notification path.** Route self-heal events via the existing
   dot-claude Telegram bot (already authenticated, simplest), or stand up
   a dedicated bot for this widget so the channel is single-purpose?
2. **Widget refresh budget.** WidgetKit gives ~40–72 timeline updates per
   widget per day. With N metrics, do we (a) share that budget across all
   metrics in one widget, refreshing the *least-recently-updated* on each
   tick, or (b) recommend one widget instance *per* metric so each gets
   its own 40–72 budget? Option (b) is cleaner per metric but eats more
   desktop real estate.
3. **Codex CLI vs Claude Code CLI for self-heal.** Preference? Default to
   `codex exec` and fall back to `claude` if not on PATH? Or the reverse?
4. **Sparkline data retention.** Last 24 readings (≈ last 12h at 30-min
   default), last 7 days (336 readings), or last 30 days (1,440 readings)?
   Higher retention = bigger App Group file = slower widget reads.
5. **First-run scrape behaviour.** When the app is installed but no metrics
   are configured, does the widget show an empty-state "Add your first
   metric" CTA, or does the app silently scrape a curated default set
   (Codex weekly spend, Claude Code spend, etc.) on first launch using
   a published list of pre-canned selectors?
6. **CLI install requirement.** App Store users who *don't* `brew install
   macos-stats-widget` get the app + widget but no auto-refresh and no
   self-heal — only "scrape now" from the app. Is that acceptable, or do
   we need an alternative auto-refresh path (e.g. a small background
   helper bundled inside the .app, sandboxed) for App Store-only users?
7. **Metrics export format.** Do we want metric configs to be
   shareable/importable JSON (so people can publish "selector packs" for
   common sites)? If yes, that's a v1.0 feature; if no, we keep the file
   user-private.
