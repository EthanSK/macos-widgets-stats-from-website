//
//  WidgetConfiguration.swift
//  MacosStatsWidgetShared
//
//  Widget composition configuration persisted with trackers.
//

import Foundation

struct WidgetConfiguration: Codable, Identifiable {
    var id: UUID
    var name: String
    var templateID: WidgetTemplate
    var size: WidgetConfigurationSize
    var layout: WidgetConfigurationLayout
    var trackerIDs: [UUID]
    var showSparklines: Bool
    var showLabels: Bool

    init(
        id: UUID = UUID(),
        name: String,
        templateID: WidgetTemplate,
        size: WidgetConfigurationSize = .small,
        layout: WidgetConfigurationLayout = .single,
        trackerIDs: [UUID] = [],
        showSparklines: Bool = true,
        showLabels: Bool = true
    ) {
        self.id = id
        self.name = name
        self.templateID = templateID
        self.size = size
        self.layout = layout
        self.trackerIDs = trackerIDs
        self.showSparklines = showSparklines
        self.showLabels = showLabels
    }
}

enum WidgetConfigurationSize: String, Codable, CaseIterable {
    case small
    case medium
    case large
    case extraLarge
}

enum WidgetConfigurationLayout: String, Codable, CaseIterable {
    case grid
    case stack
    case single
}
