//
//  ChromeCDPClient.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Minimal CDP JSON-RPC client. Intentionally uses Runtime.evaluate directly
//  and never sends Runtime.enable, matching the Google-login-safe control style
//  Ethan asked for.
//

import Foundation

enum ChromeCDPClientError: LocalizedError {
    case encodingFailed
    case disconnected
    case invalidMessage
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the CDP command."
        case .disconnected:
            return "The CDP websocket disconnected."
        case .invalidMessage:
            return "The CDP websocket returned an unreadable message."
        case .protocolError(let message):
            return message
        }
    }
}

final class ChromeCDPClient {
    private let task: URLSessionWebSocketTask
    private let queue = DispatchQueue(label: "ChromeCDPClient")
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var isClosed = false

    init(webSocketURL: URL) {
        task = URLSession.shared.webSocketTask(with: webSocketURL)
    }

    func connect() {
        task.resume()
        receiveLoop()
    }

    func prepareOpenClawStylePage(completion: @escaping () -> Void) {
        // Match the useful OpenClaw/CDP setup domains while deliberately
        // leaving Runtime.enable OFF. Runtime.evaluate below is still allowed
        // and is all selector extraction needs.
        enableDomains(["Page.enable", "Network.enable", "DOM.enable", "Accessibility.enable"], completion: completion)
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.isClosed = true
            self.task.cancel(with: .goingAway, reason: nil)
            self.failPending(ChromeCDPClientError.disconnected)
        }
    }

    func evaluate(
        _ expression: String,
        returnByValue: Bool = true,
        completion: @escaping (Result<Any?, Error>) -> Void
    ) {
        // Deliberately do NOT call Runtime.enable. Runtime.evaluate is enough
        // for selector extraction and avoids enabling the full Runtime domain
        // during Google/OAuth pages.
        send(
            method: "Runtime.evaluate",
            params: [
                "expression": expression,
                "returnByValue": returnByValue,
                "awaitPromise": false,
                "userGesture": false
            ]
        ) { result in
            switch result {
            case .success(let response):
                do {
                    completion(.success(try Self.runtimeValue(from: response)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func captureScreenshot(
        clip: [String: Any]? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var params: [String: Any] = [
            "format": "png",
            "fromSurface": true,
            "captureBeyondViewport": true
        ]
        if let clip {
            params["clip"] = clip
        }

        send(method: "Page.captureScreenshot", params: params) { result in
            switch result {
            case .success(let response):
                guard let outer = response["result"] as? [String: Any],
                      let base64 = outer["data"] as? String,
                      let data = Data(base64Encoded: base64) else {
                    completion(.failure(ChromeCDPClientError.invalidMessage))
                    return
                }
                completion(.success(data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func send(
        method: String,
        params: [String: Any]? = nil,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else {
                completion(.failure(ChromeCDPClientError.disconnected))
                return
            }

            let id = self.nextID
            self.nextID += 1
            var payload: [String: Any] = [
                "id": id,
                "method": method
            ]
            if let params {
                payload["params"] = params
            }

            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let string = String(data: data, encoding: .utf8) else {
                completion(.failure(ChromeCDPClientError.encodingFailed))
                return
            }

            self.pending[id] = completion
            self.task.send(.string(string)) { [weak self] error in
                guard let error else { return }
                self?.queue.async {
                    let callback = self?.pending.removeValue(forKey: id)
                    callback?(.failure(error))
                }
            }
        }
    }

    private func enableDomains(_ methods: [String], completion: @escaping () -> Void) {
        guard let method = methods.first else {
            completion()
            return
        }

        send(method: method) { [weak self] _ in
            self?.enableDomains(Array(methods.dropFirst()), completion: completion)
        }
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure(let error):
                self.queue.async {
                    self.isClosed = true
                    self.failPending(error)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let string):
            data = string.data(using: .utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            data = nil
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            return
        }

        queue.async { [weak self] in
            guard let callback = self?.pending.removeValue(forKey: id) else {
                return
            }

            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "CDP command failed."
                callback(.failure(ChromeCDPClientError.protocolError(message)))
                return
            }

            callback(.success(json))
        }
    }

    private func failPending(_ error: Error) {
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
    }

    private static func runtimeValue(from response: [String: Any]) throws -> Any? {
        guard let outer = response["result"] as? [String: Any] else {
            throw ChromeCDPClientError.invalidMessage
        }

        if let exception = outer["exceptionDetails"] as? [String: Any] {
            let text = exception["text"] as? String ?? "Runtime.evaluate threw an exception."
            throw ChromeCDPClientError.protocolError(text)
        }

        guard let result = outer["result"] as? [String: Any] else {
            return nil
        }

        if let unserializable = result["unserializableValue"] as? String {
            return unserializable
        }

        return result["value"]
    }
}
