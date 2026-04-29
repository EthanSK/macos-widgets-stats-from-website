//
//  SelfHealPrefsView.swift
//  MacosStatsWidget
//
//  Self-heal preferences placeholder.
//

import SwiftUI

struct SelfHealPrefsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Self-heal")
                .font(.title2.weight(.semibold))
            Text("Regex fallback and external agent healing controls will be wired in a later phase.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
        .navigationTitle("Self-heal")
    }
}
