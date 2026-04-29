//
//  SnapshotPlusStat.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Medium mixed template with one snapshot and one text tracker.
//

import SwiftUI

struct SnapshotPlusStatTemplate: View {
    let snapshotItem: WidgetTrackerItem?
    let textItem: WidgetTrackerItem?

    var body: some View {
        HStack(spacing: 12) {
            LiveSnapshotTileTemplate(item: snapshotItem)
                .frame(width: 142)

            SingleBigNumberTemplate(item: textItem)
                .padding(.vertical, -8)
        }
        .padding(8)
        .accessibilityElement(children: .contain)
    }
}
