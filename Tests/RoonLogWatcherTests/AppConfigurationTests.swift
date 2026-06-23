import XCTest
@testable import RoonLogWatcherCore

final class AppConfigurationTests: XCTestCase {
    func testConfigStoreCreatesDefaultFileAndCanSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonLogWatcherTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let store = AppConfigStore(configURL: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.configuration.dashboardPort, 17666)
        XCTAssertTrue([AppLanguage.english, AppLanguage.german].contains(store.configuration.language))
        XCTAssertEqual(store.configuration.logHistoryMaxLines, 5_000)
        XCTAssertEqual(store.configuration.maxLogLineCharacters, 2_000)

        var config = store.configuration
        config.dashboardPort = 17677
        config.language = .german
        config.pollIntervalSeconds = 0.1
        config.logVolumeWindowMinutes = 180
        config.logHistoryMaxLines = 800
        config.maxLogLineCharacters = 300
        try store.save(config)

        let reloaded = AppConfigStore(configURL: url)
        XCTAssertEqual(reloaded.configuration.dashboardPort, 17677)
        XCTAssertEqual(reloaded.configuration.language, .german)
        XCTAssertEqual(reloaded.configuration.pollIntervalSeconds, 0.25)
        XCTAssertEqual(reloaded.configuration.logVolumeWindowMinutes, 180)
        XCTAssertEqual(reloaded.configuration.logHistoryMaxLines, 800)
        XCTAssertEqual(reloaded.configuration.maxLogLineCharacters, 300)
    }

    func testDecodesOldConfigWithoutLanguageField() throws {
        let json = """
        {
          "baseDirectory": "/Volumes/Data",
          "autoDiscoverRoonLogDirectories": true,
          "logDirectories": [],
          "pollIntervalSeconds": 0.75,
          "dashboardPort": 17666,
          "enableDemoModeWhenNoLogs": true,
          "watchExistingLogsFromEnd": true,
          "fileNameIncludes": ["log", "txt"],
          "maxFilesPerDirectory": 50,
          "recentLogMaxLines": 500,
          "alertDedupeSeconds": 45,
          "sendMacNotifications": true,
          "showAllLogLines": true
        }
        """

        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.dashboardPort, 17666)
        XCTAssertTrue([AppLanguage.english, AppLanguage.german].contains(config.language))
        XCTAssertEqual(config.logVolumeWindowMinutes, 60)
        XCTAssertEqual(config.logHistoryMaxLines, 5_000)
        XCTAssertEqual(config.maxLogLineCharacters, 2_000)
    }

    func testNormalizesUnsupportedLogVolumeWindow() throws {
        var config = AppConfiguration.default
        config.logVolumeWindowMinutes = 999

        XCTAssertEqual(config.normalized().logVolumeWindowMinutes, 60)
    }

    func testNormalizesLogRetentionLimits() throws {
        var low = AppConfiguration.default
        low.recentLogMaxLines = 50
        low.logHistoryMaxLines = 25
        low.maxLogLineCharacters = 50

        let normalizedLow = low.normalized()
        XCTAssertEqual(normalizedLow.recentLogMaxLines, 100)
        XCTAssertEqual(normalizedLow.logHistoryMaxLines, 100)
        XCTAssertEqual(normalizedLow.maxLogLineCharacters, 200)

        var high = AppConfiguration.default
        high.recentLogMaxLines = 20_000
        high.logHistoryMaxLines = 100_000
        high.maxLogLineCharacters = 50_000

        let normalizedHigh = high.normalized()
        XCTAssertEqual(normalizedHigh.recentLogMaxLines, 10_000)
        XCTAssertEqual(normalizedHigh.logHistoryMaxLines, 50_000)
        XCTAssertEqual(normalizedHigh.maxLogLineCharacters, 20_000)
    }

    func testNormalizesHealthRules() throws {
        var config = AppConfiguration.default
        config.healthRules.logStaleWarningSeconds = 1
        config.healthRules.logStaleCriticalSeconds = 2
        config.healthRules.raatWarningDisconnects = 10
        config.healthRules.raatCriticalDisconnects = 2
        config.healthRules.diskCriticalFreeMB = 100_000
        config.healthRules.diskWarningFreeMB = 1_000

        let rules = config.normalized().healthRules
        XCTAssertEqual(rules.logStaleWarningSeconds, 15)
        XCTAssertGreaterThan(rules.logStaleCriticalSeconds, rules.logStaleWarningSeconds)
        XCTAssertEqual(rules.raatCriticalDisconnects, rules.raatWarningDisconnects)
        XCTAssertLessThanOrEqual(rules.diskCriticalFreeMB, rules.diskWarningFreeMB)
    }

    func testConfigStoreFallsBackToDefaultsForInvalidJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonLogWatcherBrokenConfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        try "{ this is not json".write(to: url, atomically: true, encoding: .utf8)

        let store = AppConfigStore(configURL: url)

        XCTAssertEqual(store.configuration.dashboardPort, 17666)
        XCTAssertEqual(store.configuration.logVolumeWindowMinutes, 60)
        XCTAssertNotNil(store.lastError)
    }

    func testRuntimeSnapshotKeepsHistoryServerSideWithoutEncodingIt() throws {
        var config = AppConfiguration.default
        config.recentLogMaxLines = 100
        config.logHistoryMaxLines = 120
        config.maxLogLineCharacters = 200
        let store = RuntimeStore(configuration: config)
        let longPayload = String(repeating: "x", count: 260)

        for index in 0..<125 {
            store.ingest(
                file: "/tmp/RoonServer_log.txt",
                line: "06/22 18:00:\(String(format: "%02d", index % 60)) Info: line \(index) \(longPayload)",
                events: [],
                mode: .live
            )
        }

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.recentLogs.count, 100)
        XCTAssertEqual(snapshot.volumeBuckets.count, 60)
        XCTAssertEqual(snapshot.volumeBuckets.reduce(0) { $0 + $1.total }, 120)
        XCTAssertTrue(snapshot.recentLogs.allSatisfy { $0.text.count <= 220 })
        XCTAssertTrue(snapshot.recentLogs.allSatisfy { $0.text.contains("[truncated]") })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(snapshot)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("\"logHistory\""))
        XCTAssertTrue(json.contains("\"volumeBuckets\""))
        XCTAssertLessThan(encoded.count, 90_000)

        let export = store.logExportText()
        let exportLines = export.split(separator: "\n")
        XCTAssertEqual(exportLines.count, 120)
        XCTAssertFalse(export.contains("line 0 "))
        XCTAssertTrue(export.contains("line 124 "))
        XCTAssertTrue(export.contains("[truncated]"))
    }

    func testDashboardConfigAPIReadsAndSavesDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonLogWatcherDashboardAPI-\(UUID().uuidString)", isDirectory: true)
        let configURL = directory.appendingPathComponent("config.json")
        let configStore = AppConfigStore(configURL: configURL)
        let runtimeStore = RuntimeStore(configuration: configStore.configuration)
        let server = DashboardServer(store: runtimeStore, configStore: configStore)
        try server.start(preferredPort: UInt16(24_000 + Int.random(in: 0..<1_000)))
        defer { server.stop() }

        let baseURL = try XCTUnwrap(server.url)
        let getResponse = try await http(URLRequest(url: baseURL.appendingPathComponent("api/config")))
        XCTAssertEqual(getResponse.response.statusCode, 200)

        let decoder = JSONDecoder()
        let document = try decoder.decode(ConfigDocument.self, from: getResponse.data)
        XCTAssertEqual(document.configPath, configURL.path)
        XCTAssertEqual(document.config.dashboardPort, 17666)

        var nextConfig = document.config
        nextConfig.language = .german
        nextConfig.pollIntervalSeconds = 0.05
        nextConfig.logVolumeWindowMinutes = 360
        nextConfig.logHistoryMaxLines = 700
        nextConfig.maxLogLineCharacters = 150

        var request = URLRequest(url: baseURL.appendingPathComponent("api/config"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(nextConfig)

        let postResponse = try await http(request)
        XCTAssertEqual(postResponse.response.statusCode, 200)
        let saved = try decoder.decode(ConfigDocument.self, from: postResponse.data)
        XCTAssertEqual(saved.config.language, .german)
        XCTAssertEqual(saved.config.pollIntervalSeconds, 0.25)
        XCTAssertEqual(saved.config.logVolumeWindowMinutes, 360)
        XCTAssertEqual(saved.config.logHistoryMaxLines, 700)
        XCTAssertEqual(saved.config.maxLogLineCharacters, 200)
        XCTAssertEqual(AppConfigStore(configURL: configURL).configuration.language, .german)
    }

    func testDiscovererUsesManualConfiguredDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonLogWatcherLogs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logFile = root.appendingPathComponent("RoonServer_log.txt")
        try "06/22 17:00:00 Info: test\n".write(to: logFile, atomically: true, encoding: .utf8)

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonLogWatcherConfig-\(UUID().uuidString).json")
        let store = AppConfigStore(configURL: configURL)
        var config = store.configuration
        config.autoDiscoverRoonLogDirectories = false
        config.logDirectories = [root.path]
        try store.save(config)

        let discoverer = RoonLogDiscoverer(configStore: store)
        XCTAssertEqual(discoverer.discoverDirectories(), [root.path])
        XCTAssertEqual(discoverer.discoverLogFiles(), [logFile.path])
    }

    func testDiscovererExcludesRotatedLogsFromLiveTailByDefault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonLogWatcherRotatedLogs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("RoonServer_log.txt")
        let rotated = root.appendingPathComponent("RoonServer_log.06.txt")
        try "06/23 18:00:00 Info: current\n".write(to: current, atomically: true, encoding: .utf8)
        try "06/22 22:46:29 Critical: old archive line\n".write(to: rotated, atomically: true, encoding: .utf8)

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonLogWatcherRotatedConfig-\(UUID().uuidString).json")
        let store = AppConfigStore(configURL: configURL)
        var config = store.configuration
        config.autoDiscoverRoonLogDirectories = false
        config.logDirectories = [root.path]
        try store.save(config)

        let discoverer = RoonLogDiscoverer(configStore: store)

        XCTAssertEqual(discoverer.discoverLogFiles(), [current.path])
        XCTAssertEqual(Set(discoverer.discoverLogFiles(includeRotated: true)), Set([current.path, rotated.path]))
    }

    private func http(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        var lastError: Error?
        for _ in 0..<20 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                return (data, httpResponse)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }
}
