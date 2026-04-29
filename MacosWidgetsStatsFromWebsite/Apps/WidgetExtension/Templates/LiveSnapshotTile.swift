//
//  LiveSnapshotTile.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Small Snapshot template with a cropped live image.
//

import SwiftUI

struct LiveSnapshotTileTemplate: View {
    let item: WidgetTrackerItem?

    var body: some View {
        SnapshotImageView(item: item, cornerRadius: 4)
            .overlay(alignment: .bottomLeading) {
                SnapshotOverlay(item: item)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(item?.title ?? "Snapshot tracker"), updated \(item?.updatedText ?? "never")"))
    }
}
