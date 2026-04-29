//
//  PreferencesWindow.swift
//  MacosStatsWidget
//
//  Main preferences container.
//

import SwiftUI

struct PreferencesWindow: View {
    @State private var selection: PreferencesSection? = .trackers

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
    }
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
