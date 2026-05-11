//
//  ChromiumInstallSheet.swift
//  MacosWidgetsStatsFromWebsite
//
//  UI affordance for pre-installing the managed Chromium snapshot.
//
//  The Identify-in-Chrome flow lazily downloads upstream Chromium on first
//  use if no Chromium-family browser is found on disk (Chromium / Brave /
//  Edge / a previously-managed download). That lazy path used to block on
//  an opaque ~150 MB download with no UI feedback, so we surface a
//  dedicated install button on the tracker editor + sign-in prefs + first-
//  launch wizard. This sheet drives the download with a progress bar and
//  surfaces a clear retry path on failure.
//

import AppKit
import SwiftUI

struct ChromiumInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ChromiumInstallViewModel()

    var onCompletion: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(headerLabel, systemImage: headerIcon)
                    .font(.title3.weight(.semibold))
                Text(headerSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch viewModel.state {
            case .idle:
                idleBody
            case .downloading(let fraction):
                downloadingBody(fraction: fraction)
            case .completed:
                completedBody
            case .failed(let message):
                failedBody(message: message)
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                switch viewModel.state {
                case .idle:
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        viewModel.start()
                    } label: {
                        Label("Install Chromium", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                case .downloading:
                    Button("Hide") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                case .completed:
                    Button("Done") {
                        onCompletion?()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        viewModel.start()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: viewModel.state) { newState in
            if case .completed = newState {
                onCompletion?()
            }
        }
    }

    private var headerLabel: String {
        switch viewModel.state {
        case .completed:
            return "Chromium Installed"
        case .failed:
            return "Install Failed"
        default:
            return "Install Chromium"
        }
    }

    private var headerIcon: String {
        switch viewModel.state {
        case .completed:
            return "checkmark.seal"
        case .failed:
            return "exclamationmark.triangle"
        default:
            return "arrow.down.circle"
        }
    }

    private var headerSubtitle: String {
        switch viewModel.state {
        case .idle:
            return "This app needs a Chromium-based browser to scrape signed-in pages and open the Identify view. Downloads the latest upstream Chromium snapshot (~150 MB) into the app's private Application Support folder. Nothing else on your Mac is touched."
        case .downloading:
            return "Downloading the latest upstream Chromium snapshot. This may take a couple of minutes on a slow connection."
        case .completed:
            return "Chromium is ready. You can now open Identify in Chrome from any tracker."
        case .failed:
            return "The Chromium download didn't finish. Check your network and try again, or install Chromium / Brave / Edge from their official sites instead."
        }
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("Downloaded from commondatastorage.googleapis.com/chromium-browser-snapshots — Google's official Chromium build bucket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(.secondary)
                Text("Installs to the app's private Application Support folder. Removable from System Settings or Finder anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func downloadingBody(fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: fraction, total: 1.0)
                .progressViewStyle(.linear)
            Text(progressStatusText(fraction: fraction))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var completedBody: some View {
        Label("Chromium installed and ready.", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
            .font(.callout)
    }

    private func failedBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can also install Chromium, Brave Browser, or Microsoft Edge from their official sites — the app will auto-detect any of them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progressStatusText(fraction: Double) -> String {
        if fraction <= 0 {
            return "Connecting…"
        }
        if fraction >= 0.995 {
            return "Extracting and installing…"
        }
        let percent = Int(round(fraction * 100))
        return "Downloading… \(percent)%"
    }
}

@MainActor
final class ChromiumInstallViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case completed
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func start() {
        // Idempotent — if Chromium became available in the background (e.g.
        // user installed Brave during the dialog), short-circuit.
        if ChromeBrowserProfile.shared.chromiumIsAvailable() {
            state = .completed
            return
        }

        state = .downloading(0)
        ChromeBrowserProfile.shared.installChromium(progress: { [weak self] fraction in
            guard let self else { return }
            if case .downloading = self.state {
                self.state = .downloading(fraction)
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Defensive: even after a clean managed download, an invalid
                // `MACOS_WIDGETS_STATS_CHROME_PATH` env override still blocks
                // every future `resolveBrowser()` call. Surface that as a
                // failure here rather than reporting "installed and ready"
                // while the user's actual identify attempts will throw.
                if ChromeBrowserProfile.shared.chromiumIsAvailable() {
                    self.state = .completed
                } else {
                    self.state = .failed(
                        "Chromium downloaded successfully, but the MACOS_WIDGETS_STATS_CHROME_PATH environment variable points at an invalid path. Unset that variable (or fix the path) so the app can find a launchable browser."
                    )
                }
            case .failure(let error):
                let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.state = .failed(description)
            }
        })
    }
}
