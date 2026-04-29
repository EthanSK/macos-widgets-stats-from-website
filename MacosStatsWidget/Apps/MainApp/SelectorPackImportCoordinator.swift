//
//  SelectorPackImportCoordinator.swift
//  MacosStatsWidget
//
//  Finder Open With and drag/drop selector-pack import.
//

import Foundation

enum SelectorPackImportCoordinator {
    @discardableResult
    static func importSelectorPack(at url: URL) throws -> Tracker {
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let pack = try SelectorPack.decodeStrict(from: data)
        let tracker = try pack.makeTracker()

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers.append(tracker)
        }
        NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
        return tracker
    }
}
