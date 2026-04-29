//
//  WidgetConfigsView.swift
//  MacosStatsWidget
//
//  List of widget configurations.
//

import SwiftUI

struct WidgetConfigsView: View {
    @EnvironmentObject private var store: AppGroupStore

    var body: some View {
        ZStack {
            if store.widgetConfigurations.isEmpty {
                Text("No widget configurations yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.widgetConfigurations) { configuration in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(configuration.name)
                            .font(.body.weight(.medium))
                        Text(configuration.templateID.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Widgets")
    }
}
