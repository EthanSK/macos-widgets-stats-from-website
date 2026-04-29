# macOS Widgets Stats from Website

**See any number on any logged-in webpage at a glance — without opening another tab.**

[![Status](https://img.shields.io/badge/status-v0.12.2-orange.svg)](PLAN.md)
[![Release](https://github.com/EthanSK/macos-widgets-stats-from-website/actions/workflows/release.yml/badge.svg)](https://github.com/EthanSK/macos-widgets-stats-from-website/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2013%2B-blue.svg)](#)
[![Website](https://img.shields.io/badge/website-ethansk.github.io-7eecaf.svg)](https://ethansk.github.io/macos-widgets-stats-from-website/)
[![Latest release](https://img.shields.io/github/v/release/EthanSK/macos-widgets-stats-from-website?include_prereleases&sort=semver&label=release&color=ffe27a)](https://github.com/EthanSK/macos-widgets-stats-from-website/releases)

A native macOS WidgetKit app that surfaces scraped values from any web page you
log into — Codex usage, Claude Code spend, OpenAI dashboard, your AWS bill,
your bank balance, anything that has a number or visual region on a page.
Configure it once with a click-to-pick element flow, and the widget keeps
refreshing in the background.

[Website](https://ethansk.github.io/macos-widgets-stats-from-website/) · [Architecture (PLAN.md)](PLAN.md) · [Issues](https://github.com/EthanSK/macos-widgets-stats-from-website/issues) · [Releases](https://github.com/EthanSK/macos-widgets-stats-from-website/releases)

> **Status:** v0.12.2 implements the local app, widget extension, CLI, scraping,
> snapshot rendering, widget template catalog, self-heal prompts, selector
> packs, MCP server, first-launch flow, and polish pass. Read
> [PLAN.md](PLAN.md) for the canonical architecture and roadmap.

---

## Build

```bash
brew install xcodegen
xcodegen
open MacosWidgetsStatsFromWebsite.xcodeproj

# Headless Debug builds:
xcodebuild -project MacosWidgetsStatsFromWebsite.xcodeproj -scheme MacosWidgetsStatsFromWebsite -configuration Debug DEVELOPMENT_TEAM=T34G959ZG8 build
xcodebuild -project MacosWidgetsStatsFromWebsite.xcodeproj -scheme MacosWidgetsStatsFromWebsiteWidget -configuration Debug DEVELOPMENT_TEAM=T34G959ZG8 build
xcodebuild -project MacosWidgetsStatsFromWebsite.xcodeproj -scheme MacosWidgetsStatsFromWebsiteCLI -configuration Debug DEVELOPMENT_TEAM=T34G959ZG8 build
```

The project uses Ethan's Apple Developer team for local signing. For compile-only
agent checks on machines without signing assets, pass `CODE_SIGNING_ALLOWED=NO`
on the command line. The app and widget targets are sandboxed and share data
through the App Group container.

## Updates

macOS Widgets Stats from Website uses Sparkle for automatic updates. Signed releases publish a
Sparkle appcast at
`https://ethansk.github.io/macos-widgets-stats-from-website/appcast.xml`; installed apps check
that feed daily and can also check on demand from **Check for Updates...** in
the app menu.

## Features

- Text and snapshot trackers for any page visible in the in-app WKWebView.
- Shared website data store between visible and headless browser sessions.
- Snapshot mode with long-lived page sessions, 2-second re-snapshotting, and a
  30-minute full reload heartbeat.
- Twelve WidgetKit templates for small, medium, large, and macOS 14 extra-large
  families, with separate widget configurations per widget instance.
- Self-heal prompts after repeated scrape failures, bundled numeric fallback
  extraction, and an audit log of selector-heal attempts.
- Embedded MCP server over stdio and a `0600` UNIX socket with Keychain-backed
  shared-token auth.
- Selector packs for importing and exporting trusted, script-free tracker
  definitions.
- First-launch wizard for signing in, identifying the first element, and adding
  the first widget.
- Widget polish: animated value changes, attention states, VoiceOver labels,
  Dynamic Type support, Reduce Motion respect, keyboard shortcuts, Dock badge,
  and placeholder app icon.

## Configuration

The widget reads a JSON config from
`~/Library/Application Support/macOS Widgets Stats from Website/trackers.json`. Each tracker
has a target URL, a CSS selector or element bounding rect, a refresh interval,
and a render mode (Text or Snapshot). Widget configurations live in the same
file as named instances with a size, template, and tracker list. See
[PLAN.md §5 Configuration schema](PLAN.md#5-configuration-schema) for the full
shape and migration strategy.

## Setup walkthrough

1. Open **macOS Widgets Stats from Website.app**.
2. On first launch, sign in to the first site in the in-app browser, or skip
   the wizard and open Preferences directly.
3. Click **Identify Element**, hover the value on the page until it lights up,
   click to capture.
4. Pick **Text** or **Snapshot** mode, set a refresh interval, save.
5. Add or edit widget configurations in Preferences, choosing a WidgetKit size
   and one of the 12 templates.
6. Add the widget to your desktop or notification centre and select the desired
   configuration.

## Wiring up an AI agent (optional)

The app embeds an MCP server. Any external MCP client — your Codex CLI, Claude
Code session, or anything else that speaks MCP — can connect to it and manage
trackers, trigger scrapes, or apply self-heal fixes. The app itself never
spawns AI binaries; agent involvement always runs in your own agent's session.
See [PLAN.md §13 MCP Server](PLAN.md#13-mcp-server) for transport, auth, and
the tool catalog.

The server listens on stdio when launched as an MCP subprocess and on
`~/Library/Application Support/MacosWidgetsStatsFromWebsite/mcp.sock` for local socket
clients. Retrieve the shared token from the app's Keychain-backed MCP
configuration and send it with `X-Auth` or the initialization message.

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

## Contributing

Issues and PRs welcome at
[github.com/EthanSK/macos-widgets-stats-from-website](https://github.com/EthanSK/macos-widgets-stats-from-website).
Read [PLAN.md](PLAN.md) before opening a structural PR — that's the canonical
architecture document and the place where intent gets argued out before code
gets written. Bug reports and template suggestions can go straight to
[Issues](https://github.com/EthanSK/macos-widgets-stats-from-website/issues).

## Maintainer Notes

The Sparkle Ed25519 private key is stored only in Keychain, never in git. Look
for the generic password item labeled
`Sparkle Ed25519 Private Key (macos-widgets-stats-from-website)`; Sparkle's tools also have
the same key under service `https://sparkle-project.org` with account
`macos-widgets-stats-from-website`.

The release workflow needs GitHub Actions secrets for the Developer ID
certificate (`APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD`),
Apple notarization credentials (`APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`), and
`SPARKLE_ED25519_PRIVATE_KEY`. It reads the team from `APPLE_TEAM_ID` or
`DEVELOPMENT_TEAM`, with `T34G959ZG8` checked in as the fallback.

## License

[MIT](LICENSE) — copyright Ethan Sarif-Kattan, 2026.

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
