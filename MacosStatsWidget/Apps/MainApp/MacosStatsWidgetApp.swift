//
//  MacosStatsWidgetApp.swift
//  MacosStatsWidget
//
//  App entry and scene wiring.
//

import Darwin
import Foundation
import SwiftUI

@main
struct MacosStatsWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppGroupStore
    @StateObject private var backgroundScheduler: BackgroundScheduler

    init() {
        if CommandLine.arguments.contains("--mcp-stdio") {
            MCPServer.shared.runStdioServer()
            Darwin.exit(0)
        }

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
                .onReceive(NotificationCenter.default.publisher(for: .mcpConfigurationChanged)) { _ in
                    store.reloadFromDisk()
                    backgroundScheduler.sync()
                }
        }
        .defaultSize(width: 900, height: 620)
    }
}
