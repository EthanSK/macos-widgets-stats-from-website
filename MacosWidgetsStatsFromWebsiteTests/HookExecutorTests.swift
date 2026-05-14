//
//  HookExecutorTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Behavioural tests for the runtime hook executor (v0.18.0+).
//  Uses a fake launcher to avoid spawning real processes / Terminal
//  windows during the suite.
//

import XCTest

/// Fake launcher that records every invocation and returns a canned
/// outcome (defaults to a clean exit code 0). Tests can pre-stage
/// `nextOutcomes` to simulate failures, timeouts, etc.
final class FakeHookProcessLauncher: HookProcessLauncher {
    struct Invocation {
        let hook: TrackerHook
        let tracker: Tracker
        let scrapeContext: HookScrapeContext
        let timeout: TimeInterval
    }

    private(set) var invocations: [Invocation] = []
    var nextOutcomes: [HookOutcome] = []
    var defaultOutcome: HookOutcome = HookOutcome(status: .ok, exitCode: 0, detail: nil)
    /// Delay between launch() and completion call. Tests asserting
    /// timing semantics can dial this up.
    var artificialLatency: TimeInterval = 0
    /// Synchronous completion lets unit tests assert telemetry without
    /// XCTestExpectation gymnastics.
    var completionMode: CompletionMode = .synchronous

    enum CompletionMode {
        case synchronous
        case asynchronous(queue: DispatchQueue)
    }

    func launch(
        hook: TrackerHook,
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        timeout: TimeInterval,
        completion: @escaping (HookOutcome) -> Void
    ) {
        let invocation = Invocation(hook: hook, tracker: tracker, scrapeContext: scrapeContext, timeout: timeout)
        invocations.append(invocation)
        let outcome = nextOutcomes.isEmpty ? defaultOutcome : nextOutcomes.removeFirst()

        switch completionMode {
        case .synchronous:
            if artificialLatency > 0 {
                Thread.sleep(forTimeInterval: artificialLatency)
            }
            completion(outcome)
        case .asynchronous(let queue):
            queue.asyncAfter(deadline: .now() + artificialLatency) {
                completion(outcome)
            }
        }
    }
}

final class HookExecutorTests: XCTestCase {
    private var fakeLauncher: FakeHookProcessLauncher!
    private var priorLauncher: HookProcessLauncher!

    override func setUp() {
        super.setUp()
        fakeLauncher = FakeHookProcessLauncher()
        priorLauncher = HookExecutor.setLauncher(fakeLauncher)
    }

    override func tearDown() {
        HookExecutor.setLauncher(priorLauncher)
        fakeLauncher = nil
        super.tearDown()
    }

    private func makeTracker(hooks: TrackerHooks) -> Tracker {
        Tracker(
            name: "TestTracker",
            url: "https://example.com",
            selector: ".value",
            hooks: hooks
        )
    }

    private func makeContext(trigger: HookTrigger = .onFailure, error: String? = "boom") -> HookScrapeContext {
        HookScrapeContext(
            trigger: trigger,
            firedAt: Date(timeIntervalSince1970: 1_715_000_000),
            scrapedValue: nil,
            scrapedNumeric: nil,
            errorKind: error == nil ? nil : "ScrapeError",
            errorMessage: error,
            consecutiveFailureCount: 2
        )
    }

    // MARK: - Plumbing

    func testFireDoesNothingWhenNoHooksAreConfigured() {
        let tracker = makeTracker(hooks: TrackerHooks(onSuccess: [], onFailure: []))
        HookExecutor.fire(trigger: .onFailure, tracker: tracker, scrapeContext: makeContext())
        XCTAssertEqual(fakeLauncher.invocations.count, 0)
    }

    func testFireOnlyInvokesEnabledHooksMatchingTheTrigger() {
        var disabledFail = TrackerHook(name: "off", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "echo")
        disabledFail.enabled = false
        let armedFail = TrackerHook(name: "armed", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "echo")
        let succeededOnly = TrackerHook(name: "success", trigger: .onSuccess, actionKind: .runShellCommand, actionPayload: "echo")
        let hooks = TrackerHooks(onSuccess: [succeededOnly], onFailure: [disabledFail, armedFail])
        let tracker = makeTracker(hooks: hooks)

        HookExecutor.fire(trigger: .onFailure, tracker: tracker, scrapeContext: makeContext())

        XCTAssertEqual(fakeLauncher.invocations.count, 1)
        XCTAssertEqual(fakeLauncher.invocations[0].hook.name, "armed")
    }

