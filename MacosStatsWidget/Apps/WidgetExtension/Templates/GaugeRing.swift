//
//  GaugeRing.swift
//  MacosStatsWidgetWidget
//
//  Small Text template with a threshold gauge.
//

import SwiftUI

struct GaugeRingTemplate: View {
    let item: WidgetTrackerItem?

    var body: some View {
        VStack(spacing: 8) {
            Gauge(value: gaugeValue, in: 0...1) {
                Text(item?.title ?? "Tracker")
            } currentValueLabel: {
                Text(item?.value ?? "--")
                    .font(.caption.weight(.semibold))
                    .minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(gaugeTint)
            .frame(width: 92, height: 92)

            Text(item?.title ?? "Tracker")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private var gaugeValue: Double {
        guard let numeric = item?.numeric else {
            return 0
        }

        return min(max(numeric / 100, 0), 1)
    }

    private var gaugeTint: Color {
        switch gaugeValue {
        case ..<0.7:
            return .green
        case ..<0.9:
            return .orange
        default:
            return .red
        }
    }
}
