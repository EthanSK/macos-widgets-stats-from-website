import XCTest

final class FirstLaunchEndToEndUITests: XCTestCase {
    private var tempRoot: URL!
    private var containerURL: URL!
    private var webURL: String!
    private var launchedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false

        guard let externalURL = Self.externalSetting(name: "MW_UI_E2E_URL", fallbackFile: "/tmp/mw-ui-e2e-url.txt") else {
            throw XCTSkip("Set MW_UI_E2E_URL or /tmp/mw-ui-e2e-url.txt to a local HTTP fixture URL before running this UI test.")
        }

        let root = Self.defaultSandboxWritableRoot()
        let containerName = Self.safePathComponent(name)
        let container: URL
        if let externalContainer = Self.externalSetting(name: "MW_UI_E2E_CONTAINER", fallbackFile: "/tmp/mw-ui-e2e-container.txt") {
            container = URL(fileURLWithPath: externalContainer, isDirectory: true)
                .appendingPathComponent(containerName, isDirectory: true)
        } else {
            container = root.appendingPathComponent("container", isDirectory: true)
                .appendingPathComponent(containerName, isDirectory: true)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: container.path) {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        }
        Self.clearConfigurationFiles(in: container)
        XCTAssertTrue(Self.waitForHTTP(urlString: externalURL, timeout: 5, expectedSubstring: "987.65"), "fixture HTTP server did not respond with expected value")

        tempRoot = root
        containerURL = container
        webURL = externalURL
    }

    override func tearDownWithError() throws {
        if let launchedApp {
            launchedApp.terminate()
            _ = launchedApp.wait(for: .notRunning, timeout: 5)
        }
        launchedApp = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testFirstLaunchTrackerCreationEndToEnd() throws {
        let app = launchApp()
        enterURLAndContinue(webURL, in: app)

        XCTAssertTrue(app.buttons["Open Page and Identify Element"].waitForExistence(timeout: 5), "capture step did not appear")
        XCTAssertFalse(app.buttons["Save Tracker"].isEnabled, "Save Tracker should be disabled until an element is captured")

        app.buttons["Open Page and Identify Element"].click()
        try identifyVisibleFixtureValue(in: app)
        XCTAssertTrue(app.staticTexts["Element captured — preview"].waitForExistence(timeout: 10), "element preview did not appear")
        XCTAssertTrue(app.buttons["Use Element"].waitForExistence(timeout: 5), "Use Element button missing after capture preview")
        app.buttons["Use Element"].click()

        XCTAssertTrue(app.buttons["Save Tracker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save Tracker"].isEnabled, "Save Tracker should enable after capture")
        app.buttons["Save Tracker"].click()

        XCTAssertTrue(app.staticTexts["Widget configuration"].waitForExistence(timeout: 5), "widget confirmation did not appear")
        app.buttons["Done"].click()

        let trackersFile = containerURL.appendingPathComponent("trackers.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackersFile.path), "trackers.json was not written")
        let data = try Data(contentsOf: trackersFile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let trackers = json?["trackers"] as? [[String: Any]] ?? []
        let widgets = json?["widgetConfigurations"] as? [[String: Any]] ?? []
        XCTAssertEqual(trackers.count, 1)
        XCTAssertEqual(widgets.count, 1)
        XCTAssertEqual(trackers.first?["url"] as? String, webURL)
        let selector = trackers.first?["selector"] as? String ?? ""
        XCTAssertTrue(selector.contains("value"), "captured selector should point at the fixture value element, got \\(selector)")
    }

    func testGoogleSignInFallbackDoesNotStayInEmbeddedBrowser() throws {
        let googleFixtureURL = try googleSignInFixtureURL()
        let app = launchApp(suppressExternalBrowserOpen: true)
        enterURLAndContinue(googleFixtureURL.absoluteString, in: app)

        XCTAssertTrue(app.buttons["Open Page and Identify Element"].waitForExistence(timeout: 5), "capture step did not appear")
        app.buttons["Open Page and Identify Element"].click()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15), "WKWebView did not appear")
        Thread.sleep(forTimeInterval: 1.0)
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.24)).click()

        let fallbackPredicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Google sign-in was opened in your default browser", "Google sign-in was opened in your default browser")
        let fallbackMessage = app.staticTexts.matching(fallbackPredicate).firstMatch
        XCTAssertTrue(fallbackMessage.waitForExistence(timeout: 5), "Google sign-in fallback message did not appear")

        let unsupportedBrowserPredicate = NSPredicate(format: "label CONTAINS[c] %@", "unsupported embedded-browser")
        XCTAssertFalse(app.staticTexts.matching(unsupportedBrowserPredicate).firstMatch.exists, "Google unsupported embedded-browser error appeared in-app")
    }

    private func launchApp(suppressExternalBrowserOpen: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 5)
        app.launchEnvironment["MACOS_WIDGETS_STATS_TEST_CONTAINER"] = containerURL.path
        if suppressExternalBrowserOpen {
            app.launchEnvironment["MACOS_WIDGETS_STATS_SUPPRESS_EXTERNAL_BROWSER_OPEN"] = "1"
        }
        app.launch()
        launchedApp = app
        XCTAssertTrue(app.staticTexts["Welcome to macOS Widgets Stats from Website"].waitForExistence(timeout: 15))
        return app
    }

    private func enterURLAndContinue(_ url: String, in app: XCUIApplication) {
        let urlField = app.textFields.firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "URL field missing")
        urlField.click()
        urlField.typeText(url)
        app.buttons["Continue"].click()
    }

    private func googleSignInFixtureURL() throws -> URL {
        guard let baseURL = URL(string: webURL) else {
            throw XCTSkip("MW_UI_E2E_URL was not a valid URL")
        }

        let fixtureURL = baseURL.appendingPathComponent("google.html")
        XCTAssertTrue(Self.waitForHTTP(urlString: fixtureURL.absoluteString, timeout: 5, expectedSubstring: "Continue with Google"), "Google sign-in fixture did not respond")
        return fixtureURL
    }

    private func identifyVisibleFixtureValue(in app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["Identify Element"].waitForExistence(timeout: 15), "Identify Element button missing")
        app.buttons["Identify Element"].click()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15), "WKWebView did not appear")
        Thread.sleep(forTimeInterval: 1.0)
        // The fixture places the value near the upper-left of the page, below the toolbar.
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.18)).click()
    }

    private static func defaultSandboxWritableRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers/com.ethansk.macos-widgets-stats-from-website/Data/tmp", isDirectory: true)
            .appendingPathComponent("mw-ui-e2e-\(UUID().uuidString)", isDirectory: true)
    }

    private static func clearConfigurationFiles(in container: URL) {
        let fileNames = ["trackers.json", "readings.json", "mcp.sock", ".configuration.lock", ".readings.lock"]
        for fileName in fileNames {
            let url = container.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        let characters = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(characters).replacingOccurrences(of: " ", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func externalSetting(name: String, fallbackFile: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return try? String(contentsOfFile: fallbackFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func waitForHTTP(urlString: String, timeout: TimeInterval, expectedSubstring: String) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let url = URL(string: urlString),
               let data = try? Data(contentsOf: url),
               String(data: data, encoding: .utf8)?.contains(expectedSubstring) == true {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
