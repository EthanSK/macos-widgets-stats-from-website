//
//  HookExecutor.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Detached executor for per-tracker scrape lifecycle hooks (v0.18.0+).
//
//  Design contract:
//    - Hook execution NEVER blocks scrape recording. We invoke
//      `fire(...)` from the BackgroundScheduler's post-record path and
//      return immediately. The actual Process spawn happens on a
//      dedicated utility queue.
//    - Hook failures NEVER block the scheduler. An exception thrown
//      inside the hook script is caught, stamped on the hook's
//      lastRun.detail, and logged to ActivityLogger. The next scrape
//      proceeds unaffected.
//    - 60s wall-clock timeout per hook. Exceeding it sends SIGTERM,
//      then SIGKILL 1s later if the child is still alive.
//    - Env-var contract is the public-stable API surface for hook
//      authors. See `makeEnvironment(...)` below for the full list.
//    - Hook execution can be mocked at the top of fire() via the
//      `processLauncher` static — tests inject a fake to avoid actually
//      spawning Terminal windows during the suite.
//

import Foundation

#if !WIDGET_EXTENSION

enum HookExecutor {
    static let defaultTimeoutSeconds: TimeInterval = 60.0

    /// Maximum bytes of stderr captured back into `HookLastRun.detail`.
    /// Anything beyond this is truncated so a chatty hook can't bloat
    /// trackers.json.
    static let maxCapturedDetailBytes = 1024

    /// Mockable launcher seam. Tests replace this with a fake that
    /// records invocations without spawning real processes.
    static var processLauncher: HookProcessLauncher = SystemHookProcessLauncher()

    /// Replace the launcher and return the prior value so tests can
    /// reset cleanly in tearDown.
    @discardableResult
    static func setLauncher(_ launcher: HookProcessLauncher) -> HookProcessLauncher {
        let prior = processLauncher
        processLauncher = launcher
        return prior
    }

    /// Async-fires every enabled hook for `trigger` on the given tracker.
    /// Returns immediately. Any per-hook telemetry update flows through
    /// the optional `recordTelemetry` callback so the caller (typically
    /// BackgroundScheduler) can persist the lastRun stamp back into the
    /// tracker config without HookExecutor needing to know about
    /// AppGroupStore.
    static func fire(
        trigger: HookTrigger,
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        recordTelemetry: ((UUID, HookLastRun) -> Void)? = nil
    ) {
        let hooks = tracker.hooks.enabledHooks(for: trigger)
        guard !hooks.isEmpty else {
            return
        }

        let launcher = processLauncher

        ActivityLogger.log("hook", "firing", metadata: [
            "trigger": trigger.rawValue,
            "trackerID": tracker.id.uuidString,
            "count": "\(hooks.count)"
        ])

        for hook in hooks {
            let startedAt = Date()
            let initialTelemetry = HookLastRun(
                startedAt: startedAt,
                finishedAt: nil,
                status: .ok,
                exitCode: nil,
                detail: nil
            )
            recordTelemetry?(hook.id, initialTelemetry)

            launcher.launch(
                hook: hook,
                tracker: tracker,
                scrapeContext: scrapeContext,
                timeout: defaultTimeoutSeconds
            ) { outcome in
                let telemetry = HookLastRun(
                    startedAt: startedAt,
                    finishedAt: Date(),
                    status: outcome.status,
                    exitCode: outcome.exitCode,
                    detail: truncateDetail(outcome.detail)
                )

                ActivityLogger.log("hook", "finished", metadata: [
                    "trigger": trigger.rawValue,
                    "trackerID": tracker.id.uuidString,
                    "hookID": hook.id.uuidString,
                    "hookName": hook.name,
                    "status": outcome.status.rawValue,
                    "exitCode": outcome.exitCode.map { "\($0)" } ?? "-",
                    "elapsedSec": String(format: "%.2f", telemetry.finishedAt!.timeIntervalSince(startedAt))
                ])

                recordTelemetry?(hook.id, telemetry)
            }
        }
    }

