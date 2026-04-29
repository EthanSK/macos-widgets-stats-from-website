//
//  RenderMode.swift
//  MacosStatsWidgetShared
//
//  Text or snapshot tracker rendering mode.
//

enum RenderMode: String, CaseIterable, Codable, Identifiable {
    case text
    case snapshot

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .text:
            return "Text"
        case .snapshot:
            return "Snapshot"
        }
    }

    var defaultRefreshIntervalSec: Int {
        switch self {
        case .text:
            return 1_800
        case .snapshot:
            return 2
        }
    }
}
