//
//  MCPServer.swift
//  MacosStatsWidgetShared
//
//  Embedded JSON-RPC MCP server over stdio or a local UNIX socket.
//

import Darwin
import Foundation

extension Notification.Name {
    static let mcpIdentifyElementRequested = Notification.Name("MacosStatsWidget.MCP.identifyElementRequested")
    static let mcpConfigurationChanged = Notification.Name("MacosStatsWidget.MCP.configurationChanged")
}

final class MCPServer {
    static let shared = MCPServer()

    private let socketQueue = DispatchQueue(label: "com.ethansk.macos-stats-widget.mcp.socket", qos: .utility)
    private let sessionQueue = DispatchQueue(label: "com.ethansk.macos-stats-widget.mcp.sessions", qos: .utility, attributes: .concurrent)
    private var socketFD: Int32 = -1
    private var socketRunning = false

    private init() {}

    @discardableResult
    func rotateLaunchToken() -> String? {
        try? KeychainHelper.rotateMCPToken()
    }

    func currentToken() -> String? {
        try? KeychainHelper.currentMCPToken()
    }

    func startSocketServer() {
        guard !socketRunning else {
            return
        }

        socketRunning = true
        rotateLaunchToken()

        socketQueue.async { [weak self] in
            self?.runSocketServer()
        }
    }

    func stopSocketServer() {
        socketRunning = false
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        try? FileManager.default.removeItem(at: AppGroupPaths.mcpSocketURL())
    }

    func runStdioServer() {
        let session = MCPConnectionSession(
            input: FileHandle.standardInput,
            output: FileHandle.standardOutput,
            transport: .stdio,
            expectedTokenProvider: { nil }
        )
        session.run()
    }

    private func runSocketServer() {
        let socketURL = AppGroupPaths.mcpSocketURL()
        do {
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try? FileManager.default.removeItem(at: socketURL)
        } catch {
            MCPInvocationLogger.logSystem("socket_setup_failed", detail: error.localizedDescription)
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            MCPInvocationLogger.logSystem("socket_create_failed", detail: String(errno))
            return
        }

        socketFD = fd

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let path = socketURL.path
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            MCPInvocationLogger.logSystem("socket_path_too_long", detail: path)
            close(fd)
            return
        }

        _ = path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    strncpy(destination, pointer, maxPathLength - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            MCPInvocationLogger.logSystem("socket_bind_failed", detail: String(errno))
            close(fd)
            return
        }

        chmod(socketURL.path, S_IRUSR | S_IWUSR)

        guard listen(fd, 8) == 0 else {
            MCPInvocationLogger.logSystem("socket_listen_failed", detail: String(errno))
            close(fd)
            return
        }

        while socketRunning {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if socketRunning {
                    MCPInvocationLogger.logSystem("socket_accept_failed", detail: String(errno))
                }
                continue
            }

            sessionQueue.async {
                let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
                let session = MCPConnectionSession(
                    input: handle,
                    output: handle,
                    transport: .unixSocket,
                    expectedTokenProvider: { MCPServer.shared.currentToken() }
                )
                session.run()
            }
        }
    }
}

private enum MCPTransport {
    case stdio
    case unixSocket
}

private final class MCPConnectionSession {
    private let input: FileHandle
    private let output: FileHandle
    private let transport: MCPTransport
    private let expectedTokenProvider: () -> String?
    private var isAuthenticated: Bool
    private var destructiveOperationDates: [Date] = []
    private var operationDatesByTool: [String: [Date]] = [:]

    init(
        input: FileHandle,
        output: FileHandle,
        transport: MCPTransport,
        expectedTokenProvider: @escaping () -> String?
    ) {
        self.input = input
        self.output = output
        self.transport = transport
        self.expectedTokenProvider = expectedTokenProvider
        isAuthenticated = transport == .stdio
    }

