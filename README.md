# macOS Stats Widget

**See your LLM spend at a glance — without opening another tab.**

[![Status](https://img.shields.io/badge/status-planning-orange.svg)](PLAN.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2014%2B-blue.svg)](#)

A native macOS WidgetKit widget that surfaces scraped numbers from any web page
you log into — Codex usage, Claude Code spend, OpenAI dashboard, your AWS bill,
your bank balance, anything that has a number on a page. Configure it once with
a click-to-pick element flow, and the widget keeps refreshing in the background.

> **Status:** Planning. No code yet. Read [PLAN.md](PLAN.md) for the full
> architecture proposal. Implementation starts at v0.1 once the plan is signed
> off.

---

## Quick install

```bash
# CLI scraper (eventually — Homebrew tap not yet published)
brew install ethansk/macos-stats-widget/macos-stats-widget

# Or download the .app from the Mac App Store (eventually)
```

For now there is nothing to install. The repo currently contains the design
plan, license, and scaffolding only.

## Configuration

The widget reads a JSON config from
`~/Library/Application Support/macOS Stats Widget/metrics.json`. Each metric
has a target URL, a CSS selector or screenshot crop region, a refresh interval,
and a display mode (Number or Screenshot). See
[PLAN.md §5 Configuration schema](PLAN.md#5-configuration-schema) for the full
shape and migration strategy.

## Setup walkthrough

Once the UI exists, the flow will be:

1. Open **macOS Stats Widget.app**.
2. Click **+ Add metric** in Preferences.
3. The in-app browser opens. Sign in to the page you want to track.
4. Click **Identify Element**, hover the number on the page until it lights up,
   click to capture.
5. Pick **Number** or **Screenshot** mode, set a refresh interval, save.
6. Add the widget to your desktop or notification centre. The number appears.

The full walkthrough — including screenshots and the exact UX state machine —
will be filled in once the UI is built. See
[PLAN.md §6 Element-capture UX flow](PLAN.md#6-element-capture-ux-flow) for
the design.

## Caveats

- **Scrapes via in-app browser.** The widget signs in *as you* via a sandboxed
  WKWebView profile. Cookies stay on your machine. No third-party server is
  involved. If a site changes its layout the widget self-heals via the local
  Codex CLI (see [PLAN.md §8](PLAN.md#8-self-heal-flow)).
- **Not affiliated with OpenAI, Anthropic, or any other vendor.** This is a
  user tool that reads pages you can already see in your own browser.
- **Don't put real-time-critical numbers in here.** WidgetKit gives ~40-72
  refresh slots per widget per day. The widget is for awareness, not alerts.
- **TOS responsibility is yours.** Some sites disallow scraping in their
  terms. The widget treats every site equally; you decide what to point it at.

## License

[MIT](LICENSE) — copyright Ethan Sarif-Kattan, 2026.

## Acknowledgments

- **[coding_agent_usage_tracker (caut)](https://github.com/Dicklesworthstone/coding_agent_usage_tracker)**
  — for the priority-ordered fallback chain pattern (CLI → web → OAuth → API
  → local logs) and the AI-driven debugging idea.
- **[Producer Player](https://github.com/EthanSK/producer-player)** — for the
  setup-instruction tone, monorepo layout discipline, and the Mac App Store
  submission roadmap pattern.
- Apple's WidgetKit team for shipping a real macOS widget surface.