    // MARK: - Env-var contract

    func testEnvironmentContainsTrackerAndScrapeContext() {
        let tracker = makeTracker(hooks: TrackerHooks(onFailure: [
            TrackerHook(name: "h", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "echo")
        ]))
        let ctx = HookScrapeContext(
            trigger: .onFailure,
            firedAt: Date(timeIntervalSince1970: 1_715_000_000),
            scrapedValue: "$1.23",
            scrapedNumeric: 1.23,
            errorKind: "ScrapeError",
            errorMessage: "selector did not match",
            consecutiveFailureCount: 4
        )
        let env = HookExecutor.makeEnvironment(tracker: tracker, scrapeContext: ctx)

        XCTAssertEqual(env["TRACKER_ID"], tracker.id.uuidString)
        XCTAssertEqual(env["TRACKER_NAME"], "TestTracker")
        XCTAssertEqual(env["TRACKER_URL"], "https://example.com")
        XCTAssertEqual(env["TRACKER_SELECTOR"], ".value")
        XCTAssertEqual(env["HOOK_TRIGGER"], "onFailure")
        XCTAssertEqual(env["SCRAPE_VALUE"], "$1.23")
        XCTAssertEqual(env["ERROR_KIND"], "ScrapeError")
        XCTAssertEqual(env["ERROR_MESSAGE"], "selector did not match")
        XCTAssertEqual(env["CONSECUTIVE_FAILURE_COUNT"], "4")
        XCTAssertNotNil(env["AUTO_REPAIR_SCRIPT"], "AUTO_REPAIR_SCRIPT path must be set so hook scripts can dispatch to it.")
    }

    // MARK: - Telemetry recording

    func testTelemetryCallbackFiresInitialAndFinal() {
        let hook = TrackerHook(name: "h", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "echo")
        let tracker = makeTracker(hooks: TrackerHooks(onFailure: [hook]))
        var telemetries: [(UUID, HookLastRun)] = []

        fakeLauncher.defaultOutcome = HookOutcome(status: .ok, exitCode: 0, detail: nil)
        HookExecutor.fire(
            trigger: .onFailure,
            tracker: tracker,
            scrapeContext: makeContext()
        ) { hookID, telemetry in
            telemetries.append((hookID, telemetry))
        }

        XCTAssertEqual(telemetries.count, 2, "Expected an initial (in-flight) stamp + a final stamp.")
        let final = telemetries.last!.1
        XCTAssertEqual(final.status, .ok)
        XCTAssertEqual(final.exitCode, 0)
        XCTAssertNotNil(final.finishedAt)
    }

    func testHookFailureDoesNotPreventOtherHooksFromFiring() {
        let hookA = TrackerHook(name: "a", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "echo a")
        let hookB = TrackerHook(name: "b", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "echo b")
        let tracker = makeTracker(hooks: TrackerHooks(onFailure: [hookA, hookB]))

        fakeLauncher.nextOutcomes = [
            HookOutcome(status: .error, exitCode: 99, detail: "broke"),
            HookOutcome(status: .ok, exitCode: 0, detail: nil)
        ]

        HookExecutor.fire(trigger: .onFailure, tracker: tracker, scrapeContext: makeContext())

        XCTAssertEqual(fakeLauncher.invocations.count, 2)
        XCTAssertEqual(fakeLauncher.invocations.map { $0.hook.name }, ["a", "b"])
    }

    // MARK: - Timeout reporting

    func testTimeoutOutcomeIsReportedToTelemetry() {
        let hook = TrackerHook(name: "h", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "sleep 600")
        let tracker = makeTracker(hooks: TrackerHooks(onFailure: [hook]))

        fakeLauncher.nextOutcomes = [
            HookOutcome(status: .timeout, exitCode: 15, detail: "Hook exceeded 60s timeout.")
        ]

        var finalTelemetry: HookLastRun?
        HookExecutor.fire(
            trigger: .onFailure,
            tracker: tracker,
            scrapeContext: makeContext()
        ) { _, telemetry in
            if telemetry.finishedAt != nil {
                finalTelemetry = telemetry
            }
        }

        XCTAssertEqual(finalTelemetry?.status, .timeout)
        XCTAssertTrue(finalTelemetry?.detail?.contains("60s timeout") ?? false)
    }
}
