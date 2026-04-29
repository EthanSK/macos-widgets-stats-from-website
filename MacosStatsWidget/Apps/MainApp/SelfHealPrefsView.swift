//
//  SelfHealPrefsView.swift
//  MacosStatsWidget
//
//  User-driven self-heal preferences and audit history.
//

import SwiftUI

struct SelfHealPrefsView: View {
    @EnvironmentObject private var store: AppGroupStore
    @State private var auditEntries: [AuditLogEntry] = AuditLog.entries()

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
        }
        .formStyle(.grouped)
        .navigationTitle("Self-heal")
        .onAppear {
            auditEntries = AuditLog.entries()
        }
    }
}
