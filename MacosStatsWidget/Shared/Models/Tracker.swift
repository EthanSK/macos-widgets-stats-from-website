//
//  Tracker.swift
//  MacosStatsWidgetShared
//
//  Tracker configuration row persisted in trackers.json.
//

import Foundation

struct Tracker: Codable, Identifiable {
    static let defaultBrowserProfile = "macos-stats-widget"
    static let defaultIcon = "chart.line.uptrend.xyaxis"
    static let defaultAccentColorHex = "#10a37f"

    var id: UUID
    var name: String
    var url: String
    var browserProfile: String
    var renderMode: RenderMode
    var selector: String
    var elementBoundingBox: ElementBoundingBox?
    var refreshIntervalSec: Int
    var label: String?
    var icon: String
    var accentColorHex: String
    var valueParser: ValueParser
    var history: TrackerHistory
    var hideElements: [String]
    var lastHealedAt: Date?
    var selectorHistory: [SelectorHistoryEntry]

    init(
        id: UUID = UUID(),
        name: String = "",
        url: String = "",
        browserProfile: String = Tracker.defaultBrowserProfile,
        renderMode: RenderMode = .text,
        selector: String = "",
        elementBoundingBox: ElementBoundingBox? = nil,
        refreshIntervalSec: Int? = nil,
        label: String? = nil,
        icon: String = Tracker.defaultIcon,
        accentColorHex: String = Tracker.defaultAccentColorHex,
        valueParser: ValueParser = ValueParser(),
        history: TrackerHistory = TrackerHistory(),
        hideElements: [String] = [],
        lastHealedAt: Date? = nil,
        selectorHistory: [SelectorHistoryEntry] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.browserProfile = browserProfile
        self.renderMode = renderMode
        self.selector = selector
        self.elementBoundingBox = elementBoundingBox
        self.refreshIntervalSec = refreshIntervalSec ?? renderMode.defaultRefreshIntervalSec
        self.label = label
        self.icon = icon
        self.accentColorHex = accentColorHex
        self.valueParser = valueParser
        self.history = history
        self.hideElements = hideElements
        self.lastHealedAt = lastHealedAt
        self.selectorHistory = selectorHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let renderMode = try container.decodeIfPresent(RenderMode.self, forKey: .renderMode) ?? .text

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        browserProfile = try container.decodeIfPresent(String.self, forKey: .browserProfile) ?? Tracker.defaultBrowserProfile
        self.renderMode = renderMode
        selector = try container.decodeIfPresent(String.self, forKey: .selector) ?? ""
        elementBoundingBox = try container.decodeIfPresent(ElementBoundingBox.self, forKey: .elementBoundingBox)
        refreshIntervalSec = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSec)
            ?? renderMode.defaultRefreshIntervalSec
        label = try container.decodeIfPresent(String.self, forKey: .label)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? Tracker.defaultIcon
        accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex)
            ?? Tracker.defaultAccentColorHex
        valueParser = try container.decodeIfPresent(ValueParser.self, forKey: .valueParser) ?? ValueParser()
        history = try container.decodeIfPresent(TrackerHistory.self, forKey: .history) ?? TrackerHistory()
        hideElements = try container.decodeIfPresent([String].self, forKey: .hideElements) ?? []
        lastHealedAt = try container.decodeIfPresent(Date.self, forKey: .lastHealedAt)
        selectorHistory = try container.decodeIfPresent([SelectorHistoryEntry].self, forKey: .selectorHistory) ?? []
    }
}

struct ElementBoundingBox: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var viewportWidth: Double
    var viewportHeight: Double
    var devicePixelRatio: Double
}

struct ValueParser: Codable, Equatable {
    enum ParserType: String, Codable {
        case currencyOrNumber
        case percent
        case raw
    }

    var type: ParserType
    var stripChars: [String]

    init(type: ParserType = .currencyOrNumber, stripChars: [String] = ["$", ",", " "]) {
        self.type = type
        self.stripChars = stripChars
    }
}

struct TrackerHistory: Codable, Equatable {
    enum RetentionPolicy: String, Codable {
        case count
        case days
    }

    var retentionPolicy: RetentionPolicy
    var retentionValue: Int
    var displayWindow: Int

    init(retentionPolicy: RetentionPolicy = .days, retentionValue: Int = 7, displayWindow: Int = 24) {
        self.retentionPolicy = retentionPolicy
        self.retentionValue = retentionValue
        self.displayWindow = displayWindow
    }
}

struct SelectorHistoryEntry: Codable, Equatable {
    var selector: String
    var replacedAt: Date

    init(selector: String, replacedAt: Date = Date()) {
        self.selector = selector
        self.replacedAt = replacedAt
    }
}
