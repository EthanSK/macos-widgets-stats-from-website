//
//  SignInPrefsView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Sign in, re-sign in, and reset browser controls.
//

import SwiftUI
import WebKit

struct SignInPrefsView: View {
    @State private var browserPresentation: SignInBrowserPresentation?
    @State private var cookieDomains: [String] = []
    @State private var isLoadingDomains = false
    @State private var statusMessage: String?
    @State private var showsResetConfirmation = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Profile") {
                    Text(WebViewProfile.name)
                        .monospaced()
                }
                Text("WKWebsiteDataStore profile name: \(WebViewProfile.name)")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 12) {
                    Button("Sign in to a site") {
                        browserPresentation = SignInBrowserPresentation(url: nil)
                    }

                    Menu("Re-sign in to...") {
                        ForEach(cookieDomains, id: \.self) { domain in
                            Button(domain) {
                                openBrowser(forDomain: domain)
                            }
                        }
                    }
                    .disabled(cookieDomains.isEmpty)

                    Button("Reset browser data", role: .destructive) {
                        showsResetConfirmation = true
                    }
                }

                Text(domainStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Stored credentials (Keychain): 0 entries")
                Text("Passkeys available: AuthenticationServices framework")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .navigationTitle("Browser & Sign-in")
        .onAppear {
            loadCookieDomains()
        }
        .sheet(item: $browserPresentation, onDismiss: loadCookieDomains) { presentation in
            InAppBrowserView(initialURL: presentation.url, allowsElementIdentification: false)
                .frame(width: 1100, height: 760)
        }
        .alert("Reset browser data?", isPresented: $showsResetConfirmation) {
            Button("Reset Browser Data", role: .destructive) {
                resetBrowserData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes cookies, local storage, IndexedDB, service workers, and caches for the shared browser profile.")
        }
    }

    private var domainStatusText: String {
        if isLoadingDomains {
            return "Loading signed-in domains..."
        }

        if cookieDomains.isEmpty {
            return "No cookie-backed sites found for this profile."
        }

        return "\(cookieDomains.count) cookie-backed site\(cookieDomains.count == 1 ? "" : "s") found."
    }

    private func openBrowser(forDomain domain: String) {
        let url = URL(string: "https://\(domain)")
        browserPresentation = SignInBrowserPresentation(url: url)
    }

    private func loadCookieDomains() {
        isLoadingDomains = true
        WebViewProfile.shared.websiteDataStore.fetchDataRecords(ofTypes: Set([WKWebsiteDataTypeCookies])) { records in
            DispatchQueue.main.async {
                cookieDomains = records
                    .map(\.displayName)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                isLoadingDomains = false
            }
        }
    }

    private func resetBrowserData() {
        statusMessage = "Resetting browser data..."
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WebViewProfile.shared.websiteDataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                statusMessage = "Browser data reset."
                loadCookieDomains()
            }
        }
    }
}

private struct SignInBrowserPresentation: Identifiable {
    let id = UUID()
    let url: URL?
}
