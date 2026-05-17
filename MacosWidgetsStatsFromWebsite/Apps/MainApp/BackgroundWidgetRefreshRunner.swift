//
//  BackgroundWidgetRefreshRunner.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.20.3 — instrumented diagnostic for host-process-identity widget refresh.
//
//  The LaunchAgent's `scrape-all` CLI writes fresh data to the App Group
//  every 5 minutes, but macOS WidgetKit will not wake a parked widget
//  extension just because the CLI calls `reloadAllTimelines()`. The
//  canonical fix is to briefly relaunch the host GUI binary in
//  background-only mode so `reloadTimelines(ofKind:)` is invoked from the
//  host's process identity — that DOES wake the extension.
//
//  v0.20.3 diagnostic changes (Codex review #2):
//    1. Activation policy switched from `.prohibited` to `.accessory`.
//       `.prohibited` may prevent the process from being recognized as a
//       valid containing-app host by WidgetKit. `.accessory` (LSUIElement-
//       style) still suppresses Dock icon and menu bar but IS recognized.
//    2. `reloadTimelines(ofKind:)` instead of `reloadAllTimelines()` — more
//       direct, may behave differently when the host identity check is
//       strict.
//    3. `getCurrentConfigurations` is called BEFORE the reload and the
//       count is logged. If count is 0 while widgets are visibly on the
//       desktop, WidgetKit isn't recognizing this process as the
//       containing-app for the WidgetExtension (identity broken). If
//       count > 0, identity is fine and the reload should fire.
//    4. Runloop hold extended from 2s to 12s to give WidgetKit time to
//       process the reload + queue the timeline invocation.
//    5. Reload dispatched on the next main-run-loop turn so it runs after
//       AppKit/NSApplication is fully initialized.
//
//  Invocation contract:
//    /Applications/MacosWidgetsStatsFromWebsite.app/Contents/MacOS/MacosWidgetsStatsFromWebsite \
//      --background-widget-refresh
//
//  Or via env var (covers the case where Swift's CommandLine parser is
//  stripped by some launch path):
//    STATS_WIDGET_BG_REFRESH=1
//

import AppKit
import Darwin
import Foundation
import WidgetKit

enum BackgroundWidgetRefreshRunner {
    static let flag = "--background-widget-refresh"
    static let envVarName = "STATS_WIDGET_BG_REFRESH"

    /// The widget kind string must match `StatsWidget.kind` in the
    /// WidgetExtension. Hardcoded here to avoid linking the extension
    /// target's symbols into the main app.
    static let widgetKind = "MacosWidgetsStatsFromWebsite"

    /// How long to keep the process alive after asking WidgetKit to
    /// reload. WidgetKit dispatches the reload over XPC, so the host
    /// needs to be alive long enough for the request to actually land
    /// with `chronod` and the extension to be scheduled. v0.20.2 used
    /// 2.0s which empirically was too aggressive — bumped to 12.0s in
    /// v0.20.3 to give WidgetKit time to queue the timeline invocation
    /// before the host exits.
    static let runloopHoldSeconds: TimeInterval = 12.0

    /// True iff the current invocation should run the headless refresh
    /// path (and skip every other startup side effect).
    static func isInvokedForBackgroundRefresh() -> Bool {
        if CommandLine.arguments.contains(flag) {
            return true
        }
        if let envValue = ProcessInfo.processInfo.environment[envVarName],
           envValue == "1" || envValue.lowercased() == "true" {
            return true
        }
        return false
    }

    /// Headless refresh path. Sets the activation policy to `.accessory`
    /// to suppress Dock icon / menu bar (but stay recognizable as a host
    /// to WidgetKit), asks WidgetKit to reload the specific widget kind,
    /// holds the run loop briefly so the IPC actually flushes, and exits.
    /// Never returns.
    static func runAndExit() -> Never {
        // Touching `NSApplication.shared` materialises NSApp if it does
        // not already exist. We're called from `App.init()`, which is
        // SwiftUI's `@main`-driven entry point — by this point AppKit
        // has bootstrapped enough that NSApp is available, but reading
        // `.shared` explicitly is the defensive belt-and-braces form.
        //
        // `.accessory` MUST be set BEFORE any window can present so no
        // Dock icon flash / window flash reaches the user. We're upstream
        // of SwiftUI's Scene construction at this point. Switched from
        // `.prohibited` in v0.20.3 because `.prohibited` may prevent the
        // process from being recognized as a valid containing-app host
        // by WidgetKit. `.accessory` (LSUIElement-style) still has no
        // Dock/menu bar but IS recognized.
        NSApplication.shared.setActivationPolicy(.accessory)

        // ActivityLogger writes to the same log file the GUI uses, so
        // the entry shows up next to the normal "app launch" entries
        // and is greppable from `~/Library/Logs/macOS Widgets Stats from Website/`.
        ActivityLogger.log("app", "background widget refresh starting (.accessory)", metadata: [
            "pid": "\(getpid())"
        ])

        // Dispatch the reload on the next main-run-loop turn so it runs
        // after AppKit/NSApplication is fully initialized. The diagnostic
        // `getCurrentConfigurations` call sits in front of the reload and
        // logs the count + kinds — if count is 0 while widgets ARE on
        // the user's screen, the process identity isn't being recognized
        // by WidgetKit (Apple's "containing app" check is failing). If
        // count > 0, identity is fine and the reload should actually fire.
        DispatchQueue.main.async {
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case .success(let configs):
                    ActivityLogger.log("app", "WidgetCenter getCurrentConfigurations count=\(configs.count)", metadata: [
                        "kinds": configs.map { $0.kind }.joined(separator: ",")
                    ])
                case .failure(let err):
                    ActivityLogger.log("app", "WidgetCenter getCurrentConfigurations failed", metadata: [
                        "error": err.localizedDescription
                    ])
                }
                WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                ActivityLogger.log("app", "background widget refresh reloaded timelines (ofKind)", metadata: [
                    "kind": widgetKind
                ])
            }
        }

        // Spin the main run loop briefly so any deferred WidgetKit IPC
        // has time to flush before the process exits. RunLoop.run(until:)
        // is the supported way to do this from a non-async context — a
        // bare `Thread.sleep` would block any AppKit work that needs the
        // main run loop.
        let deadline = Date().addingTimeInterval(runloopHoldSeconds)
        RunLoop.main.run(until: deadline)

        ActivityLogger.log("app", "background widget refresh exiting")
        Darwin.exit(0)
    }
}
