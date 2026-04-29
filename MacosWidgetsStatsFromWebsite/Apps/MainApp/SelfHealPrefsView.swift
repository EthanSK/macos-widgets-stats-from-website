//
//  SelfHealPrefsView.swift
//  MacosWidgetsStatsFromWebsite
//
//  User-driven self-heal preferences and audit history.
//

import AppKit
import SwiftUI

struct SelfHealPrefsView: View {
    @EnvironmentObject private var store: AppGroupStore
    @State private var auditEntries: [AuditLogEntry] = AuditLog.entries()
    @State private var mcpToken: String?

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Regex fallback",
                    isOn: Binding(
                        get: { store.preferences.selfHeal.regexFallbackEnabled },
                        set: { value in
                            store.preferences.selfHeal.regexFallbackEnabled = value
                            store.persist()
                        }
                    )
                )

                Toggle(
                    "Allow external agent selector updates",
                    isOn: Binding(
                        get: { store.preferences.selfHeal.externalAgentHealEnabled },
                        set: { value in
                            store.preferences.selfHeal.externalAgentHealEnabled = value
                            store.persist()
                        }
                    )
                )
            } header: {
                Text("Fallbacks")
            } footer: {
                Text("Fallback extraction is local regex only. The app never invokes AI CLIs.")
            }

            Section {
                if auditEntries.isEmpty {
                    Text("No heal attempts recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    List(auditEntries.suffix(50).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.outcome.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(entry.timestamp, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(entry.source) · \(entry.trackerID.uuidString)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let before = entry.beforeSelector, let after = entry.afterSelector {
                                Text("\(before) → \(after)")
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .frame(minHeight: 180)
                }
            } header: {
                HStack {
                    Text("Audit Log")
                    Spacer()
                    Button {
                        auditEntries = AuditLog.entries()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh Audit Log")
                }
            }

            Section {
                LabeledContent("Socket") {
                    Text(AppGroupPaths.mcpSocketURL().path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                if let mcpToken {
                    Text(mcpToken)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("Token hidden.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Reveal token") {
                        mcpToken = MCPServer.shared.currentToken()
                    }

                    Button("Copy token") {
                        let token = mcpToken ?? MCPServer.shared.currentToken()
                        if let token {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                            mcpToken = token
                        }
                    }
                }
            } header: {
                Text("MCP")
            } footer: {
                Text("Socket clients authenticate with this launch token in X-Auth or initialize params. Stdio MCP does not require a token.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Self-heal")
        .onAppear {
            auditEntries = AuditLog.entries()
        }
    }
}
