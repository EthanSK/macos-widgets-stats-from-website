//
//  MacosStatsWidgetApp.swift
//  MacosStatsWidget
//
//  App entry and scene wiring.
//

import Darwin
import Foundation
import AppKit
import SwiftUI

@main
struct MacosStatsWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppGroupStore
    @StateObject private var backgroundScheduler: BackgroundScheduler
    @State private var showsFirstLaunchFlow: Bool

    init() {
        if CommandLine.arguments.contains("--mcp-stdio") {
            MCPServer.shared.runStdioServer()
            Darwin.exit(0)
        }

        let store = AppGroupStore()
        _store = StateObject(wrappedValue: store)
        _backgroundScheduler = StateObject(wrappedValue: BackgroundScheduler(store: store))
        _showsFirstLaunchFlow = State(initialValue: !AppGroupStore.hasExistingConfigurationFile())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(backgroundScheduler)
                .onAppear {
                    backgroundScheduler.sync()
                    DockBadgeUpdater.update()
                }
                .onReceive(store.$trackers) { _ in
                    backgroundScheduler.sync()
                }
                .onReceive(NotificationCenter.default.publisher(for: .mcpConfigurationChanged)) { _ in
                    store.reloadFromDisk()
                    backgroundScheduler.sync()
                    DockBadgeUpdater.update()
                }
                .sheet(isPresented: $showsFirstLaunchFlow) {
                    FirstLaunchWizardView(isPresented: $showsFirstLaunchFlow)
                        .environmentObject(store)
                }
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdateController.shared.checkForUpdates()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .help) {
                Button("Show First-Launch Flow") {
                    showsFirstLaunchFlow = true
                }
            }
        }
    }
}
