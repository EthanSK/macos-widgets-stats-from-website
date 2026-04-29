//
//  TrackersListView.swift
//  MacosStatsWidget
//
//  List of configured trackers.
//

import SwiftUI

struct TrackersListView: View {
    @EnvironmentObject private var store: AppGroupStore
    @EnvironmentObject private var backgroundScheduler: BackgroundScheduler
    @State private var selectedTrackerID: UUID?
    @State private var editorPresentation: TrackerEditorPresentation?

    var body: some View {
        ZStack {
            if store.trackers.isEmpty {
                Text("No trackers yet — click + to add one")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedTrackerID) {
                    ForEach(store.trackers) { tracker in
                        TrackerRowView(tracker: tracker)
                            .tag(tracker.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                edit(tracker)
                            }
                            .contextMenu {
                                Button("Edit") {
                                    edit(tracker)
                                }
                                Button("Duplicate") {
                                    store.duplicateTracker(tracker)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    delete(tracker)
                                }
                            }
                    }
                    .onMove(perform: store.moveTrackers)
                }
            }
        }
        .navigationTitle("Trackers")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    add()
                } label: {
                    Label("Add Tracker", systemImage: "plus")
                }
                .help("Add Tracker")

                Button {
                    editSelected()
                } label: {
                    Label("Edit Tracker", systemImage: "pencil")
                }
                .disabled(selectedTracker == nil)
                .help("Edit Tracker")

                Button {
                    scrapeSelected()
                } label: {
                    Label("Scrape Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(selectedTracker == nil)
                .help("Scrape Now")
            }
        }
        .sheet(item: $editorPresentation) { presentation in
            TrackerEditorView(mode: presentation.mode, tracker: presentation.tracker) { savedTracker in
                store.upsertTracker(savedTracker)
                selectedTrackerID = savedTracker.id
            }
            .frame(width: 500)
        }
        .overlay(alignment: .bottomLeading) {
            if let error = store.lastPersistenceError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
    }

    private var selectedTracker: Tracker? {
        guard let selectedTrackerID else {
            return nil
        }

        return store.trackers.first { $0.id == selectedTrackerID }
    }

    private func add() {
        editorPresentation = TrackerEditorPresentation(mode: .add, tracker: Tracker())
    }

    private func editSelected() {
        guard let selectedTracker else {
            return
        }

        edit(selectedTracker)
    }

    private func scrapeSelected() {
        guard let selectedTrackerID else {
            return
        }

        backgroundScheduler.triggerScrapeNow(trackerID: selectedTrackerID)
    }

    private func edit(_ tracker: Tracker) {
        selectedTrackerID = tracker.id
        editorPresentation = TrackerEditorPresentation(mode: .edit, tracker: tracker)
    }

    private func delete(_ tracker: Tracker) {
        if selectedTrackerID == tracker.id {
            selectedTrackerID = nil
        }

        store.deleteTracker(id: tracker.id)
    }
}

private struct TrackerRowView: View {
    let tracker: Tracker

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tracker.icon.isEmpty ? Tracker.defaultIcon : tracker.icon)
                .foregroundStyle(Color(hexString: tracker.accentColorHex) ?? .accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(tracker.name.isEmpty ? "Untitled tracker" : tracker.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(tracker.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Text(tracker.renderMode.rawValue)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(tracker.renderMode == .text ? Color.green.opacity(0.18) : Color.blue.opacity(0.16))
                )
                .foregroundStyle(tracker.renderMode == .text ? .green : .blue)
        }
        .padding(.vertical, 4)
    }
}

private struct TrackerEditorPresentation: Identifiable {
    let id = UUID()
    let mode: TrackerEditorView.Mode
    let tracker: Tracker
}
