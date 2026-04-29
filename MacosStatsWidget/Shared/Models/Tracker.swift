//
//  Tracker.swift
//  MacosStatsWidgetShared
//
//  v0.1 stub — see PLAN.md §5 for the full design.
//

import Foundation

struct Tracker: Codable, Identifiable {
    var id: UUID
    var name: String
    var url: String

    init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}
