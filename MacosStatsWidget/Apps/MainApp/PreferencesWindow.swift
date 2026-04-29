//
//  PreferencesWindow.swift
//  MacosStatsWidget
//
//  Main preferences container.
//

import AppKit
import SwiftUI

struct PreferencesWindow: View {
    @EnvironmentObject private var store: AppGroupStore
    @State private var selection: PreferencesSection? = .trackers
    @State private var mcpIdentifyPresentation: MCPIdentifyPresentation?

    var body: some View {
        NavigationSplitView {
            List(PreferencesSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
            .navigationTitle("Preferences")
        } detail: {
            switch selection ?? .trackers {
            case .trackers:
                TrackersListView()
            case .widgets:
                WidgetConfigsView()
            case .browser:
                SignInPrefsView()
            case .selfHeal:
                SelfHealPrefsView()
            case .about:
                AboutPrefsView()
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: AppNavigationEvents.openTrackerSettingsNotification)) { _ in
            selection = .trackers
        }
        .onReceive(NotificationCenter.default.publisher(for: .mcpIdentifyElementRequested)) { notification in
            openMCPIdentifyRequest(notification)
        }
        .sheet(item: $mcpIdentifyPresentation) { presentation in
            InAppBrowserView(initialURL: presentation.url, renderMode: .text, allowsElementIdentification: true) { pick in
                completeMCPIdentifyRequest(presentation, pick: pick)
            }
            .frame(width: 1100, height: 760)
        }
    }

    private func openMCPIdentifyRequest(_ notification: Notification) {
        guard let trackerIDString = notification.userInfo?["trackerID"] as? String,
              let trackerID = UUID(uuidString: trackerIDString),
              let urlString = notification.userInfo?["url"] as? String,
              let url = URL(string: urlString) else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        store.reloadFromDisk()

        if !store.trackers.contains(where: { $0.id == trackerID }) {
            store.addTracker(Tracker(id: trackerID, name: "Pending \(url.host ?? "Tracker")", url: url.absoluteString, selector: ""))
        }

        selection = .browser
        mcpIdentifyPresentation = MCPIdentifyPresentation(trackerID: trackerID, url: url)
    }

    private func completeMCPIdentifyRequest(_ presentation: MCPIdentifyPresentation, pick: ElementPick) {
        store.reloadFromDisk()
        guard let tracker = store.trackers.first(where: { $0.id == presentation.trackerID }) else {
            return
        }

        var updated = tracker
        if updated.name.hasPrefix("Pending ") {
            updated.name = presentation.url.host ?? "Tracked Element"
        }
        updated.selector = pick.selector
        updated.elementBoundingBox = pick.bbox
        updated.url = presentation.url.absoluteString
        store.updateTracker(updated)

        AuditLog.record(
            trackerID: updated.id,
            beforeSelector: nil,
            afterSelector: pick.selector,
            outcome: "human_in_loop_identified",
            source: "mcp"
        )
        NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
    }
}

private struct MCPIdentifyPresentation: Identifiable {
    let id = UUID()
    let trackerID: UUID
    let url: URL
}

private enum PreferencesSection: String, CaseIterable, Hashable, Identifiable {
    case trackers
    case widgets
    case browser
    case selfHeal
    case about

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .trackers:
            return "Trackers"
        case .widgets:
            return "Widgets"
        case .browser:
            return "Browser & Sign-in"
        case .selfHeal:
            return "Self-heal"
        case .about:
            return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .trackers:
            return "list.bullet.rectangle"
        case .widgets:
            return "rectangle.grid.2x2"
        case .browser:
            return "globe"
        case .selfHeal:
            return "wrench.and.screwdriver"
        case .about:
            return "info.circle"
        }
    }
}

private struct AboutPrefsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS Stats Widget")
                .font(.title2.weight(.semibold))
            Text("Preferences shell for v0.2.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
        .navigationTitle("About")
    }
}
