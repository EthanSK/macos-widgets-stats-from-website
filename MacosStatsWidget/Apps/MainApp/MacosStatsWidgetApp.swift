//
//  MacosStatsWidgetApp.swift
//  MacosStatsWidget
//
//  App entry and scene wiring.
//

import SwiftUI

@main
struct MacosStatsWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppGroupStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 900, height: 620)
    }
}
