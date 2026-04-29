//
//  WidgetTemplate.swift
//  MacosStatsWidgetShared
//
//  v0.1 stub — see PLAN.md §9 for the full design.
//

enum WidgetTemplate: String, CaseIterable, Codable {
    case singleBigNumber = "single-big-number"
    case numberPlusSparkline = "number-plus-sparkline"
    case gaugeRing = "gauge-ring"
    case liveSnapshotTile = "live-snapshot-tile"
    case headlineSparkline = "headline-sparkline"
    case dualStatCompare = "dual-stat-compare"
    case dashboard3Up = "dashboard-3-up"
    case snapshotPlusStat = "snapshot-plus-stat"
    case statsListWatchlist = "stats-list-watchlist"
    case heroPlusDetail = "hero-plus-detail"
    case liveSnapshotHero = "live-snapshot-hero"
    case megaDashboardGrid = "mega-dashboard-grid"
}

enum WidgetTemplateMode: String, CaseIterable, Codable {
    case text
    case snapshot
    case mixed
}

extension WidgetTemplate {
    var displayName: String {
        switch self {
        case .singleBigNumber:
            return "Single Big Number"
        case .numberPlusSparkline:
            return "Number + Sparkline"
        case .gaugeRing:
            return "Gauge Ring"
        case .liveSnapshotTile:
            return "Live Snapshot Tile"
        case .headlineSparkline:
            return "Headline + Sparkline"
        case .dualStatCompare:
            return "Dual Stat Compare"
        case .dashboard3Up:
            return "Dashboard 3-Up"
        case .snapshotPlusStat:
            return "Snapshot + Stat"
        case .statsListWatchlist:
            return "Stats List"
        case .heroPlusDetail:
            return "Hero + Detail"
        case .liveSnapshotHero:
            return "Live Snapshot Hero"
        case .megaDashboardGrid:
            return "Mega Dashboard Grid"
        }
    }

    var size: WidgetConfigurationSize {
        switch self {
        case .singleBigNumber, .numberPlusSparkline, .gaugeRing, .liveSnapshotTile:
            return .small
        case .headlineSparkline, .dualStatCompare, .dashboard3Up, .snapshotPlusStat:
            return .medium
        case .statsListWatchlist, .heroPlusDetail, .liveSnapshotHero:
            return .large
        case .megaDashboardGrid:
            return .extraLarge
        }
    }

    var mode: WidgetTemplateMode {
        switch self {
        case .liveSnapshotTile, .liveSnapshotHero:
            return .snapshot
        case .snapshotPlusStat, .megaDashboardGrid:
            return .mixed
        default:
            return .text
        }
    }

    var slotCount: ClosedRange<Int> {
        switch self {
        case .singleBigNumber, .numberPlusSparkline, .gaugeRing, .liveSnapshotTile, .headlineSparkline, .heroPlusDetail, .liveSnapshotHero:
            return 1...1
        case .dualStatCompare, .snapshotPlusStat:
            return 2...2
        case .dashboard3Up:
            return 3...3
        case .statsListWatchlist:
            return 4...6
        case .megaDashboardGrid:
            return 6...8
        }
    }

    var defaultLayout: WidgetConfigurationLayout {
        switch self {
        case .singleBigNumber, .numberPlusSparkline, .gaugeRing, .liveSnapshotTile, .headlineSparkline, .heroPlusDetail, .liveSnapshotHero:
            return .single
        case .statsListWatchlist:
            return .stack
        default:
            return .grid
        }
    }
}

extension WidgetConfigurationSize {
    var displayName: String {
        switch self {
        case .small:
            return "Small"
        case .medium:
            return "Medium"
        case .large:
            return "Large"
        case .extraLarge:
            return "Extra Large"
        }
    }
}

extension WidgetConfigurationLayout {
    var displayName: String {
        switch self {
        case .grid:
            return "Grid"
        case .stack:
            return "Stack"
        case .single:
            return "Single"
        }
    }
}