    func run() {
        while let lineData = readLineData() {
            guard let line = String(data: lineData, encoding: .utf8) else {
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if handleHeaderLine(trimmed) {
                continue
            }

            handleJSONLine(Data(trimmed.utf8))
        }
    }

    private func readLineData() -> Data? {
        var data = Data()
        while true {
            let byte = input.readData(ofLength: 1)
            if byte.isEmpty {
                return data.isEmpty ? nil : data
            }

            if byte[byte.startIndex] == 10 {
                return data
            }

            data.append(byte)
        }
    }

    private func handleHeaderLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        guard lowercased.hasPrefix("x-auth:") else {
            return false
        }

        let token = String(line.dropFirst("X-Auth:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        isAuthenticated = tokenMatches(token)
        return true
    }

    private func handleJSONLine(_ data: Data) {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String else {
                write(error: MCPError.invalidRequest, id: nil)
                return
            }

            let id = request["id"]
            let params = request["params"] as? [String: Any] ?? [:]

            if method.hasPrefix("notifications/") {
                return
            }

            let result = try handle(method: method, params: params)
            if id != nil {
                write(result: result, id: id)
            }
        } catch let error as MCPError {
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"]
            write(error: error, id: id ?? nil)
        } catch {
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"]
            write(error: .internalError(error.localizedDescription), id: id ?? nil)
        }
    }

    private func handle(method: String, params: [String: Any]) throws -> Any {
        if method == "initialize" {
            try authenticateIfNeeded(params: params)
            return [
                "protocolVersion": "2024-11-05",
                "serverInfo": [
                    "name": "macos-stats-widget",
                    "version": "0.9.0"
                ],
                "capabilities": [
                    "tools": [:]
                ]
            ]
        }

        guard isAuthenticated else {
            throw MCPError.unauthorized
        }

        switch method {
        case "tools/list":
            return ["tools": MCPToolCatalog.tools]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("Missing tool name.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            try rateLimit(toolName: name)
            let toolResult = try MCPToolDispatcher.perform(name: name, arguments: arguments)
            return [
                "content": [
                    [
                        "type": "text",
                        "text": MCPJSON.stringify(toolResult)
                    ]
                ],
                "isError": false
            ]
        default:
            guard MCPToolCatalog.toolNames.contains(method) else {
                throw MCPError.methodNotFound(method)
            }
            try rateLimit(toolName: method)
            return try MCPToolDispatcher.perform(name: method, arguments: params)
        }
    }

    private func authenticateIfNeeded(params: [String: Any]) throws {
        guard transport == .unixSocket else {
            isAuthenticated = true
            return
        }

        if isAuthenticated {
            return
        }

        let token = (params["token"] as? String)
            ?? ((params["headers"] as? [String: Any])?["X-Auth"] as? String)
            ?? ((params["headers"] as? [String: Any])?["x-auth"] as? String)

        guard let token, tokenMatches(token) else {
            throw MCPError.unauthorized
        }

        isAuthenticated = true
    }

    private func tokenMatches(_ token: String) -> Bool {
        guard let expectedToken = expectedTokenProvider(), !expectedToken.isEmpty else {
            return false
        }

        return token == expectedToken
    }

    private func rateLimit(toolName: String) throws {
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)

        var toolDates = operationDatesByTool[toolName, default: []].filter { $0 > oneMinuteAgo }
        guard toolDates.count < 60 else {
            throw MCPError.rateLimited("Too many \(toolName) calls in the last minute.")
        }
        toolDates.append(now)
        operationDatesByTool[toolName] = toolDates

        if MCPToolCatalog.destructiveToolNames.contains(toolName) {
            destructiveOperationDates = destructiveOperationDates.filter { $0 > oneMinuteAgo }
            guard destructiveOperationDates.count < 10 else {
                throw MCPError.rateLimited("Too many destructive MCP operations in the last minute.")
            }
            destructiveOperationDates.append(now)
        }
    }

    private func write(result: Any, id: Any?) {
        writeJSONObject([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ])
    }

    private func write(error: MCPError, id: Any?) {
        writeJSONObject([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": error.code,
                "message": error.message
            ]
        ])
    }

    private func writeJSONObject(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }

        var line = data
        line.append(10)
        try? output.write(contentsOf: line)
    }
}

private enum MCPError: Error {
    case invalidRequest
    case invalidParams(String)
    case methodNotFound(String)
    case toolNotFound(String)
    case unauthorized
    case notFound(String)
    case validation(String)
    case rateLimited(String)
    case internalError(String)

    var code: Int {
        switch self {
        case .invalidRequest:
            return -32600
        case .methodNotFound, .toolNotFound:
            return -32601
        case .invalidParams, .validation:
            return -32602
        case .unauthorized:
            return -32001
        case .notFound:
            return -32004
        case .rateLimited:
            return -32029
        case .internalError:
            return -32603
        }
    }

