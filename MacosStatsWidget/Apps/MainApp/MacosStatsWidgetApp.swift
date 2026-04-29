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
    @StateObject private var store: AppGroupStore
    @StateObject private var backgroundScheduler: BackgroundScheduler

    init() {
        let store = AppGroupStore()
        _store = StateObject(wrappedValue: store)
        _backgroundScheduler = StateObject(wrappedValue: BackgroundScheduler(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(backgroundScheduler)
                .onAppear {
                    backgroundScheduler.sync()
                }
                .onReceive(store.$trackers) { _ in
                    backgroundScheduler.sync()
                }
        }
        .defaultSize(width: 900, height: 620)
    }
}
