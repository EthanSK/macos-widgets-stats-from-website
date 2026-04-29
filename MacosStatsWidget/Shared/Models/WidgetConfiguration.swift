//
//  WidgetConfiguration.swift
//  MacosStatsWidgetShared
//
//  v0.1 stub — see PLAN.md §5 for the full design.
//

import Foundation

struct WidgetConfiguration: Codable, Identifiable {
    var id: UUID
    var name: String
    var templateID: WidgetTemplate
    var trackerIDs: [UUID]

    init(
        id: UUID = UUID(),
        name: String,
        templateID: WidgetTemplate,
        trackerIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.templateID = templateID
        self.trackerIDs = trackerIDs
    }
}
