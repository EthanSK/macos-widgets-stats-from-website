# macOS Stats Widget

**See any number on any logged-in webpage at a glance — without opening another tab.**

[![Status](https://img.shields.io/badge/status-planning-orange.svg)](PLAN.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2014%2B-blue.svg)](#)

A native macOS WidgetKit app that surfaces scraped values from any web page you
log into — Codex usage, Claude Code spend, OpenAI dashboard, your AWS bill,
your bank balance, anything that has a number or visual region on a page.
Configure it once with a click-to-pick element flow, and the widget keeps
refreshing in the background.

> **Status:** Planning. No code yet. Read [PLAN.md](PLAN.md) for the canonical
> v0.0.4 architecture proposal. Implementation starts at v0.1 once the plan is
> signed off.

---

## Quick install

```bash
# Mac App Store (eventually) — primary distribution path
open "macappstore://apps.apple.com/app/macos-stats-widget"

# Homebrew tap (eventually) — optional CLI for headless / power-user setups
brew install ethansk/macos-stats-widget/macos-stats-widget
```

For now there is nothing to install. The repo currently contains the design
plan, license, and scaffolding only.

## Configuration

The widget reads a JSON config from
`~/Library/Application Support/macOS Stats Widget/trackers.json`. Each tracker
has a target URL, a CSS selector or element bounding rect, a refresh interval,
and a render mode (Text or Snapshot). See
[PLAN.md §5 Configuration schema](PLAN.md#5-configuration-schema) for the full
shape and migration strategy.

## Setup walkthrough

Once the UI exists, the flow will be:

1. Open **macOS Stats Widget.app**.
2. Click **+ Add tracker** in Preferences.
3. The in-app browser opens. Sign in to the page you want to track.
4. Click **Identify Element**, hover the value on the page until it lights up,
   click to capture.
5. Pick **Text** or **Snapshot** mode, set a refresh interval, save.
6. Add the widget to your desktop or notification centre. The value appears.

The full walkthrough — including screenshots and the exact UX state machine —
will be filled in once the UI is built. See
[PLAN.md §6 Element-capture UX flow](PLAN.md#6-element-capture-ux-flow) for
the design.

## Wiring up an AI agent (optional)

The app embeds an MCP server. Any external MCP client — your Codex CLI, Claude
Code session, or anything else that speaks MCP — can connect to it and manage
trackers, trigger scrapes, or apply self-heal fixes. The app itself never
spawns AI binaries; agent involvement always runs in your own agent's session.
See [PLAN.md §13 MCP Server](PLAN.md#13-mcp-server) for transport, auth, and
the tool catalog.

## Caveats

- **Scrapes via in-app browser.** The app signs in *as you* via a sandboxed
  WKWebView profile. Cookies stay on your machine. No third-party server is
  involved. If a site changes its layout the app prompts you to re-Identify
  the element, with a regex fallback to keep showing *something* until you
  fix it. (See [PLAN.md §8 Self-heal flow](PLAN.md#8-self-heal-flow).)
- **macOS has no widget reload budget.** Apple's per-instance ~40–72/day cap
  is iOS-only ([Apple forum 711091](https://developer.apple.com/forums/thread/711091)).
  On macOS the app refreshes the widget whenever a meaningful new reading
  lands — see [PLAN.md §9.2](PLAN.md#9-widget-ui).
- **Not affiliated with OpenAI, Anthropic, or any other vendor.** This is a
  user tool that reads pages you can already see in your own browser.
- **TOS responsibility is yours.** Some sites disallow scraping in their
  terms. The app treats every site equally; you decide what to point it at.

## License

[MIT](LICENSE) — copyright Ethan Sarif-Kattan, 2026.

## Build (v0.1)

```bash
brew install xcodegen
xcodegen
open MacosStatsWidget.xcodeproj
# or for headless build:
xcodebuild -project MacosStatsWidget.xcodeproj -scheme MacosStatsWidget -configuration Debug build
```

## Acknowledgments

- **[CodexBar](https://github.com/steipete/CodexBar)**, **[MeterBar](https://meterbar.app/)**,
  **[iStat Menus](https://bjango.com/mac/istatmenus/)**,
  **[TokenTracker](https://github.com/mm7894215/TokenTracker)** — design
  patterns the widget catalog draws from. See
  [PLAN.md §9.4 Design lineage](PLAN.md#9-widget-ui).
- **[coding_agent_usage_tracker (caut)](https://github.com/Dicklesworthstone/coding_agent_usage_tracker)**
  — for the priority-ordered fallback chain pattern (CLI → web → OAuth → API
  → local logs).
- **[Producer Player](https://github.com/EthanSK/producer-player)** — for the
  setup-instruction tone, monorepo layout discipline, and the Mac App Store
  submission roadmap pattern.
- Apple's WidgetKit team for shipping a real macOS widget surface.
