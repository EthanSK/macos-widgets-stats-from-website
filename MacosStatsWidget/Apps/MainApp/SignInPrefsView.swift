//
//  SignInPrefsView.swift
//  MacosStatsWidget
//
//  Sign in, re-sign in, and reset browser controls.
//

import SwiftUI

struct SignInPrefsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Profile") {
                    Text("macos-stats-widget")
                        .monospaced()
                }
                Text("WKWebsiteDataStore profile name: macos-stats-widget")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 12) {
                    Button("Sign in to a site") {}
                        .disabled(true)
                    Button("Re-sign in to...") {}
                        .disabled(true)
                    Button("Reset browser data") {}
                        .disabled(true)
                }

                Text("Coming in v0.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }
}
