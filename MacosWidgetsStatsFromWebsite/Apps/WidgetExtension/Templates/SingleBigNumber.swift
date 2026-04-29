//
//  SingleBigNumber.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Small Text template with one hero value.
//

import SwiftUI

struct SingleBigNumberTemplate: View {
    let item: WidgetTrackerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item?.title ?? "Tracker")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(item?.value ?? "--")
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .numericValueTransition()
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: item?.status == .ok ? "arrow.clockwise" : "exclamationmark.triangle.fill")
                Text(item?.updatedText ?? "not updated")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item?.title ?? "Tracker"), \(item?.value ?? "no value"), updated \(item?.updatedText ?? "never")"))
    }

    private var statusColor: Color {
        switch item?.status {
        case .broken:
            return .red
        case .stale, nil:
            return .secondary
        case .ok:
            return .primary
        }
    }
}
