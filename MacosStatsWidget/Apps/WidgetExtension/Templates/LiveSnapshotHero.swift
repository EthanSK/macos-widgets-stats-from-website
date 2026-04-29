//
//  LiveSnapshotHero.swift
//  MacosStatsWidgetWidget
//
//  Large Snapshot template with full-bleed image.
//

import SwiftUI

struct LiveSnapshotHeroTemplate: View {
    let item: WidgetTrackerItem?

    var body: some View {
        SnapshotImageView(item: item, cornerRadius: 0)
            .overlay(alignment: .topLeading) {
                SnapshotOverlay(item: item)
                    .padding(10)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(item?.title ?? "Snapshot tracker"), updated \(item?.updatedText ?? "never")"))
    }
}
