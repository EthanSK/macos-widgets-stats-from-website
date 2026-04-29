//
//  PreferencesWindow.swift
//  MacosStatsWidget
//
//  Main preferences container.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesWindow: View {
    @EnvironmentObject private var store: AppGroupStore
    @State private var selection: PreferencesSection? = .trackers
    @State private var mcpIdentifyPresentation: MCPIdentifyPresentation?
    @State private var isSelectorPackDropTargeted = false
    @State private var selectorPackImportMessage: String?

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
        .onDrop(
            of: [SelectorPack.contentTypeIdentifier, UTType.fileURL.identifier, UTType.json.identifier],
            isTargeted: $isSelectorPackDropTargeted,
            perform: importDroppedSelectorPacks
        )
        .overlay(alignment: .bottomTrailing) {
            if isSelectorPackDropTargeted {
                Label("Import selector pack", systemImage: "square.and.arrow.down")
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
            } else if let selectorPackImportMessage {
                Text(selectorPackImportMessage)
                    .font(.caption)
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
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

    private func importDroppedSelectorPacks(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    if let error {
                        showSelectorPackImportResult(error.localizedDescription)
                        return
                    }

                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        importSelectorPack(url)
                    } else if let url = item as? URL {
                        importSelectorPack(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(SelectorPack.contentTypeIdentifier) || provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                handled = true
                let type = provider.hasItemConformingToTypeIdentifier(SelectorPack.contentTypeIdentifier)
                    ? SelectorPack.contentTypeIdentifier
                    : UTType.json.identifier
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let error {
                        showSelectorPackImportResult(error.localizedDescription)
                        return
                    }
                    guard let data else {
                        showSelectorPackImportResult("Dropped selector pack was empty.")
                        return
                    }
                    importSelectorPack(data)
                }
            }
        }
        return handled
    }

    private func importSelectorPack(_ url: URL) {
        do {
            let tracker = try SelectorPackImportCoordinator.importSelectorPack(at: url)
            DispatchQueue.main.async {
                store.reloadFromDisk()
                selection = .trackers
                showSelectorPackImportResult("Imported \(tracker.name).")
            }
        } catch {
            showSelectorPackImportResult(error.localizedDescription)
        }
    }

    private func importSelectorPack(_ data: Data) {
        do {
            let pack = try SelectorPack.decodeStrict(from: data)
            let tracker = try pack.makeTracker()
            try AppGroupStore.mutateSharedConfiguration { configuration in
                configuration.trackers.append(tracker)
            }
            DispatchQueue.main.async {
                store.reloadFromDisk()
                selection = .trackers
                showSelectorPackImportResult("Imported \(tracker.name).")
            }
        } catch {
            showSelectorPackImportResult(error.localizedDescription)
        }
    }

    private func showSelectorPackImportResult(_ message: String) {
        DispatchQueue.main.async {
            selectorPackImportMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if selectorPackImportMessage == message {
                    selectorPackImportMessage = nil
                }
            }
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
