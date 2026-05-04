//
//  ChromeBrowserProfile.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  OpenClaw-style Chromium/Chrome profile launcher for Google-login-safe CDP scraping.
//

import AppKit
import Foundation

struct ChromeBrowserLaunchConfiguration: Equatable {
    let profileName: String
    let cdpPort: Int
    let cdpURL: URL
    let userDataDirectory: URL
}

struct ChromeBrowserTarget: Equatable {
    let id: String
    let webSocketDebuggerURL: URL
}

enum ChromeBrowserProfileError: LocalizedError {
    case browserNotFound
    case launchFailed(String)
    case cdpNotReachable(Int)
    case targetCreationFailed(String)
    case invalidCDPResponse

    var errorDescription: String? {
        switch self {
        case .browserNotFound:
            return "No Chromium-based browser was found. Install Google Chrome/Chromium or set MACOS_WIDGETS_STATS_CHROME_PATH."
        case .launchFailed(let message):
            return "Could not launch the browser profile: \(message)"
        case .cdpNotReachable(let port):
            return "Chrome DevTools Protocol did not become reachable on port \(port)."
        case .targetCreationFailed(let message):
            return "Could not create a browser tab: \(message)"
        case .invalidCDPResponse:
            return "Chrome DevTools Protocol returned an unreadable response."
        }
    }
}

final class ChromeBrowserProfile {
    static let shared = ChromeBrowserProfile()
    static let defaultProfileName = Tracker.defaultBrowserProfile