    /// Build the env-var bag every hook sees. The naming is **stable
    /// public API** — third parties writing custom hooks rely on these
    /// names. Rename = breaking change.
    static func makeEnvironment(
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        bundleAutoRepairScript: Bool = true
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        env["TRACKER_ID"] = tracker.id.uuidString
        env["TRACKER_NAME"] = tracker.name
        env["TRACKER_URL"] = tracker.url
        env["TRACKER_SELECTOR"] = tracker.selector
        env["TRACKER_RENDER_MODE"] = tracker.renderMode.rawValue
        env["TRACKER_BROWSER_PROFILE"] = tracker.browserProfile

        env["HOOK_TRIGGER"] = scrapeContext.trigger.rawValue
        env["HOOK_FIRED_AT"] = ISO8601DateFormatter().string(from: scrapeContext.firedAt)

        if let value = scrapeContext.scrapedValue {
            env["SCRAPE_VALUE"] = value
        }
        if let numeric = scrapeContext.scrapedNumeric {
            env["SCRAPE_NUMERIC"] = "\(numeric)"
        }
        if let errorKind = scrapeContext.errorKind {
            env["ERROR_KIND"] = errorKind
        }
        if let errorMessage = scrapeContext.errorMessage {
            env["ERROR_MESSAGE"] = errorMessage
        }
        if let consecutiveFailureCount = scrapeContext.consecutiveFailureCount {
            env["CONSECUTIVE_FAILURE_COUNT"] = "\(consecutiveFailureCount)"
        }

        env["APP_GROUP_IDENTIFIER"] = AppGroupPaths.identifier
        env["MCP_SOCKET_PATH"] = AppGroupPaths.mcpSocketURL().path

        if bundleAutoRepairScript {
            env["AUTO_REPAIR_SCRIPT"] = HookScriptPaths.autoRepairScriptURL().path
        }

        return env
    }

    private static func truncateDetail(_ detail: String?) -> String? {
        guard var trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.utf8.count > maxCapturedDetailBytes {
            let end = trimmed.index(trimmed.startIndex, offsetBy: maxCapturedDetailBytes, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            trimmed = String(trimmed[..<end]) + "…"
        }
        return trimmed
    }
}

/// Snapshot of the scrape attempt that produced the hook firing. Passed
/// through to the executor as env vars and surfaced to test mocks.
struct HookScrapeContext: Equatable {
    var trigger: HookTrigger
    var firedAt: Date
    var scrapedValue: String?
    var scrapedNumeric: Double?
    var errorKind: String?
    var errorMessage: String?
    var consecutiveFailureCount: Int?
}

/// Result of a single hook process invocation.
struct HookOutcome: Equatable {
    var status: HookLastRun.Status
    var exitCode: Int32?
    var detail: String?
}

/// Pluggable seam — tests swap in a fake launcher that doesn't actually
/// fork/exec.
protocol HookProcessLauncher {
    func launch(
        hook: TrackerHook,
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        timeout: TimeInterval,
        completion: @escaping (HookOutcome) -> Void
    )
}

/// Production launcher. Spawns a Process per hook, captures stderr,
/// applies a hard wall-clock timeout, and reports back via completion.
final class SystemHookProcessLauncher: HookProcessLauncher {
    static let workQueue = DispatchQueue(
        label: "com.ethansk.macos-widgets-stats-from-website.hook-executor",
        qos: .utility,
        attributes: .concurrent
    )

    func launch(
        hook: TrackerHook,
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        timeout: TimeInterval,
        completion: @escaping (HookOutcome) -> Void
    ) {
        Self.workQueue.async {
            let outcome = self.runSynchronously(
                hook: hook,
                tracker: tracker,
                scrapeContext: scrapeContext,
                timeout: timeout
            )
            completion(outcome)
        }
    }

    private func runSynchronously(
        hook: TrackerHook,
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        timeout: TimeInterval
    ) -> HookOutcome {
        let process = Process()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()

        switch hook.actionKind {
        case .runShellCommand:
            // Substitute well-known placeholder tokens before exec.
            let resolvedPayload = hook.actionPayload
                .replacingOccurrences(
                    of: HookScriptPaths.autoRepairCommandToken,
                    with: HookScriptPaths.autoRepairScriptURL().path
                )
            process.launchPath = "/bin/bash"
            process.arguments = ["-lc", resolvedPayload]
        case .runAppleScript:
            process.launchPath = "/usr/bin/osascript"
            process.arguments = ["-e", hook.actionPayload]
        }

        process.environment = HookExecutor.makeEnvironment(
            tracker: tracker,
            scrapeContext: scrapeContext
        )
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            return HookOutcome(
                status: .error,
                exitCode: nil,
                detail: "Could not launch hook: \(error.localizedDescription)"
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                let killDeadline = Date().addingTimeInterval(1.0)
                while process.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.waitUntilExit()
        }

        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let combinedDetail = combine(stderr: stderr, stdout: stdout)

        if timedOut {
            return HookOutcome(
                status: .timeout,
                exitCode: process.terminationStatus,
                detail: "Hook exceeded \(Int(timeout))s timeout. " + combinedDetail
            )
        }

        let exitCode = process.terminationStatus
        if exitCode == 0 {
            return HookOutcome(status: .ok, exitCode: exitCode, detail: combinedDetail.nilIfBlank)
        } else {
            return HookOutcome(status: .error, exitCode: exitCode, detail: combinedDetail.nilIfBlank ?? "Hook exited with code \(exitCode).")
        }
    }

    private func combine(stderr: String, stdout: String) -> String {
        switch (stderr.isEmpty, stdout.isEmpty) {
        case (true, true): return ""
        case (false, true): return stderr
        case (true, false): return stdout
        case (false, false): return stderr + "\n" + stdout
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif
