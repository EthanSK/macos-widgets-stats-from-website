//
//  HookScriptPaths.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Resolve on-disk locations for bundled hook scripts shipped with the app.
//
//  The auto-repair script (`auto-repair-tracker.sh`) is shipped via two
//  layered locations so the hook works whether the app is launched
//  from `/Applications` (bundle resource available) or via `xcodebuild run`
//  in a dev derived-data path:
//
//    1. Bundled inside the .app at `Contents/Resources/Scripts/...`
//       — preferred, signed, immutable.
//    2. Fallback at `<Application Support>/<App>/Scripts/...`
//       — written on first launch from the bundled copy when present,
//         editable for power users who want to tweak the agent prompt.
//
//  When neither location exists (e.g. running unit tests in a stripped
//  derived-data dir with no Resources path), the helper returns the
//  Application Support path anyway and the script-installation step
//  writes a fresh copy from the embedded fallback string.
//

import Foundation

enum HookScriptPaths {
    static let autoRepairScriptFileName = "auto-repair-tracker.sh"

    /// Returns the canonical path the hook system should invoke. Prefers
    /// the bundled copy when present; falls back to the writable copy
    /// under Application Support so the path is always non-nil even when
    /// the app is running out of a derived-data build.
    static func autoRepairScriptURL() -> URL {
        if let bundled = bundledScriptURL(named: autoRepairScriptFileName) {
            return bundled
        }
        return userWritableScriptURL(named: autoRepairScriptFileName)
    }

    /// Shell command stored in `TrackerHook.actionPayload` for the default
    /// auto-repair scaffold. Resolved lazily at the hook's exec time so
    /// the path reflects the current install — moving the .app between
    /// builds doesn't strand the saved command on a stale absolute path.
    ///
    /// Forwarded for backwards-compat with code outside the Hooks module
    /// that referenced the token here pre-refactor. The canonical
    /// definition now lives on `TrackerHooks` so widget builds (which
    /// exclude Hooks/) can still see the string.
    static var autoRepairCommandToken: String { TrackerHooks.autoRepairCommandToken }

    static func autoRepairInvocationCommand() -> String {
        autoRepairCommandToken
    }

    /// Resolves a bundled script URL inside the running .app's Resources
    /// directory. Returns nil when running under contexts that don't have
    /// a Resources path (e.g. command-line tests, certain headless invokes).
    static func bundledScriptURL(named name: String) -> URL? {
        // The CLI tool and the GUI app share the Shared/ source folder, so
        // Bundle.main may resolve to either of them. Both bundles get the
        // same Resources/Scripts directory when bundled.
        let bundles = Array(Set([Bundle.main, Bundle(for: HookScriptPathsAnchor.self)]))
        for bundle in bundles {
            if let resourceURL = bundle.resourceURL {
                let candidate = resourceURL
                    .appendingPathComponent("Scripts", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Writable per-user script directory, e.g.
    /// `~/Library/Application Support/macOS Widgets Stats from Website/Scripts/<name>`.
    /// Created on demand.
    static func userWritableScriptURL(named name: String) -> URL {
        let supportDir = AppGroupPaths.canonicalApplicationSupportURL()
            .appendingPathComponent("Scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true, attributes: nil)
        return supportDir.appendingPathComponent(name, isDirectory: false)
    }
}

/// Empty class only used as a Bundle(for:) anchor to find the Shared
/// framework's resource bundle in test contexts. Keep at file scope so
/// `Bundle(for:)` returns the framework bundle, not the test bundle.
private final class HookScriptPathsAnchor {}
