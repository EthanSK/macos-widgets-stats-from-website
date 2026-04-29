//
//  TrackerEditorView.swift
//  MacosStatsWidget
//
//  Add/edit tracker form.
//

import AppKit
import SwiftUI

struct TrackerEditorView: View {
    enum Mode {
        case add
        case edit
    }

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Tracker
    @State private var labelText: String
    @State private var accentColor: Color

    let mode: Mode
    let onSave: (Tracker) -> Void

    init(mode: Mode, tracker: Tracker, onSave: @escaping (Tracker) -> Void) {
        self.mode = mode
        self.onSave = onSave
        _draft = State(initialValue: tracker)
        _labelText = State(initialValue: tracker.label ?? "")
        _accentColor = State(initialValue: Color(hexString: tracker.accentColorHex) ?? Color(hexString: Tracker.defaultAccentColorHex) ?? .accentColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("URL", text: $draft.url)
                        if !urlValidationMessage.isEmpty {
                            Text(urlValidationMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Picker("Render mode", selection: $draft.renderMode) {
                        ForEach(RenderMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper(value: $draft.refreshIntervalSec, in: refreshIntervalRange, step: refreshIntervalStep) {
                        Text("Refresh interval: \(formattedRefreshInterval)")
                    }
                } header: {
                    Text("Tracker")
                }

                Section {
                    TextField("Label", text: $labelText)

                    HStack {
                        TextField("SF Symbol", text: $draft.icon)
                        Image(systemName: draft.icon.isEmpty ? Tracker.defaultIcon : draft.icon)
                            .frame(width: 24)
                    }

                    ColorPicker("Accent color", selection: $accentColor, supportsOpacity: false)
                } header: {
                    Text("Presentation")
                }

                Section {
                    LabeledContent("Selector") {
                        Text("Captured via Identify Element flow — coming in v0.3")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Capture")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .navigationTitle(mode == .add ? "Add Tracker" : "Edit Tracker")
        .onChange(of: draft.renderMode) { newMode in
            draft.refreshIntervalSec = newMode.defaultRefreshIntervalSec
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && validatedURL != nil
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURL: String {
        draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedURL: URL? {
        guard let components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              let url = components.url else {
            return nil
        }

        return url
    }

    private var urlValidationMessage: String {
        guard !trimmedURL.isEmpty, validatedURL == nil else {
            return ""
        }

        return "Enter a valid http or https URL."
    }

    private var refreshIntervalRange: ClosedRange<Int> {
        switch draft.renderMode {
        case .text:
            return 60...86_400
        case .snapshot:
            return 1...60
        }
    }

    private var refreshIntervalStep: Int {
        draft.renderMode == .text ? 60 : 1
    }

    private var formattedRefreshInterval: String {
        if draft.refreshIntervalSec < 60 {
            return "\(draft.refreshIntervalSec) sec"
        }

        let minutes = draft.refreshIntervalSec / 60
        if minutes < 60 {
            return "\(minutes) min"
        }

        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private func save() {
        guard let url = validatedURL else {
            return
        }

        var savedTracker = draft
        savedTracker.name = trimmedName
        savedTracker.url = url.absoluteString
        savedTracker.label = labelText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        savedTracker.icon = savedTracker.icon.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Tracker.defaultIcon
        savedTracker.accentColorHex = accentColor.hexString ?? Tracker.defaultAccentColorHex
        savedTracker.browserProfile = Tracker.defaultBrowserProfile
        savedTracker.selector = ""
        savedTracker.elementBoundingBox = nil
        onSave(savedTracker)
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension Color {
    init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let hex = Int(value, radix: 16) else {
            return nil
        }

        let red = Double((hex >> 16) & 0xff) / 255.0
        let green = Double((hex >> 8) & 0xff) / 255.0
        let blue = Double(hex & 0xff) / 255.0
        self.init(red: red, green: green, blue: blue)
    }

    var hexString: String? {
        let color = NSColor(self)
        guard let rgbColor = color.usingColorSpace(.sRGB) else {
            return nil
        }

        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
}
