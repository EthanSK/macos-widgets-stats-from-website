//
//  MCPClient.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Minimal local client for power-user CLI calls to the app socket.
//

import Darwin
import Foundation

final class MCPClient {
    private let socketURL: URL
    private let token: String?

    init(socketURL: URL = AppGroupPaths.mcpSocketURL(), token: String? = nil) {
        self.socketURL = socketURL
        self.token = token
    }

    func call(toolName: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.socketCreateFailed(errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = socketURL.path
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            close(fd)
            throw ClientError.socketPathTooLong
        }

        _ = path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    strncpy(destination, pointer, maxPathLength - 1)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            throw ClientError.socketConnectFailed(errno)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if let token {
            try handle.write(contentsOf: Data("X-Auth: \(token)\n".utf8))
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": toolName,
                "arguments": arguments
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        try handle.write(contentsOf: data + Data("\n".utf8))

        let response = readLine(from: handle)
        guard let response,
              let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw ClientError.invalidResponse
        }

        return object
    }

    private func readLine(from handle: FileHandle) -> Data? {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                return data.isEmpty ? nil : data
            }
            if byte[byte.startIndex] == 10 {
                return data
            }
            data.append(byte)
        }
    }

    enum ClientError: LocalizedError {
        case socketCreateFailed(Int32)
        case socketConnectFailed(Int32)
        case socketPathTooLong
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .socketCreateFailed(let code):
                return "Could not create MCP socket: \(code)."
            case .socketConnectFailed(let code):
                return "Could not connect to MCP socket: \(code)."
            case .socketPathTooLong:
                return "MCP socket path is too long."
            case .invalidResponse:
                return "MCP server response was not valid JSON."
            }
        }
    }
}