    var message: String {
        switch self {
        case .invalidRequest:
            return "Invalid JSON-RPC request."
        case .invalidParams(let message),
             .validation(let message),
             .rateLimited(let message),
             .internalError(let message):
            return message
        case .methodNotFound(let method):
            return "Method not found: \(method)."
        case .toolNotFound(let tool):
            return "Tool not found: \(tool)."
        case .unauthorized:
            return "Unauthorized MCP socket session. Send the Keychain-backed token in initialize params or an X-Auth header line."
        case .notFound(let message):
            return message
        }
    }
}

private enum MCPToolCatalog {
    static let destructiveToolNames: Set<String> = [
        "delete_tracker",
        "update_widget_configuration",
        "import_selector_pack"
    ]

    static let toolNames = Set(tools.compactMap { $0["name"] as? String })

    static let tools: [[String: Any]] = [
        tool("list_trackers", "Return all trackers with current values, status, and last-updated metadata.", [:]),
        tool("get_tracker", "Return one tracker with current value, sparkline, and full configuration.", [
            "id": stringSchema("Tracker UUID")
        ], required: ["id"]),
        tool("add_tracker", "Add a tracker. Selector is required unless the caller uses identify_element first.", [
            "name": stringSchema("Tracker name"),
            "url": stringSchema("HTTPS URL, or http://localhost for testing"),
            "renderMode": enumSchema(["text", "snapshot"]),
            "selector": stringSchema("CSS selector"),
            "label": stringSchema("Optional widget label"),
            "icon": stringSchema("SF Symbol name"),
            "refreshIntervalSec": intSchema("Refresh interval in seconds"),
            "hideElements": arraySchema(stringSchema("CSS selector to hide before snapshots"))
        ], required: ["name", "url", "selector"]),
        tool("update_tracker", "Modify tracker fields such as name, URL, label, icon, refresh interval, mode, or selector.", [
            "id": stringSchema("Tracker UUID")
        ], required: ["id"]),
        tool("delete_tracker", "Delete a tracker and unlink it from widget configurations.", [
            "id": stringSchema("Tracker UUID")
        ], required: ["id"]),
        tool("update_selector", "Apply a self-heal selector replacement from an external MCP agent.", [
            "id": stringSchema("Tracker UUID"),
            "newSelector": stringSchema("Replacement CSS selector")
        ], required: ["id", "newSelector"]),
        tool("trigger_scrape", "Force-refresh one tracker now and return the resulting reading.", [
            "id": stringSchema("Tracker UUID")
        ], required: ["id"]),
        tool("identify_element", "Open the visible app browser and wait for the user to confirm an element.", [
            "url": stringSchema("HTTPS URL, or http://localhost for testing")
        ], required: ["url"]),
        tool("list_widget_configurations", "Return all widget compositions.", [:]),
        tool("update_widget_configuration", "Create or update a widget composition.", [
            "id": stringSchema("Widget configuration UUID; optional for create"),
            "name": stringSchema("Configuration name"),
            "templateID": enumSchema(WidgetTemplate.allCases.map(\.rawValue)),
            "size": enumSchema(WidgetConfigurationSize.allCases.map(\.rawValue)),
            "layout": enumSchema(WidgetConfigurationLayout.allCases.map(\.rawValue)),
            "trackerIDs": arraySchema(stringSchema("Tracker UUID"))
        ]),
        tool("export_selector_pack", "Serialize one tracker as selector pack JSON.", [
            "trackerId": stringSchema("Tracker UUID")
        ], required: ["trackerId"]),
        tool("import_selector_pack", "Add a tracker from selector pack JSON. Scripts are rejected.", [
            "json": [
                "description": "Selector pack object or JSON string",
                "oneOf": [
                    ["type": "object"],
                    ["type": "string"]
                ]
            ]
        ], required: ["json"]),
        tool("attach_webhook", "Set or clear the generic notification webhook.", [
            "url": [
                "type": ["string", "null"],
                "description": "Webhook URL, or null to clear."
            ]
        ]),
        tool("get_heal_history", "Return selector replacement and fallback audit history for a tracker.", [
            "id": stringSchema("Tracker UUID")
        ], required: ["id"])
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": true
            ]
        ]
    }

    private static func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func intSchema(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func enumSchema(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }

    private static func arraySchema(_ itemSchema: [String: Any]) -> [String: Any] {
        ["type": "array", "items": itemSchema]
    }
}

