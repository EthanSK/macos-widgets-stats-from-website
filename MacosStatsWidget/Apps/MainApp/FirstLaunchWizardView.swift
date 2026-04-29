//
//  FirstLaunchWizardView.swift
//  MacosStatsWidget
//
//  Skippable first-launch setup: sign in, identify an element, create first widget.
//

import SwiftUI

struct FirstLaunchWizardView: View {
    @EnvironmentObject private var store: AppGroupStore
    @Binding var isPresented: Bool

    @State private var step: Step = .signIn
    @State private var starter: Starter = .codexUsage
    @State private var customURL = ""
    @State private var signInBrowser: BrowserPresentation?
    @State private var identifyBrowser: BrowserPresentation?
    @State private var didOpenSignInBrowser = false

    @State private var trackerName = "First Tracker"
    @State private var renderMode: RenderMode = .text
    @State private var icon = Tracker.defaultIcon
    @State private var accentColor = Color(hexString: Tracker.defaultAccentColorHex) ?? .accentColor
    @State private var createdTracker: Tracker?
    @State private var createdWidgetConfiguration: WidgetConfiguration?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            switch step {
            case .signIn:
                signInStep
            case .identify:
                identifyStep
            case .widget:
                widgetStep
            }
        }
        .padding(28)
        .frame(width: 620)
        .frame(minHeight: 430)
        .sheet(item: $signInBrowser, onDismiss: {
            if didOpenSignInBrowser {
                step = .identify
            }
        }) { presentation in
            InAppBrowserView(initialURL: presentation.url, allowsElementIdentification: false)
                .frame(width: 1100, height: 760)
        }
        .sheet(item: $identifyBrowser) { presentation in
            InAppBrowserView(initialURL: presentation.url, renderMode: renderMode, allowsElementIdentification: true) { pick in
                createFirstTracker(from: pick, url: presentation.url)
            }
            .frame(width: 1100, height: 760)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to macOS Stats Widget")
                .font(.title2.weight(.semibold))
            Text(step.subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("First tracked site", selection: $starter) {
                ForEach(Starter.allCases) { starter in
                    Text(starter.title).tag(starter)
                }
            }

            if starter == .custom {
                TextField("https://example.com", text: $customURL)
                    .textFieldStyle(.roundedBorder)
            } else {
                LabeledContent("URL") {
                    Text(starter.urlString)
                        .textSelection(.enabled)
                }
            }

            Text("The in-app browser uses the shared macos-stats-widget WebKit profile for cookies and sign-in state.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 16)

            HStack {
                Button("Skip") {
                    skip()
                }
                Spacer()
                Button("Open browser") {
                    openSignInBrowser()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var identifyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section {
                    TextField("Name", text: $trackerName)
                    Picker("Render mode", selection: $renderMode) {
                        ForEach(RenderMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        TextField("SF Symbol", text: $icon)
                        Image(systemName: icon.isEmpty ? Tracker.defaultIcon : icon)
                            .frame(width: 24)
                    }

                    ColorPicker("Accent color", selection: $accentColor, supportsOpacity: false)
                }
            }
            .formStyle(.grouped)

            Text("Hover the value you want to track, click to select it, then confirm the preview.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 16)

            HStack {
                Button("Skip") {
                    skip()
                }
                Spacer()
                Button("Back") {
                    step = .signIn
                }
                Button("Identify Element") {
                    openIdentifyBrowser()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var widgetStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let createdWidgetConfiguration {
                LabeledContent("Widget") {
                    Text("\(createdWidgetConfiguration.name) - \(createdWidgetConfiguration.templateID.displayName) - \(createdWidgetConfiguration.size.displayName)")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add it from the desktop widget picker:")
                    .font(.headline)
                Text("1. Right-click the desktop and choose Edit Widgets")
                Text("2. Search for macOS Stats Widget")
                Text("3. Drag the small widget onto the desktop")
                Text("4. Pick the new configuration")
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            HStack {
                Button("I'll do this later") {
                    finish()
                }
                Spacer()
                Button("Done") {
                    finish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var selectedURL: URL? {
        let urlString = starter == .custom ? customURL : starter.urlString
        let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private func openSignInBrowser() {
        guard let url = selectedURL else {
            errorMessage = "Enter a valid http or https URL."
            return
        }

        errorMessage = nil
        didOpenSignInBrowser = true
        signInBrowser = BrowserPresentation(url: url)
        if trackerName == "First Tracker" {
            trackerName = defaultTrackerName(for: url)
        }
    }

    private func openIdentifyBrowser() {
        guard let url = selectedURL else {
            errorMessage = "Enter a valid http or https URL."
            step = .signIn
            return
        }

        guard !trackerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Name the tracker before identifying an element."
            return
        }

        errorMessage = nil
        identifyBrowser = BrowserPresentation(url: url)
    }

    private func createFirstTracker(from pick: ElementPick, url: URL) {
        var tracker = Tracker(
            name: trackerName.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.absoluteString,
            renderMode: renderMode,
            selector: pick.selector,
            elementBoundingBox: pick.bbox,
            label: nil,
            icon: icon.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Tracker.defaultIcon,
            accentColorHex: accentColor.hexString ?? Tracker.defaultAccentColorHex
        )
        tracker.browserProfile = Tracker.defaultBrowserProfile

        let widgetConfiguration = WidgetConfiguration(
            name: "\(tracker.name) Widget",
            templateID: .singleBigNumber,
            size: .small,
            layout: .single,
            trackerIDs: [tracker.id]
        )

        store.addTracker(tracker)
        store.addWidgetConfiguration(widgetConfiguration)
        createdTracker = tracker
        createdWidgetConfiguration = widgetConfiguration
        step = .widget
    }

    private func skip() {
        store.persist()
        isPresented = false
    }

    private func finish() {
        store.persist()
        isPresented = false
    }

    private func defaultTrackerName(for url: URL) -> String {
        switch starter {
        case .codexUsage:
            return "Codex Usage"
        case .claudeSpend:
            return "Claude Code Spend"
        case .custom:
            return url.host ?? "First Tracker"
        }
    }
}

private enum Step {
    case signIn
    case identify
    case widget

    var subtitle: String {
        switch self {
        case .signIn:
            return "Step 1 of 3: sign in to the first site you want to track."
        case .identify:
            return "Step 2 of 3: identify the value or page region."
        case .widget:
            return "Step 3 of 3: create the first desktop widget."
        }
    }
}

private enum Starter: String, CaseIterable, Identifiable {
    case codexUsage
    case claudeSpend
    case custom

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .codexUsage:
            return "Codex usage"
        case .claudeSpend:
            return "Claude Code spend"
        case .custom:
            return "Custom URL"
        }
    }

    var urlString: String {
        switch self {
        case .codexUsage:
            return "https://platform.openai.com/usage"
        case .claudeSpend:
            return "https://console.anthropic.com/settings"
        case .custom:
            return ""
        }
    }
}

private struct BrowserPresentation: Identifiable {
    let id = UUID()
    let url: URL
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
