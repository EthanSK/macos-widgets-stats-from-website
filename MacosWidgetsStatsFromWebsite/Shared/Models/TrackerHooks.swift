//
//  TrackerHooks.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Per-tracker scrape lifecycle hooks (v0.18.0+).
//
//  A "hook" is a small user-defined command that the scheduler fires after
//  every scrape attempt. Hooks live on the tracker itself so they survive
//  config sync + roundtrip cleanly. Two triggers are supported today:
//
//    .onSuccess  — fired after a scrape lands a valid reading
//    .onFailure  — fired after a scrape error is recorded (any error kind)
//
//  The default failure hook spawns a Claude Code agent in its own Terminal
//  window pointed at the failing tracker; the agent re-identifies the broken
//  element via the embedded MCP server and patches the selector. See
//  Resources/Scripts/auto-repair-tracker.sh for the script body and the
//  feedback loop with the user (macOS notification + ActivityLogger).
//
//  Why a single tracker-scoped hook list (rather than a global one)?
//    - Per-tracker context (URL, selector, last error) is what hook scripts
//      need; threading it through a global hook bus would require us to
//      reinvent that context.
//    - Users routinely want different hooks per tracker (e.g. ping Slack
//      only for the production-cost tracker, run the auto-repair only on
//      sign-in-prone selectors). Forcing one hook list to fan out via
//      conditionals inside scripts is worse than letting the model encode it.
//

import Foundation

/// When a hook is allowed to fire. Extensible: future kinds (.onValueAbove,
/// .onStaleFor) can be added without breaking the JSON shape because the
/// `trigger` field is a string-coded enum decoded with a safe default.
enum HookTrigger: String, Codable, Equatable, CaseIterable {
    case onSuccess
    case onFailure
}

/// What a hook DOES when it fires. The payload (`command` for shell,
/// `script` for AppleScript) is a single string passed verbatim to the
/// underlying executor — no shell-escaping is done by Swift so users
/// authoring custom hooks have full control. The 60s timeout in
/// HookExecutor still applies regardless of action kind.
enum HookActionKind: String, Codable, Equatable, CaseIterable {
    case runShellCommand
    case runAppleScript
}

/// One configured hook. Stable UUID so the UI can edit/delete by id
/// without index drift after reorder.
struct TrackerHook: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var trigger: HookTrigger
    var actionKind: HookActionKind
    /// The shell command, AppleScript source, or other payload depending
    /// on `actionKind`. For runShellCommand: passed to `/bin/bash -lc ...`
    /// so users can use pipes, env, etc. For runAppleScript: passed to
    /// `osascript -e ...`.
    var actionPayload: String
    var enabled: Bool
    /// Tag set when this hook was inserted as part of the default
    /// auto-repair scaffold (see TrackerHooks.defaultFailureHooks). Used
    /// to disambiguate user-authored hooks from the bundled ones — UI can
    /// optionally surface "[built-in]" and migration code can detect
    /// older defaults that need refreshing.
    var builtInIdentifier: String?

    /// Last-run telemetry. Updated by HookExecutor every time the hook
    /// fires. `nil` means the hook has never run yet.
    var lastRun: HookLastRun?

    init(
        id: UUID = UUID(),
        name: String,
        trigger: HookTrigger,
        actionKind: HookActionKind,
        actionPayload: String,
        enabled: Bool = true,
        builtInIdentifier: String? = nil,
        lastRun: HookLastRun? = nil
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.actionKind = actionKind
        self.actionPayload = actionPayload
        self.enabled = enabled
        self.builtInIdentifier = builtInIdentifier
        self.lastRun = lastRun
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed hook"
        trigger = try container.decodeIfPresent(HookTrigger.self, forKey: .trigger) ?? .onFailure
        actionKind = try container.decodeIfPresent(HookActionKind.self, forKey: .actionKind) ?? .runShellCommand
        actionPayload = try container.decodeIfPresent(String.self, forKey: .actionPayload) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        builtInIdentifier = try container.decodeIfPresent(String.self, forKey: .builtInIdentifier)
        lastRun = try container.decodeIfPresent(HookLastRun.self, forKey: .lastRun)
    }
}

/// Telemetry stamped on a TrackerHook each time it executes. Surfaces in
/// the editor UI so users can see whether a hook is healthy without
/// scrolling activity.log.
struct HookLastRun: Codable, Equatable {
    enum Status: String, Codable, Equatable, CaseIterable {
        case ok
        case error
        case timeout
        case skipped
    }

    var startedAt: Date
    var finishedAt: Date?
    var status: Status
    var exitCode: Int32?
    /// Trimmed stderr / message. Capped at 1 KB inside HookExecutor so the
    /// hooks list in trackers.json doesn't balloon if a script gets noisy.
    var detail: String?
}

/// Collection of hooks for a single tracker, grouped by trigger. We use
/// optional arrays so older trackers.json files that pre-date the field
/// roundtrip cleanly without writing empty `[]` placeholders everywhere.
struct TrackerHooks: Codable, Equatable {
    var onSuccess: [TrackerHook]
    var onFailure: [TrackerHook]

    init(onSuccess: [TrackerHook] = [], onFailure: [TrackerHook] = []) {
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onSuccess = try container.decodeIfPresent([TrackerHook].self, forKey: .onSuccess) ?? []
        onFailure = try container.decodeIfPresent([TrackerHook].self, forKey: .onFailure) ?? []
    }

    var isEmpty: Bool {
        onSuccess.isEmpty && onFailure.isEmpty
    }

    /// Returns all hooks that should fire for the given trigger. Disabled
    /// hooks are filtered out here so callers don't have to remember to
    /// check `.enabled` everywhere.
    func enabledHooks(for trigger: HookTrigger) -> [TrackerHook] {
        switch trigger {
        case .onSuccess:
            return onSuccess.filter(\.enabled)
        case .onFailure:
            return onFailure.filter(\.enabled)
        }
    }
}

/// Identifier for the built-in auto-repair hook installed on every new
/// tracker. Stored in `TrackerHook.builtInIdentifier` so migrations can
/// refresh the scaffold without clobbering user-authored hooks.
enum BuiltInHookIdentifier {
    static let autoRepair = "builtin.auto-repair-v1"
}

extension TrackerHooks {
    /// Literal placeholder token recognised by HookExecutor at run-time
    /// and substituted for the absolute path to the bundled auto-repair
    /// script. Kept here (rather than in HookScriptPaths) so widget and
    /// main-app builds — which differ in which Hooks/ files they include
    /// — agree on the string without forcing every target to compile the
    /// full executor.
    static let autoRepairCommandToken = "${AUTO_REPAIR_SCRIPT}"

    /// The scaffold installed on every new tracker. Currently a single
    /// failure hook that spawns a Claude Code agent in Terminal.
    ///
    /// Marketed as opt-out, not opt-in (per voice 2967). Users can
    /// disable it per-tracker via the Hooks panel in the editor.
    static func defaultScaffold() -> TrackerHooks {
        TrackerHooks(
            onFailure: [
                TrackerHook(
                    name: "Auto-repair via Claude",
                    trigger: .onFailure,
                    actionKind: .runShellCommand,
                    actionPayload: autoRepairCommandToken,
                    enabled: true,
                    builtInIdentifier: BuiltInHookIdentifier.autoRepair
                )
            ]
        )
    }
}