private enum MCPToolDispatcher {
    static func perform(name: String, arguments: [String: Any]) throws -> Any {
        MCPInvocationLogger.logTool(name, arguments: arguments)

        switch name {
        case "list_trackers":
            return listTrackers()
        case "get_tracker":
            return try getTracker(arguments)
        case "add_tracker":
            return try addTracker(arguments)
        case "update_tracker":
            return try updateTracker(arguments)
        case "delete_tracker":
            return try deleteTracker(arguments)
        case "update_selector":
            return try updateSelector(arguments)
        case "trigger_scrape":
            return try triggerScrape(arguments)
        case "identify_element":
            return try identifyElement(arguments)
        case "list_widget_configurations":
            return listWidgetConfigurations()
        case "update_widget_configuration":
            return try updateWidgetConfiguration(arguments)
        case "export_selector_pack":
            return try exportSelectorPack(arguments)
        case "import_selector_pack":
            return try importSelectorPack(arguments)
        case "attach_webhook":
            return try attachWebhook(arguments)
        case "get_heal_history":
            return try getHealHistory(arguments)
        default:
            throw MCPError.toolNotFound(name)
        }
    }

    private static func listTrackers() -> Any {
        let configuration = AppGroupStore.loadSharedConfiguration()
        return configuration.trackers.map { trackerPayload($0, includeHistory: false) }
    }

    private static func getTracker(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        guard let tracker = configuration.trackers.first(where: { $0.id == id }) else {
            throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
        }
        return trackerPayload(tracker, includeHistory: true)
    }

    private static func addTracker(_ arguments: [String: Any]) throws -> Any {
        let url = try urlArgument("url", arguments)
        let name = try stringArgument("name", arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        let selector = try stringArgument("selector", arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MCPError.validation("Tracker name cannot be empty.")
        }
        guard !selector.isEmpty else {
            throw MCPError.validation("Selector is required. Use identify_element when the user needs to pick it.")
        }

        let renderMode = renderModeArgument(arguments["renderMode"]) ?? .text
        let tracker = Tracker(
            name: name,
            url: url.absoluteString,
            renderMode: renderMode,
            selector: selector,
            refreshIntervalSec: intArgument("refreshIntervalSec", arguments),
            label: arguments["label"] as? String,
            icon: (arguments["icon"] as? String)?.nilIfEmpty ?? Tracker.defaultIcon,
            hideElements: stringArrayArgument("hideElements", arguments) ?? []
        )

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers.append(tracker)
        }
        notifyConfigurationChanged()
        return ["id": tracker.id.uuidString, "tracker": trackerPayload(tracker, includeHistory: true)]
    }

