//
//  TrackerHooksCodableTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Round-trip + default-scaffold tests for TrackerHooks (v0.18.0+).
//

import XCTest

final class TrackerHooksCodableTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        let lastRun = HookLastRun(
            startedAt: Date(timeIntervalSince1970: 1_715_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_715_000_005),
            status: .timeout,
            exitCode: 137,
            detail: "Hook exceeded 60s timeout."
        )
        let original = TrackerHooks(
            onSuccess: [
                TrackerHook(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    name: "Ping Slack",
                    trigger: .onSuccess,
                    actionKind: .runShellCommand,
                    actionPayload: "curl -s slack-webhook",
                    enabled: true,
                    builtInIdentifier: nil,
                    lastRun: lastRun
                )
            ],
            onFailure: [
                TrackerHook(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    name: "Auto-repair",
                    trigger: .onFailure,
                    actionKind: .runShellCommand,
                    actionPayload: TrackerHooks.autoRepairCommandToken,
                    enabled: false,
                    builtInIdentifier: BuiltInHookIdentifier.autoRepair,
                    lastRun: nil
                )
            ]
        )

        let data = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(TrackerHooks.self, from: data)
        XCTAssertEqual(roundTripped, original)
    }

    func testDecodeIsTolerantOfMissingKeys() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TrackerHooks.self, from: json)
        XCTAssertTrue(decoded.onSuccess.isEmpty)
        XCTAssertTrue(decoded.onFailure.isEmpty)
    }

    func testEnabledFilterRespectsTriggerAndEnabledFlag() {
        let on1 = TrackerHook(name: "ok-hook", trigger: .onSuccess, actionKind: .runShellCommand, actionPayload: "echo")
        var disabledFail = TrackerHook(name: "off-hook", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "echo")
        disabledFail.enabled = false
        let enabledFail = TrackerHook(name: "armed-hook", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "echo")
        let hooks = TrackerHooks(onSuccess: [on1], onFailure: [disabledFail, enabledFail])
        XCTAssertEqual(hooks.enabledHooks(for: .onSuccess).count, 1)
        XCTAssertEqual(hooks.enabledHooks(for: .onFailure).map(\.name), ["armed-hook"])
    }

    func testDefaultScaffoldHasOneFailureHookWithBuiltInTag() {
        let scaffold = TrackerHooks.defaultScaffold()
        XCTAssertTrue(scaffold.onSuccess.isEmpty)
        XCTAssertEqual(scaffold.onFailure.count, 1)
        XCTAssertEqual(scaffold.onFailure[0].builtInIdentifier, BuiltInHookIdentifier.autoRepair)
        XCTAssertEqual(scaffold.onFailure[0].trigger, .onFailure)
        XCTAssertEqual(scaffold.onFailure[0].actionPayload, TrackerHooks.autoRepairCommandToken)
        XCTAssertTrue(scaffold.onFailure[0].enabled)
    }

    func testTrackerInitGetsScaffoldByDefault() {
        let tracker = Tracker(name: "t", url: "https://example.com", selector: ".x")
        XCTAssertFalse(tracker.hooks.isEmpty)
        XCTAssertEqual(tracker.hooks.onFailure.count, 1)
    }

    func testPre018TrackerJSONDecodesWithEmptyHooksBag() throws {
        // Simulate a pre-0.18 trackers.json blob — no hooks key.
        let json = """
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "name": "Legacy",
            "url": "https://example.com",
            "selector": ".legacy"
        }
        """.data(using: .utf8)!
        let tracker = try JSONDecoder().decode(Tracker.self, from: json)
        XCTAssertTrue(tracker.hooks.isEmpty, "Decoded pre-0.18 tracker should have empty hooks bag; AppGroupStore.backfillDefaultHookScaffoldIfNeeded() backfills it on app launch.")
    }
}