    private let defaultCDPPort = 18800
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "ChromeBrowserProfile")
    private var launchedProcess: Process?

    private init() {}

    func configuration(profileName: String = ChromeBrowserProfile.defaultProfileName) -> ChromeBrowserLaunchConfiguration {
        let root = AppGroupPaths.canonicalApplicationSupportURL()
            .appendingPathComponent("Browser", isDirectory: true)
            .appendingPathComponent(safeProfileName(profileName), isDirectory: true)
        return ChromeBrowserLaunchConfiguration(
            profileName: profileName,
            cdpPort: defaultCDPPort,
            cdpURL: URL(string: "http://127.0.0.1:\(defaultCDPPort)")!,
            userDataDirectory: root.appendingPathComponent("user-data", isDirectory: true)
        )
    }

    func openVisibleBrowser(
        url: URL?,
        profileName: String = ChromeBrowserProfile.defaultProfileName,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        ensureLaunched(profileName: profileName, foreground: true) { [weak self] result in
            switch result {
            case .success(let configuration):
                guard let url else {
                    completion?(.success(()))
                    return
                }

                self?.openTab(url: url, configuration: configuration) { tabResult in
                    completion?(tabResult.map { _ in () })
                }
            case .failure(let error):
                completion?(.failure(error))
            }
        }
    }

    func ensureLaunched(
        profileName: String = ChromeBrowserProfile.defaultProfileName,
        foreground: Bool = false,
        completion: @escaping (Result<ChromeBrowserLaunchConfiguration, Error>) -> Void
    ) {
        let configuration = configuration(profileName: profileName)
        if isCDPReachable(configuration: configuration) {
            completion(.success(configuration))
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.fileManager.createDirectory(at: configuration.userDataDirectory, withIntermediateDirectories: true)
                let browser = try self.resolveBrowser()
                try self.launch(browser: browser, configuration: configuration, foreground: foreground)
                self.waitUntilCDPReachable(configuration: configuration, deadline: Date().addingTimeInterval(12), completion: completion)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func openTab(
        url: URL,
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (Result<ChromeBrowserTarget, Error>) -> Void
    ) {
        createTargetRequest(url: url, configuration: configuration, method: "PUT") { [weak self] result in
            switch result {
            case .success:
                completion(result)
            case .failure:
                self?.createTargetRequest(url: url, configuration: configuration, method: "GET", completion: completion)
            }
        }
    }

    func closeTarget(id: String, configuration: ChromeBrowserLaunchConfiguration) {
        guard !id.isEmpty,
              let url = URL(string: "/json/close/\(id)", relativeTo: configuration.cdpURL)?.absoluteURL else {
            return
        }

        URLSession.shared.dataTask(with: url).resume()
    }

    private func buildChromeLaunchArguments(configuration: ChromeBrowserLaunchConfiguration) -> [String] {
        [
            "--remote-debugging-port=\(configuration.cdpPort)",
            "--user-data-dir=\(configuration.userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-features=Translate,MediaRouter",
            "--disable-session-crashed-bubble",
            "--hide-crash-restore-bubble",
            "--password-store=basic",
            "--no-proxy-server"
        ]
    }

    private func launch(browser: ResolvedBrowser, configuration: ChromeBrowserLaunchConfiguration, foreground: Bool) throws {
        let arguments = buildChromeLaunchArguments(configuration: configuration) + ["about:blank"]

        switch browser.kind {
        case .appBundle(let appURL):
            let openConfiguration = NSWorkspace.OpenConfiguration()
            openConfiguration.arguments = arguments
            openConfiguration.activates = foreground
            openConfiguration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: openConfiguration)
        case .executable(let executableURL):
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            launchedProcess = process
        }
    }

    private func waitUntilCDPReachable(
        configuration: ChromeBrowserLaunchConfiguration,
        deadline: Date,
        completion: @escaping (Result<ChromeBrowserLaunchConfiguration, Error>) -> Void
    ) {
        if isCDPReachable(configuration: configuration) {
            DispatchQueue.main.async {
                completion(.success(configuration))
            }
            return
        }

        guard Date() < deadline else {
            DispatchQueue.main.async {
                completion(.failure(ChromeBrowserProfileError.cdpNotReachable(configuration.cdpPort)))
            }
            return
        }

        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitUntilCDPReachable(configuration: configuration, deadline: deadline, completion: completion)
        }
    }

    private func isCDPReachable(configuration: ChromeBrowserLaunchConfiguration) -> Bool {
        guard let url = URL(string: "/json/version", relativeTo: configuration.cdpURL)?.absoluteURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        return (json["Browser"] as? String)?.isEmpty == false || (json["webSocketDebuggerUrl"] as? String)?.isEmpty == false
    }

    private func createTargetRequest(
        url targetURL: URL,
        configuration: ChromeBrowserLaunchConfiguration,
        method: String,
        completion: @escaping (Result<ChromeBrowserTarget, Error>) -> Void
    ) {
        guard let encoded = targetURL.absoluteString.addingPercentEncoding(withAllowedCharacters: Self.cdpQueryAllowedCharacters),
              let requestURL = URL(string: "/json/new?\(encoded)", relativeTo: configuration.cdpURL)?.absoluteURL else {
            completion(.failure(ChromeBrowserProfileError.targetCreationFailed("The URL could not be encoded.")))
            return
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                completion(.failure(ChromeBrowserProfileError.targetCreationFailed("CDP /json/new returned HTTP \(httpResponse.statusCode).")))
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let webSocketString = json["webSocketDebuggerUrl"] as? String,
                  let webSocketURL = URL(string: webSocketString) else {
                completion(.failure(ChromeBrowserProfileError.invalidCDPResponse))
                return
            }

            completion(.success(ChromeBrowserTarget(id: id, webSocketDebuggerURL: webSocketURL)))
        }.resume()
    }

    private func resolveBrowser() throws -> ResolvedBrowser {
        if let override = ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_CHROME_PATH"]?.nilIfEmpty {
            if let browser = ResolvedBrowser(path: override) {
                return browser
            }
            throw ChromeBrowserProfileError.launchFailed("MACOS_WIDGETS_STATS_CHROME_PATH does not point at an app bundle or executable browser.")
        }

        for url in bundledBrowserCandidates() + systemBrowserCandidates() {
            if let browser = ResolvedBrowser(url: url) {
                return browser
            }
        }

        throw ChromeBrowserProfileError.browserNotFound
    }

    private func bundledBrowserCandidates() -> [URL] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        return [
            resources.appendingPathComponent("Browsers/Chromium.app", isDirectory: true),
            resources.appendingPathComponent("Browsers/Google Chrome for Testing.app", isDirectory: true),
            resources.appendingPathComponent("Chromium.app", isDirectory: true)
        ]
    }

    private func systemBrowserCandidates() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Google Chrome for Testing.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Chromium.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Brave Browser.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Microsoft Edge.app", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin/chromium", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/chromium", isDirectory: false),
            URL(fileURLWithPath: "/usr/bin/chromium", isDirectory: false),
            URL(fileURLWithPath: "/usr/bin/google-chrome", isDirectory: false)
        ]
    }

    private func safeProfileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let safe = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return safe.isEmpty ? "openclaw" : safe
    }

    private static let cdpQueryAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return allowed
    }()
}

private struct ResolvedBrowser {
    enum Kind {
        case appBundle(URL)
        case executable(URL)
    }

    let kind: Kind

    init?(path: String) {
        self.init(url: URL(fileURLWithPath: path))
    }

    init?(url: URL) {
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue, url.pathExtension.lowercased() == "app" {
            kind = .appBundle(url)
            return
        }

        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }

        kind = .executable(url)
    }
}

private extension FileHandle {
    static var nullDevice: FileHandle {
        FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.standardError
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