    private static func updateTracker(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        var updatedTracker: Tracker?

        try AppGroupStore.mutateSharedConfiguration { configuration in
            guard let index = configuration.trackers.firstIndex(where: { $0.id == id }) else {
                throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
            }

            var tracker = configuration.trackers[index]
            if let value = arguments["name"] as? String {
                tracker.name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if arguments.keys.contains("url") {
                tracker.url = try urlArgument("url", arguments).absoluteString
            }
            if let value = arguments["label"] as? String {
                tracker.label = value.nilIfEmpty
            }
            if let value = arguments["icon"] as? String {
                tracker.icon = value.nilIfEmpty ?? Tracker.defaultIcon
            }
            if let value = arguments["accentColorHex"] as? String {
                tracker.accentColorHex = value
            }
            if let value = intArgument("refreshIntervalSec", arguments) {
                tracker.refreshIntervalSec = max(1, value)
            }
            if let mode = renderModeArgument(arguments["renderMode"]) {
                tracker.renderMode = mode
            }
            if let value = arguments["selector"] as? String {
                tracker.selector = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let hideElements = stringArrayArgument("hideElements", arguments) {
                tracker.hideElements = hideElements
            }

            configuration.trackers[index] = tracker
            updatedTracker = tracker
        }

        notifyConfigurationChanged()
        return trackerPayload(try require(updatedTracker, "Updated tracker was not produced."), includeHistory: true)
    }

    private static func deleteTracker(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)

        try AppGroupStore.mutateSharedConfiguration { configuration in
            guard configuration.trackers.contains(where: { $0.id == id }) else {
                throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
            }
            configuration.trackers.removeAll { $0.id == id }
            configuration.widgetConfigurations = configuration.widgetConfigurations.map { widgetConfiguration in
                var updated = widgetConfiguration
                updated.trackerIDs.removeAll { $0 == id }
                return updated
            }
        }

        notifyConfigurationChanged()
        return ["ok": true]
    }

    private static func updateSelector(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        let selector = try stringArgument("newSelector", arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else {
            throw MCPError.validation("newSelector cannot be empty.")
        }

        let configuration = AppGroupStore.loadSharedConfiguration()
        guard configuration.preferences.selfHeal.externalAgentHealEnabled else {
            throw MCPError.validation("External agent selector updates are disabled in Preferences.")
        }

        var updatedTracker: Tracker?
        var beforeSelector: String?
        try AppGroupStore.mutateSharedConfiguration { configuration in
            guard let index = configuration.trackers.firstIndex(where: { $0.id == id }) else {
                throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
            }
            var tracker = configuration.trackers[index]
            beforeSelector = tracker.selector
            tracker.selectorHistory.append(SelectorHistoryEntry(selector: tracker.selector))
            tracker.selector = selector
            tracker.lastHealedAt = Date()
            configuration.trackers[index] = tracker
            updatedTracker = tracker
        }

        AuditLog.record(
            trackerID: id,
            beforeSelector: beforeSelector,
            afterSelector: selector,
            outcome: "mcp_selector_updated",
            source: "mcp"
        )
        notifyConfigurationChanged()
        return trackerPayload(try require(updatedTracker, "Updated tracker was not produced."), includeHistory: true)
    }

    private static func triggerScrape(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        guard let tracker = configuration.trackers.first(where: { $0.id == id }) else {
            throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
        }

        let result = blockingScrape(tracker)
        let reading: TrackerReading
        switch result {
        case .success(let newReading):
            try AppGroupStore.record(reading: newReading, for: tracker)
            reading = newReading
        case .failure(let error):
            reading = try AppGroupStore.recordFailure(message: error.localizedDescription, for: tracker)
        }

        return readingPayload(reading, includeHistory: true)
    }

    private static func identifyElement(_ arguments: [String: Any]) throws -> Any {
        let url = try urlArgument("url", arguments)
        let tracker = Tracker(
            name: "Pending \(url.host ?? "Tracker")",
            url: url.absoluteString,
            renderMode: .text,
            selector: ""
        )

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers.append(tracker)
        }

        notifyConfigurationChanged()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .mcpIdentifyElementRequested,
                object: nil,
                userInfo: [
                    "trackerID": tracker.id.uuidString,
                    "url": url.absoluteString
                ]
            )
        }

