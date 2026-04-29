//
//  PlaceholderWidget.swift
//  MacosStatsWidgetWidget
//
//  v0.1 stub — see PLAN.md §9 for the full design.
//

import SwiftUI
import WidgetKit

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        let entry = PlaceholderEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct PlaceholderWidgetEntryView: View {
    let entry: PlaceholderEntry

    var body: some View {
        Text("Configure in main app")
            .multilineTextAlignment(.center)
            .padding()
    }
}

struct PlaceholderWidget: Widget {
    private let kind = "PlaceholderWidget"

    var body: some SwiftUI.WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaceholderProvider()) { entry in
            PlaceholderWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("macOS Stats Widget")
        .description("Configure widgets in the main app.")
    }
}
