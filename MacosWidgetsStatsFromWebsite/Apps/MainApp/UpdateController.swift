//
//  UpdateController.swift
//  MacosWidgetsStatsFromWebsite
//
//  Sparkle 2 updater integration.
//

import AppKit
import Sparkle

final class UpdateController: NSObject {
    static let shared = UpdateController()

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    var updater: SPUUpdater {
        updaterController.updater
    }

    func start() {
        updaterController.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        updaterController.checkForUpdates(sender)
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // The app is always safe to update-check; keep this delegate hook for future gating.
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("Sparkle found update %@", item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        NSLog("Sparkle did not find an update: %@", error.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("Sparkle update check failed: %@", error.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            NSLog("Sparkle update cycle finished with error: %@", error.localizedDescription)
        }
    }
}