        return [
            "trackerId": tracker.id.uuidString,
            "status": "awaiting_user"
        ]
    }

    private static func listWidgetConfigurations() -> Any {
        AppGroupStore.loadSharedConfiguration().widgetConfigurations.map(widgetConfigurationPayload)
    }

    private static func updateWidgetConfiguration(_ arguments: [String: Any]) throws -> Any {
        let id = (arguments["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        var updatedConfiguration: WidgetConfiguration?

        try AppGroupStore.mutateSharedConfiguration { configuration in
            let existingIndex = configuration.widgetConfigurations.firstIndex(where: { $0.id == id })
            let template = widgetTemplateArgument(arguments["templateID"])
                ?? existingIndex.map { configuration.widgetConfigurations[$0].templateID }
                ?? .singleBigNumber
            let size = widgetSizeArgument(arguments["size"])
                ?? existingIndex.map { configuration.widgetConfigurations[$0].size }
                ?? template.size
            let layout = widgetLayoutArgument(arguments["layout"])
                ?? existingIndex.map { configuration.widgetConfigurations[$0].layout }
                ?? template.defaultLayout
            let trackerIDs = uuidArrayArgument("trackerIDs", arguments)
                ?? existingIndex.map { configuration.widgetConfigurations[$0].trackerIDs }
                ?? []
            let name = (arguments["name"] as? String)
                ?? existingIndex.map { configuration.widgetConfigurations[$0].name }
                ?? "\(template.displayName) Widget"

            var widgetConfiguration = existingIndex.map { configuration.widgetConfigurations[$0] }
                ?? WidgetConfiguration(name: name, templateID: template)
            widgetConfiguration.id = id
            widgetConfiguration.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            widgetConfiguration.templateID = template
            widgetConfiguration.size = size
            widgetConfiguration.layout = layout
            widgetConfiguration.trackerIDs = trackerIDs

            if let showSparklines = arguments["showSparklines"] as? Bool {
                widgetConfiguration.showSparklines = showSparklines
            }
            if let showLabels = arguments["showLabels"] as? Bool {
                widgetConfiguration.showLabels = showLabels
            }

            if let existingIndex {
                configuration.widgetConfigurations[existingIndex] = widgetConfiguration
            } else {
                configuration.widgetConfigurations.append(widgetConfiguration)
            }
            updatedConfiguration = widgetConfiguration
        }

        notifyConfigurationChanged()
        return widgetConfigurationPayload(try require(updatedConfiguration, "Updated widget configuration was not produced."))
    }

    private static func exportSelectorPack(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("trackerId", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        guard let tracker = configuration.trackers.first(where: { $0.id == id }) else {
            throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
        }

        return selectorPackPayload(for: tracker)
    }

    private static func importSelectorPack(_ arguments: [String: Any]) throws -> Any {
        let pack = try selectorPackArgument(arguments["json"])
        let url = try validatedURL(from: try require(pack["url"] as? String, "Selector pack URL is required."))
        let name = (pack["name"] as? String)?.nilIfEmpty ?? (pack["label"] as? String)?.nilIfEmpty ?? "Imported Tracker"
        let mode = renderModeArgument(pack["mode"]) ?? .text
        let selector = try require(pack["selector"] as? String, "Selector pack selector is required.")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else {
            throw MCPError.validation("Selector pack selector cannot be empty.")
        }

        let tracker = Tracker(
            name: name,
            url: url.absoluteString,
            renderMode: mode,
            selector: selector,
            elementBoundingBox: elementBoundingBox(from: pack["cropRegion"]),
            label: pack["label"] as? String,
            icon: (pack["icon"] as? String)?.nilIfEmpty ?? Tracker.defaultIcon,
            hideElements: stringArray(from: pack["hideElements"]) ?? []
        )

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers.append(tracker)
        }
        notifyConfigurationChanged()
        return ["trackerId": tracker.id.uuidString]
    }

    private static func attachWebhook(_ arguments: [String: Any]) throws -> Any {
        try AppGroupStore.mutateSharedConfiguration { configuration in
            if arguments["url"] is NSNull {
                configuration.preferences.notificationChannels.webhook = nil
            } else {
                configuration.preferences.notificationChannels.webhook = (arguments["url"] as? String)?.nilIfEmpty
            }
        }
        notifyConfigurationChanged()
        return ["ok": true]
    }

    private static func getHealHistory(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        return AuditLog.entries(for: id).map { entry in
            [
                "id": entry.id.uuidString,
                "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
                "trackerID": entry.trackerID.uuidString,
                "beforeSelector": entry.beforeSelector as Any? ?? NSNull(),
                "afterSelector": entry.afterSelector as Any? ?? NSNull(),
                "outcome": entry.outcome,
                "source": entry.source
            ]
        }
    }

    private static func blockingScrape(_ tracker: Tracker) -> Result<TrackerReading, Error> {
        var result: Result<TrackerReading, Error>?
        WKWebViewScraper.scrape(tracker: tracker) { scrapeResult in
            result = scrapeResult
        }

        if Thread.isMainThread {
            while result == nil {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        } else {
            while result == nil {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        return result ?? .failure(MCPError.internalError("Scrape finished without a result."))
    }

    private static func trackerPayload(_ tracker: Tracker, includeHistory: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "id": tracker.id.uuidString,
            "name": tracker.name,
            "url": tracker.url,
            "browserProfile": tracker.browserProfile,
            "renderMode": tracker.renderMode.rawValue,
            "selector": tracker.selector,
            "refreshIntervalSec": tracker.refreshIntervalSec,
            "label": tracker.label as Any? ?? NSNull(),
            "icon": tracker.icon,
            "accentColorHex": tracker.accentColorHex,
            "hideElements": tracker.hideElements,
            "lastHealedAt": tracker.lastHealedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
            "selectorHistory": tracker.selectorHistory.map { entry in
                [
                    "selector": entry.selector,
                    "replacedAt": ISO8601DateFormatter().string(from: entry.replacedAt)
                ]
            },
            "reading": AppGroupStore.reading(for: tracker.id).map { readingPayload($0, includeHistory: includeHistory) } as Any? ?? NSNull()
        ]

        if includeHistory {
            payload["history"] = tracker.historyPayload
            payload["valueParser"] = tracker.valueParserPayload
        }

        if let box = tracker.elementBoundingBox {
            payload["elementBoundingBox"] = boundingBoxPayload(box)
        } else {
            payload["elementBoundingBox"] = NSNull()
        }

        return payload
    }

    private static func readingPayload(_ reading: TrackerReading, includeHistory: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "currentValue": reading.currentValue as Any? ?? NSNull(),
            "currentNumeric": reading.currentNumeric as Any? ?? NSNull(),
            "snapshotPath": reading.snapshotPath as Any? ?? NSNull(),
            "snapshotCacheKey": reading.snapshotCacheKey as Any? ?? NSNull(),
            "snapshotCapturedAt": reading.snapshotCapturedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
            "lastUpdatedAt": reading.lastUpdatedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
            "status": reading.status.rawValue,
            "lastError": reading.lastError as Any? ?? NSNull(),
            "consecutiveFailureCount": reading.consecutiveFailureCount as Any? ?? NSNull()
        ]
        if includeHistory {
            payload["sparkline"] = reading.sparkline
        }
        return payload
    }

    private static func widgetConfigurationPayload(_ configuration: WidgetConfiguration) -> [String: Any] {
        [
            "id": configuration.id.uuidString,
            "name": configuration.name,
            "templateID": configuration.templateID.rawValue,
            "size": configuration.size.rawValue,
            "layout": configuration.layout.rawValue,
            "trackerIDs": configuration.trackerIDs.map(\.uuidString),
            "showSparklines": configuration.showSparklines,
            "showLabels": configuration.showLabels
        ]
    }

    private static func selectorPackPayload(for tracker: Tracker) -> [String: Any] {
        [
            "schemaVersion": 1,
            "name": tracker.name,
            "url": tracker.url,
            "mode": tracker.renderMode.rawValue,
            "selector": tracker.selector,
            "cropRegion": tracker.elementBoundingBox.map(boundingBoxPayload) as Any? ?? NSNull(),
            "label": tracker.label as Any? ?? NSNull(),
            "icon": tracker.icon,
            "hideElements": tracker.hideElements
        ]
    }

    private static func boundingBoxPayload(_ box: ElementBoundingBox) -> [String: Any] {
        [
            "x": box.x,
            "y": box.y,
            "width": box.width,
            "height": box.height,
            "viewportWidth": box.viewportWidth,
            "viewportHeight": box.viewportHeight,
            "devicePixelRatio": box.devicePixelRatio
        ]
    }

    private static func selectorPackArgument(_ value: Any?) throws -> [String: Any] {
        let pack: [String: Any]
        if let dictionary = value as? [String: Any] {
            pack = dictionary
        } else if let string = value as? String,
                  let data = string.data(using: .utf8),
                  let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pack = dictionary
        } else {
            throw MCPError.invalidParams("json must be a selector pack object or JSON string.")
        }

        guard (pack["schemaVersion"] as? Int) == 1 else {
            throw MCPError.validation("Unsupported selector pack schemaVersion.")
        }

        let bannedKeys = ["script", "scripts", "javascript", "userScript", "userScripts"]
        let lowercasedKeys = Set(pack.keys.map { $0.lowercased() })
        guard bannedKeys.allSatisfy({ !lowercasedKeys.contains($0.lowercased()) }) else {
            throw MCPError.validation("Selector packs cannot contain script-like fields.")
        }

        return pack
    }

    private static func elementBoundingBox(from value: Any?) -> ElementBoundingBox? {
        guard let dictionary = value as? [String: Any],
              let x = doubleValue(dictionary["x"]),
              let y = doubleValue(dictionary["y"]),
              let width = doubleValue(dictionary["width"]),
              let height = doubleValue(dictionary["height"]) else {
            return nil
        }

        return ElementBoundingBox(
            x: x,
            y: y,
            width: width,
            height: height,
            viewportWidth: doubleValue(dictionary["viewportWidth"]) ?? 0,
            viewportHeight: doubleValue(dictionary["viewportHeight"]) ?? 0,
            devicePixelRatio: doubleValue(dictionary["devicePixelRatio"]) ?? 1
        )
    }

    private static func urlArgument(_ key: String, _ arguments: [String: Any]) throws -> URL {
        try validatedURL(from: try stringArgument(key, arguments))
    }

    private static func validatedURL(from string: String) throws -> URL {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw MCPError.validation("URL is invalid.")
        }

        if scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")) {
            return url
        }

        throw MCPError.validation("Scrape URLs must be https://, or http://localhost for testing.")
    }

    private static func stringArgument(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String else {
            throw MCPError.invalidParams("Missing string argument: \(key).")
        }
        return value
    }

    private static func uuidArgument(_ key: String, _ arguments: [String: Any]) throws -> UUID {
        guard let value = arguments[key] as? String, let id = UUID(uuidString: value) else {
            throw MCPError.invalidParams("Missing or invalid UUID argument: \(key).")
        }
        return id
    }

    private static func uuidArrayArgument(_ key: String, _ arguments: [String: Any]) -> [UUID]? {
        guard let values = arguments[key] as? [String] else {
            return nil
        }
        return values.compactMap(UUID.init(uuidString:))
    }

    private static func intArgument(_ key: String, _ arguments: [String: Any]) -> Int? {
        if let value = arguments[key] as? Int {
            return value
        }
        if let value = arguments[key] as? NSNumber {
            return value.intValue
        }
        if let value = arguments[key] as? String {
            return Int(value)
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private static func renderModeArgument(_ value: Any?) -> RenderMode? {
        (value as? String).flatMap(RenderMode.init(rawValue:))
    }

    private static func widgetTemplateArgument(_ value: Any?) -> WidgetTemplate? {
        (value as? String).flatMap(WidgetTemplate.init(rawValue:))
    }

    private static func widgetSizeArgument(_ value: Any?) -> WidgetConfigurationSize? {
        (value as? String).flatMap(WidgetConfigurationSize.init(rawValue:))
    }

    private static func widgetLayoutArgument(_ value: Any?) -> WidgetConfigurationLayout? {
        (value as? String).flatMap(WidgetConfigurationLayout.init(rawValue:))
    }

    private static func stringArrayArgument(_ key: String, _ arguments: [String: Any]) -> [String]? {
        stringArray(from: arguments[key])
    }

    private static func stringArray(from value: Any?) -> [String]? {
        value as? [String]
    }

    private static func notifyConfigurationChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw MCPError.validation(message)
        }
        return value
    }
}

private enum MCPInvocationLogger {
    static func logTool(_ toolName: String, arguments: [String: Any]) {
        let fingerprint = arguments.keys.sorted().joined(separator: ",")
        write("tool=\(toolName) caller=local args=[\(fingerprint)]")
    }

    static func logSystem(_ event: String, detail: String) {
        write("event=\(event) detail=\(detail)")
    }

    private static func write(_ line: String) {
        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/macOS Stats Widget", isDirectory: true)
        let url = directory.appendingPathComponent("mcp.log", isDirectory: false)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let payload = "\(timestamp) \(line)\n"

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(payload.utf8))
                try handle.close()
            } else {
                try Data(payload.utf8).write(to: url, options: .atomic)
            }
        } catch {
            // Logging must not affect MCP tool execution.
        }
    }
}

private enum MCPJSON {
    static func stringify(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

private extension Tracker {
    var historyPayload: [String: Any] {
        [
            "retentionPolicy": history.retentionPolicy.rawValue,
            "retentionValue": history.retentionValue,
            "displayWindow": history.displayWindow
        ]
    }

    var valueParserPayload: [String: Any] {
        [
            "type": valueParser.type.rawValue,
            "stripChars": valueParser.stripChars
        ]
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
