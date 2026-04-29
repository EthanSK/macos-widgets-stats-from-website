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
