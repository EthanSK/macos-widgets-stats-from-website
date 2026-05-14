//
//  HookProcessIntegrationTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Integration tests against the real SystemHookProcessLauncher.
//
//  These spawn real /bin/bash children, so we keep them simple and
//  fast (a 1-2s sleep is the worst case). We override the timeout to
//  a few seconds rather than the production 60s so the suite stays
//  CI-friendly.
//

import XCTest

final class HookProcessIntegrationTests: XCTestCase {
    private func makeTracker() -> Tracker {
        Tracker(
            name: "TestTracker",
            url: "https://example.com",
            selector: ".v",
            hooks: TrackerHooks()
        )
    }

    private func makeContext() -> HookScrapeContext {
        HookScrapeContext(
            trigger: .onFailure,
            firedAt: Date(),
            scrapedValue: nil,
            scrapedNumeric: nil,
            errorKind: "TestError",
            errorMessage: "boom",
            consecutiveFailureCount: 1
        )
    }

    func testRealLauncherReportsSuccessForCleanShellHook() {
        let launcher = SystemHookProcessLauncher()
        let hook = TrackerHook(
            name: "echo-test",
            trigger: .onFailure,
            actionKind: .runShellCommand,
            actionPayload: "echo hello"
        )

        let exp = expectation(description: "hook completes")
        var outcome: HookOutcome?
        launcher.launch(
            hook: hook,
            tracker: makeTracker(),
            scrapeContext: makeContext(),
            timeout: 5.0
        ) { result in
            outcome = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)

        XCTAssertEqual(outcome?.status, .ok)
        XCTAssertEqual(outcome?.exitCode, 0)
    }

    func testRealLauncherCapturesNonZeroExit() {
        let launcher = SystemHookProcessLauncher()
        let hook = TrackerHook(
            name: "fail-test",
            trigger: .onFailure,
            actionKind: .runShellCommand,
            actionPayload: "echo nope >&2; exit 7"
        )

        let exp = expectation(description: "hook completes")
        var outcome: HookOutcome?
        launcher.launch(
            hook: hook,
            tracker: makeTracker(),
            scrapeContext: makeContext(),
            timeout: 5.0
        ) { result in
            outcome = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)

        XCTAssertEqual(outcome?.status, .error)
        XCTAssertEqual(outcome?.exitCode, 7)
        XCTAssertTrue(outcome?.detail?.contains("nope") ?? false)
    }

    func testRealLauncherEnforcesTimeout() {
        let launcher = SystemHookProcessLauncher()
        // 30s sleep > 2s timeout. Production limit is 60s; we use 2s
        // here so the test stays under 5s wall time.
        let hook = TrackerHook(
            name: "timeout-test",
            trigger: .onFailure,
            actionKind: .runShellCommand,
            actionPayload: "sleep 30"
        )

        let exp = expectation(description: "hook completes")
        var outcome: HookOutcome?
        let started = Date()
        launcher.launch(
            hook: hook,
            tracker: makeTracker(),
            scrapeContext: makeContext(),
            timeout: 2.0
        ) { result in
            outcome = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 8.0)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(outcome?.status, .timeout)
        XCTAssertLessThan(elapsed, 6.0, "Timeout should fire close to its configured 2s, with a 1s SIGTERM->SIGKILL grace. Actual elapsed: \(elapsed)s")
    }

    func testRealLauncherSubstitutesAutoRepairScriptToken() {
        // Build a tracker with a hook whose payload contains the
        // token. We don't care that the actual auto-repair script may
        // exist or not — we only care that the token is substituted
        // for a valid-looking path before exec.
        let launcher = SystemHookProcessLauncher()
        // Use a shell hook that echoes the substituted path. The
        // SCRIPT_RESOLVED env var lets the test assert on it without
        // depending on the auto-repair script's behaviour.
        let hook = TrackerHook(
            name: "token-test",
            trigger: .onFailure,
            actionKind: .runShellCommand,
            actionPayload: "echo TOKEN=\(TrackerHooks.autoRepairCommandToken) >&2; exit 0"
        )

        let exp = expectation(description: "hook completes")
        var outcome: HookOutcome?
        launcher.launch(
            hook: hook,
            tracker: makeTracker(),
            scrapeContext: makeContext(),
            timeout: 5.0
        ) { result in
            outcome = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)

        XCTAssertEqual(outcome?.status, .ok)
        // Detail should contain TOKEN=/some/path/auto-repair-tracker.sh
        // rather than the literal token.
        let detail = outcome?.detail ?? ""
        XCTAssertTrue(detail.contains("auto-repair-tracker.sh"),
                      "Token should be substituted with the resolved script path. Detail: \(detail)")
        XCTAssertFalse(outcome?.detail?.contains("${AUTO_REPAIR_SCRIPT}") ?? false,
                       "Literal token should have been replaced before exec.")
    }
}
