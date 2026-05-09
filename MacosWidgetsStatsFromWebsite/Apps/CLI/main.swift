//
//  main.swift
//  MacosWidgetsStatsFromWebsiteCLI
//
//  Power-user adjunct and MCP stdio entrypoint.
//

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--mcp-stdio") || arguments.first == "mcp-stdio" {
    MCPServer.shared.runStdioServer()
    exit(0)
}

if arguments.first == "mcp-token" {
    if let token = MCPServer.shared.currentToken() {
        print(token)
    } else {
        fputs("No MCP token is available. Launch the app to start the socket server.\n", stderr)
        exit(1)
    }
} else {
    // Read CFBundleShortVersionString from the embedded Info.plist (xcodebuild
    // links the CLI Info.plist into the binary via INFOPLIST_FILE). Single
    // source of truth lives in project.yml MARKETING_VERSION; see AGENTS.md.
    let marketingVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    print("macos-widgets-stats-from-website CLI v\(marketingVersion)")
    print("Usage: macos-widgets-stats-from-website mcp-stdio | mcp-token")
}
