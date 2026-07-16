import XCTest
@testable import RoonLogWatcherCore

final class LogParserTests: XCTestCase {
    func testParsesRoonStatsMemoryLine() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/22 17:03:11 Info: [stats] 845 MB Physical 384 MB Managed 461 MB estimated Unmanaged 1280 MB Virtual"
        )

        XCTAssertTrue(events.contains { $0.domain == "memory" && $0.title == "Physical Memory" && $0.valueMB == 845 })
        XCTAssertTrue(events.contains { $0.title == "Managed Memory" && $0.valueMB == 384 })
        XCTAssertTrue(events.contains { $0.title == "Unmanaged Memory" && $0.valueMB == 461 })
    }

    func testMemoryTrendFallsBackToPhysicalMemoryLogMetric() {
        let parser = LogParser()
        let store = RuntimeStore()
        let line = "Info: [stats] 845 MB Physical 384 MB Managed 461 MB estimated Unmanaged 1280 MB Virtual"

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: line,
            events: parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line),
            mode: .live
        )

        let trend = store.snapshot().memoryTrend24h
        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend.first?.metric, "Physical Memory")
        XCTAssertEqual(trend.first?.valueMB, 845)
    }

    func testMemoryTrendKeepsPhysicalLogMetricWhenProcessSamplerAppears() {
        let store = RuntimeStore()
        let now = Date().addingTimeInterval(-10 * 60)

        for index in 0..<6 {
            let time = now.addingTimeInterval(TimeInterval(index * 60))
            store.ingest(
                file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
                line: "memory \(index)",
                events: [memoryEvent(time: time, valueMB: Double(900 + index))],
                mode: .live
            )
        }

        store.updateSystemStatus(LocalSystemStatus(
            sampledAt: Date(),
            host: RoonHostStatus(
                isRoonServerLikely: true,
                reason: "test",
                detectedProcesses: ["RoonServer"],
                detectedLogDirectories: ["/tmp/RoonServer/Logs"],
                checkedAt: Date()
            ),
            processes: [],
            totalCPUPercent: 0,
            totalMemoryMB: 512,
            openFileCount: nil,
            logVolumePath: nil,
            logVolumeFreeMB: nil,
            logVolumeFreeRatio: nil
        ))

        let trend = store.snapshot().memoryTrend24h

        XCTAssertEqual(trend.count, 6)
        XCTAssertTrue(trend.allSatisfy { $0.metric == "Physical Memory" })
        XCTAssertEqual(trend.last?.valueMB, 905)
    }

    func testMemoryTrendBucketsDenseFirstHourWithoutCollapsingToEmptyDay() {
        let store = RuntimeStore()
        let now = Date().addingTimeInterval(-5)
        let firstSample = now.addingTimeInterval(-59 * 60)

        for index in 0..<60 {
            let time = firstSample.addingTimeInterval(TimeInterval(index * 60))
            store.ingest(
                file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
                line: "memory \(index)",
                events: [memoryEvent(time: time, valueMB: Double(1_000 + index))],
                mode: .live
            )
        }

        let trend = store.snapshot().memoryTrend24h

        XCTAssertGreaterThanOrEqual(trend.count, 40)
        XCTAssertLessThanOrEqual(trend.count, 48)
        XCTAssertEqual(trend.last?.metric, "Physical Memory")
        XCTAssertEqual(trend.last?.valueMB, 1_059)
    }

    func testMemoryTrendRetainsMoreThanSixHoursWhenFullStatsLinesArrive() {
        let store = RuntimeStore()
        let now = Date().addingTimeInterval(-5)
        let firstSample = now.addingTimeInterval(-7 * 60 * 60)

        for index in 0...1_680 {
            let time = firstSample.addingTimeInterval(TimeInterval(index * 15))
            store.ingest(
                file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
                line: "stats \(index)",
                events: memoryStatsEvents(time: time, physicalMB: Double(1_000 + index)),
                mode: .live
            )
        }

        let trend = store.snapshot().memoryTrend24h
        let coveredSeconds = trend.last?.time.timeIntervalSince(trend.first?.time ?? Date()) ?? 0

        XCTAssertEqual(trend.count, 48)
        XCTAssertGreaterThan(coveredSeconds, 6.75 * 60 * 60)
        XCTAssertEqual(trend.first?.metric, "Physical Memory")
        XCTAssertEqual(trend.last?.metric, "Physical Memory")
    }

    func testRuntimeStoreCreatesMemoryInsightForLargePhysicalJumpWithContext() {
        let parser = LogParser()
        let store = RuntimeStore()
        let first = Date().addingTimeInterval(-60)
        let context = first.addingTimeInterval(8)
        let second = first.addingTimeInterval(22)
        let source = "/tmp/RoonServer/Logs/RoonServer_log.txt"
        let contextLine = "\(logTimestamp(for: context)) Trace: [metadatasvc] GOT 250 dirty albums, updating metadata cache"
        let firstStats = "\(logTimestamp(for: first)) Info: [stats] 420000 MB Virtual 1000 MB Physical 700 MB Managed 300 MB estimated Unmanaged"
        let secondStats = "\(logTimestamp(for: second)) Info: [stats] 420050 MB Virtual 1260 MB Physical 860 MB Managed 400 MB estimated Unmanaged"

        store.ingest(file: source, line: firstStats, events: parser.parse(file: source, line: firstStats), mode: .live)
        store.ingest(file: source, line: contextLine, events: parser.parse(file: source, line: contextLine), mode: .live)
        store.ingest(file: source, line: secondStats, events: parser.parse(file: source, line: secondStats), mode: .live)

        let insight = store.snapshot().memoryInsights.first

        XCTAssertEqual(store.snapshot().memoryInsights.count, 1)
        XCTAssertEqual(insight?.direction, "increase")
        XCTAssertEqual(insight?.category, "metadata")
        XCTAssertEqual(insight?.deltaPhysicalMB ?? 0, 260, accuracy: 0.01)
        XCTAssertEqual(insight?.deltaManagedMB ?? 0, 160, accuracy: 0.01)
        XCTAssertFalse(insight?.relatedEvents.isEmpty ?? true)
        XCTAssertGreaterThan(insight?.confidence ?? 0, 0.35)
    }

    func testMemoryInsightsPersistAcrossRuntimeStoreRestart() {
        let parser = LogParser()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonLogWatcherTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("memory-insights.json")
        let source = "/tmp/RoonServer/Logs/RoonServer_log.txt"
        let first = Date().addingTimeInterval(-60)
        let second = first.addingTimeInterval(20)
        let firstStats = "\(logTimestamp(for: first)) Info: [stats] 420000 MB Virtual 900 MB Physical 550 MB Managed 350 MB estimated Unmanaged"
        let secondStats = "\(logTimestamp(for: second)) Info: [stats] 420100 MB Virtual 1105 MB Physical 620 MB Managed 485 MB estimated Unmanaged"

        let store = RuntimeStore(memoryInsightStoreURL: storeURL)
        store.ingest(file: source, line: firstStats, events: parser.parse(file: source, line: firstStats), mode: .live)
        store.ingest(file: source, line: secondStats, events: parser.parse(file: source, line: secondStats), mode: .live)
        store.flushPersistence()

        let restored = RuntimeStore(memoryInsightStoreURL: storeURL)

        XCTAssertEqual(store.snapshot().memoryInsights.count, 1)
        XCTAssertEqual(restored.snapshot().memoryInsights.count, 1)
        XCTAssertEqual(restored.snapshot().memoryInsights.first?.deltaPhysicalMB ?? 0, 205, accuracy: 0.01)
        try? FileManager.default.removeItem(at: directory)
    }

    func testManagedMemoryBelowNinetyTwoPercentDoesNotWarn() {
        let parser = LogParser()
        var configuration = AppConfiguration.default
        configuration.memoryAlerts.managedMemoryMB = 1200
        let store = RuntimeStore(configuration: configuration)
        let line = "Info: [stats] 1088 MB Managed"

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: line,
            events: parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line),
            mode: .live
        )

        let snapshot = store.snapshot()
        XCTAssertFalse(snapshot.health.signals.contains { $0.domain == "memory" && $0.severity != .info })
        XCTAssertEqual(snapshot.health.score, 100)
    }

    func testManagedMemoryNearThresholdUsesSpecificSignal() {
        let parser = LogParser()
        var configuration = AppConfiguration.default
        configuration.memoryAlerts.managedMemoryMB = 1200
        let store = RuntimeStore(configuration: configuration)
        let line = "Info: [stats] 1105 MB Managed"

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: line,
            events: parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line),
            mode: .live
        )

        let signal = store.snapshot().health.signals.first { $0.id == "memory.managed_near_threshold" }
        XCTAssertEqual(signal?.severity, .info)
        XCTAssertEqual(signal?.valueMB, 1105)
        XCTAssertEqual(signal?.thresholdMB, 1200)
        XCTAssertEqual(store.snapshot().health.score, 100)
    }

    func testManagedMemoryOverThresholdWithoutSwapDoesNotLowerHealth() {
        let parser = LogParser()
        var configuration = AppConfiguration.default
        configuration.memoryAlerts.managedMemoryMB = 1200
        let store = RuntimeStore(configuration: configuration)
        store.updateSystemStatus(localSystemStatus(totalMemoryMB: 2_400, swapUsedMB: 4, swapTotalMB: 1_024))
        let line = "Info: [stats] 1220 MB Managed"

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: line,
            events: parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line),
            mode: .live
        )

        let snapshot = store.snapshot()
        let signal = snapshot.health.signals.first { $0.id == "memory.managed_high" }
        XCTAssertEqual(signal?.severity, .info)
        XCTAssertEqual(signal?.impact, 0)
        XCTAssertEqual(snapshot.health.score, 100)
        XCTAssertEqual(snapshot.health.state, .healthy)
    }

    func testAllocatedSwapWithoutActivityDoesNotLowerHealth() {
        let store = RuntimeStore()
        store.updateSystemStatus(localSystemStatus(totalMemoryMB: 2_400, swapUsedMB: 512, swapTotalMB: 2_048))

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/30 09:00:00 Info: alive",
            events: [],
            mode: .live
        )

        let snapshot = store.snapshot()
        let signal = snapshot.health.signals.first { $0.id == "system.swap.inactive" }
        XCTAssertEqual(signal?.severity, .info)
        XCTAssertEqual(signal?.valueMB, 512)
        XCTAssertEqual(snapshot.health.state, .healthy)
    }

    func testActiveSwapOutCreatesCriticalHealthSignal() {
        let store = RuntimeStore()
        store.updateSystemStatus(localSystemStatus(
            totalMemoryMB: 2_400,
            swapUsedMB: 800,
            swapTotalMB: 1_024,
            swapOutRateMBps: 6
        ))

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/30 09:00:00 Info: alive",
            events: [],
            mode: .live
        )

        let snapshot = store.snapshot()
        let signal = snapshot.health.signals.first { $0.id == "system.swap.critical" }
        XCTAssertEqual(signal?.severity, .critical)
        XCTAssertEqual(snapshot.health.state, .critical)
    }

    func testParsesPlainPlaybackBufferingAsNoticeWithZone() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/22 17:03:24 Trace: [zone Living Room] state changed: Prepared => Buffering"
        )

        XCTAssertTrue(events.contains { $0.type == "playback.buffering" && $0.zone == "Living Room" && $0.severity == .info })
        XCTAssertFalse(events.contains { $0.domain == "playback" && $0.severity != .info })
    }

    func testParsesPlaybackTimeoutAsVisibleWarning() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/22 17:03:24 Warn: [zone Living Room] state changed: Prepared => Buffering timeout"
        )

        XCTAssertTrue(events.contains { $0.type == "playback.warning.detected" && $0.zone == "Living Room" && $0.severity == .warning })
    }

    func testPlaybackTrackTitleCrashDoesNotBecomeServerError() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/29 16:23:58 Trace: [WiiM Ultra] [Enhanced, 16/44 TIDAL FLAC => 32/44] [100% buf] [PLAYING @ 3:38/4:38] Crash - Above & Beyond"
        )

        XCTAssertTrue(events.contains { $0.domain == "playback" && $0.type == "playback.playing" && $0.severity == .info })
        XCTAssertFalse(events.contains { $0.domain == "server" })
        XCTAssertFalse(events.contains { $0.severity == .warning || $0.severity == .critical })
    }

    func testActualServerCrashStillBecomesCritical() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/29 16:23:58 Error: RoonServer crash detected while starting server"
        )

        XCTAssertTrue(events.contains { $0.domain == "server" && $0.type == "server.exception" && $0.severity == .critical })
    }

    func testParsesDatabaseLockAsTransientNotice() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/database.log",
            line: "06/22 17:14:13 Error: SQLite busy (database is locked)"
        )

        XCTAssertTrue(events.contains { $0.domain == "database" && $0.type == "database.notice" && $0.severity == .info })
        XCTAssertFalse(events.contains { $0.domain == "database" && $0.severity == .warning })
    }

    func testParsesDatabaseFailureAsWarningHealthEvent() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/database.log",
            line: "06/22 17:14:13 Error: SQLite failed to open database file"
        )

        XCTAssertTrue(events.contains { $0.domain == "database" && $0.type == "database.warning" && $0.severity == .warning })
    }

    func testParsesDatabaseCorruptionAsCriticalHealthEvent() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/database.log",
            line: "06/22 17:14:13 Error: SQLite database disk image is malformed"
        )

        XCTAssertTrue(events.contains { $0.domain == "database" && $0.type == "database.critical" && $0.severity == .critical })
    }

    func testClassifiesRetryExceptionsAsInfoNotCritical() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/22 23:43:59 Warn: [concurrency] exception caught, but version changed out from under us. retry"
        )

        XCTAssertTrue(events.contains { $0.domain == "server" && $0.type == "server.exception.notice" && $0.severity == .info })
        XCTAssertFalse(events.contains { $0.severity == .warning || $0.severity == .critical })
    }

    func testClassifiesKnownRoonCriticalApiExceptionAsInfo() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/23 16:03:45 Critical: while dispatching events: System.InvalidOperationException: Already sent a final response"
        )

        XCTAssertTrue(events.contains { $0.domain == "extension" && $0.type == "extension.response_race" && $0.severity == .info })
        XCTAssertFalse(events.contains { $0.severity == .warning || $0.severity == .critical })
    }

    func testClassifiesRoonOperationalNoiseAsInfo() {
        let parser = LogParser()
        let lines = [
            "06/23 00:08:59 Critical: scx: in OnAfterEntry: System.IndexOutOfRangeException: Index was outside the bounds of the array.",
            "06/22 22:46:29 Critical: scx: in OnAfterExit: System.ArgumentException: Destination array was not long enough.",
            "06/22 23:09:12 Warn: [zone MRIRR] Swim failed to start (Result[Status=NotFound]), bailing",
            "06/22 23:09:02 Warn: [swim] Failed to start persisted swim session: Result[Status=NotFound]",
            "06/22 22:46:51 Warn: [storage] [directory] Failed to extract audio format from '/music/example.mp3': CorruptFile",
            "06/22 22:46:29 Warn: [devicedb] autodetect script failed: System.Collections.Generic.KeyNotFoundException",
            "06/23 18:14:46 Critical: Failed to perform search for query Delerium, Sarah McLachlan, John Summit Silence.: System.Collections.Generic.KeyNotFoundException"
        ]

        for line in lines {
            let events = parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line)
            XCTAssertTrue(events.contains { $0.domain == "log" && $0.type == "log.notice" && $0.severity == .info }, line)
            XCTAssertFalse(events.contains { $0.severity == .warning || $0.severity == .critical }, line)
        }
    }

    func testParsesOperationalAnalysisSignalsFromRoonLogs() {
        let parser = LogParser()
        let cases: [(String, String, Double?, String?)] = [
            ("07/10 05:01:29 Trace: [backup] preparing backup...", "backup.started", nil, nil),
            ("07/10 05:02:29 Trace: [backup] bytes transferred: 524288000/748131200 (70%)", "backup.progress", 524_288_000, "bytes"),
            ("07/10 05:03:29 Trace: [backup] writing backup manifest", "backup.finalizing", nil, nil),
            ("07/10 05:04:29 Trace: [backup] successful sync", "backup.completed", nil, nil),
            ("07/10 05:05:29 Trace: [updatemetadata] Flush: pending adds=13993, pending removes=7, current q size=4", "metadata.backlog", 14_004, "items"),
            ("07/10 05:06:29 Trace: [dbperf] flush leveldb in 245 ms", "database.latency", 245, "ms"),
            ("07/10 05:07:29 Trace: [library] endmutation in 812ms", "database.mutation", 812, "ms"),
            ("07/10 05:08:29 Trace: [library stats] tracks: 36000, albums: 1500", "library.stats", 36_000, "tracks"),
            ("07/10 05:09:29 Trace: [storage] initial scan of /Volumes/Music took: 3329 ms", "storage.scan.completed", 3_329, "ms"),
            ("07/10 05:10:29 Trace: [easyhttp] GET to https://api.tidal.com/v1/albums returned after 304 ms, status code: 200", "service.http", 304, "ms"),
            ("07/10 05:11:29 Trace: download speed: 6835kbps response time: 74ms", "streaming.download", 6_835, "kbps")
        ]

        for (line, type, value, unit) in cases {
            let parsed = parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line).first
            XCTAssertEqual(parsed?.type, type, line)
            if let value {
                XCTAssertEqual(parsed?.numericValue ?? -1, value, accuracy: 0.001, line)
            }
            XCTAssertEqual(parsed?.unit, unit, line)
        }
    }

    func testClassifiesImageRetryAndFileCacheStatusAsNonCritical() {
        let parser = LogParser()
        let retryEvents = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/22 23:21:40 Trace: [remoting/brokerserver] Failed to get image data due to IOException (attempt 1/3)"
        )
        let cacheEvents = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/22 23:48:12 Info: FTMSI-B 1 FileCache ti/C2980AA5 dwStatus:AllBlocksDownloaded files:1 accessTimeOut:True priorities: ('zoneplayer:6':10) --> bw limit:0kbps"
        )

        XCTAssertTrue(retryEvents.contains { $0.domain == "media" && $0.type == "media.image_retry" && $0.severity == .info })
        XCTAssertTrue(cacheEvents.contains { $0.domain == "cache" && $0.type == "cache.status" && $0.severity == .info })
        XCTAssertFalse(retryEvents.contains { $0.severity == .warning })
        XCTAssertFalse((retryEvents + cacheEvents).contains { $0.severity == .critical })
    }

    func testRuntimeStoreKeepsSnapshotCounters() {
        let store = RuntimeStore()
        let event = RuntimeEvent(
            id: "event-1",
            time: Date(),
            domain: "raat",
            type: "raat.disconnected",
            severity: .warning,
            title: "RAAT disconnected",
            message: "transport lost",
            source: "RoonServer/RoonServer_log.txt",
            valueMB: nil,
            zone: "Living Room"
        )

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "transport lost",
            events: [event],
            mode: .live
        )

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.mode, .live)
        XCTAssertEqual(snapshot.counters.processedLines, 1)
        XCTAssertEqual(snapshot.counters.warningCount, 1)
        XCTAssertEqual(snapshot.playback.count, 1)
    }

    func testRuntimeHealthBecomesCriticalForDatabaseCorruption() {
        let store = RuntimeStore()
        let event = RuntimeEvent(
            id: "database-corrupt",
            time: Date(),
            domain: "database",
            type: "database.critical",
            severity: .critical,
            title: "Database critical",
            message: "SQLite database disk image is malformed",
            source: "RoonServer/database.log",
            valueMB: nil,
            zone: nil
        )

        store.ingest(
            file: "/tmp/RoonServer/Logs/database.log",
            line: "SQLite database disk image is malformed",
            events: [event],
            mode: .live
        )

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.health.state, .critical)
        XCTAssertLessThan(snapshot.health.score, 70)
        XCTAssertTrue(snapshot.health.signals.contains { $0.id == "database.critical" })
    }

    func testPlainPlaybackBufferingBurstDoesNotAffectHealthScore() {
        let parser = LogParser()
        let store = RuntimeStore()

        for index in 0..<6 {
            let line = "Trace: [zone Living Room] state changed: Prepared => Buffering \(index)"
            store.ingest(
                file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
                line: line,
                events: parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line),
                mode: .live
            )
        }

        let snapshot = store.snapshot()

        XCTAssertFalse(snapshot.health.signals.contains { $0.id == "playback.unstable" })
        XCTAssertEqual(snapshot.counters.warningCount, 0)
    }

    func testPlaybackTimeoutBurstCreatesVisibleHealthWarning() {
        let parser = LogParser()
        let store = RuntimeStore()

        for index in 0..<6 {
            let line = "Warn: [zone Living Room] state changed: Prepared => Buffering timeout \(index)"
            store.ingest(
                file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
                line: line,
                events: parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line),
                mode: .live
            )
        }

        let snapshot = store.snapshot()
        let playbackSignal = snapshot.health.signals.first { $0.id == "playback.unstable" }

        XCTAssertEqual(snapshot.health.state, .degraded)
        XCTAssertGreaterThanOrEqual(snapshot.health.score, 70)
        XCTAssertEqual(playbackSignal?.severity, .warning)
        XCTAssertEqual(playbackSignal?.count, 6)
        XCTAssertEqual(snapshot.counters.warningCount, 6)
    }

    func testSingleRaatDisconnectDoesNotCreateHealthWarning() {
        let parser = LogParser()
        let store = RuntimeStore()
        let line = "Debug: [raat/tcpaudiosource] disconnecting"

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: line,
            events: parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line),
            mode: .live
        )

        let snapshot = store.snapshot()

        XCTAssertFalse(snapshot.health.signals.contains { $0.id == "raat.unstable" || $0.id == "raat.disconnected" })
        XCTAssertEqual(snapshot.counters.warningCount, 0)
        XCTAssertFalse(snapshot.playback.contains { $0.type == "raat.disconnected" })
    }

    func testIdleRaatDisconnectBurstDoesNotEscalateHealth() {
        let parser = LogParser()
        let store = RuntimeStore()

        for index in 0..<2 {
            let line = "Warn: [raat/tcpaudiosource] transport lost \(index)"
            store.ingest(
                file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
                line: line,
                events: parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line),
                mode: .live
            )
        }

        let snapshot = store.snapshot()
        XCTAssertFalse(snapshot.health.signals.contains { $0.id == "raat.unstable" })
        XCTAssertEqual(snapshot.counters.warningCount, 0)
        XCTAssertEqual(snapshot.diagnostics.incidents.first { $0.kind == "raat.transport" }?.severity, .info)
    }

    func testRuntimeStoreRetainsMoreThanEightyAlerts() {
        let store = RuntimeStore()

        for index in 0..<120 {
            let event = RuntimeEvent(
                id: "critical-\(index)",
                time: Date(),
                domain: "server",
                type: "server.exception",
                severity: .critical,
                title: "Server exception",
                message: "fatal test event \(index)",
                source: "RoonServer/RoonServer_log.txt",
                valueMB: nil,
                zone: nil
            )
            store.ingest(
                file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
                line: "fatal test event \(index)",
                events: [event],
                mode: .live
            )
        }

        XCTAssertEqual(store.snapshot().alerts.count, 120)
    }

    func testRuntimeStoreIgnoresAlertsOlderThanCurrentRun() {
        let store = RuntimeStore()
        let event = RuntimeEvent(
            id: "old-alert",
            time: Date().addingTimeInterval(-24 * 60 * 60),
            domain: "server",
            type: "server.critical.warning",
            severity: .warning,
            title: "Server critical log entry",
            message: "old archive alert",
            source: "RoonServer/RoonServer_log.06.txt",
            valueMB: nil,
            zone: nil
        )

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.06.txt",
            line: "old archive alert",
            events: [event],
            mode: .live
        )

        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.alerts.isEmpty)
        XCTAssertEqual(snapshot.counters.warningCount, 1)
    }

    func testRuntimeSnapshotIncludesSystemStatusAndHealthTrend() {
        let store = RuntimeStore()
        let now = Date()
        store.updateSystemStatus(LocalSystemStatus(
            sampledAt: now,
            host: RoonHostStatus(
                isRoonServerLikely: true,
                reason: "test",
                detectedProcesses: ["RoonServer"],
                detectedLogDirectories: ["/tmp/RoonServer/Logs"],
                checkedAt: now
            ),
            processes: [
                RoonProcessStatus(
                    pid: 123,
                    name: "RoonServer",
                    path: "/Applications/Roon.app/Contents/MacOS/RoonServer",
                    cpuPercent: 3.2,
                    memoryMB: 512,
                    openFiles: 42
                )
            ],
            totalCPUPercent: 3.2,
            totalMemoryMB: 512,
            openFileCount: 42,
            logVolumePath: "/tmp",
            logVolumeFreeMB: 100_000,
            logVolumeFreeRatio: 0.5
        ))

        store.ingest(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/22 18:00:00 Info: alive",
            events: [],
            mode: .live
        )

        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.system?.host.isRoonServerLikely == true)
        XCTAssertEqual(snapshot.system?.processes.first?.name, "RoonServer")
        XCTAssertFalse(snapshot.healthTrend.isEmpty)
        XCTAssertEqual(snapshot.memoryTrend24h.first?.metric, "Roon Process Memory")
        XCTAssertEqual(snapshot.memoryTrend24h.first?.valueMB, 512)
        XCTAssertTrue(snapshot.health.signals.contains { $0.id == "system.host.detected" })
    }

    func testHealthCountsCurrentSourcesInsteadOfRotatedArchives() {
        let store = RuntimeStore()
        store.setWatchedFiles([
            "/tmp/RoonServer/Logs/RoonServer_log.txt",
            "/tmp/RoonServer/Logs/RoonServer_log.01.txt",
            "/tmp/Roon/Logs/Roon_log.txt",
            "/tmp/RAATServer/Logs/RAATServer_log.20.txt"
        ])

        let snapshot = store.snapshot()
        let sourceSignal = snapshot.health.signals.first { $0.id == "source.active" }

        XCTAssertEqual(snapshot.counters.watchedFileCount, 4)
        XCTAssertEqual(sourceSignal?.count, 2)
    }

    func testRuntimeStoreRemovesSourcesNoLongerWatched() {
        let store = RuntimeStore()
        store.setWatchedFiles([
            "/tmp/RoonServer/Logs/RoonServer_log.txt",
            "/tmp/RoonServer/Logs/RoonServer_log.06.txt"
        ])
        store.setWatchedFiles([
            "/tmp/RoonServer/Logs/RoonServer_log.txt"
        ])

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.counters.watchedFileCount, 1)
        XCTAssertEqual(snapshot.watchedSources.map(\.path), ["/tmp/RoonServer/Logs/RoonServer_log.txt"])
    }

    func testLocalSystemSamplerDetectsRoonProcessesFromCommandListing() {
        let listing = """
        44252 0.6 72800 /Users/tester/Applications/RoonLogWatcher.app/Contents/MacOS/RoonLogWatcher
        49889 0.0 56912 /Applications/Roon.app/Contents/MacOS/RAATServer
        49890 0.1 94256 /Applications/Roon.app/Contents/Resources/../RoonServer.app/Contents/MacOS/RoonServer
        49898 1.4 2153360 /Applications/Roon.app/Contents/RoonServer.app/Contents/RoonAppliance.app/Contents/MacOS/RoonAppliance
        49900 0.0 592 /Applications/Roon.app/Contents/RoonServer.app/Contents/MonoBundle/processreaper 49898
        """
        let baseDate = Date()
        let mib = UInt64(1_048_576)
        var diskSampleIndex = 0
        let sampler = LocalSystemSampler(
            processListingProvider: { listing },
            openFileCountProvider: { pid in pid == 49898 ? 123 : 7 },
            diskIOProvider: { pid in
                let multiplier: UInt64
                switch pid {
                case 49889, 49890: multiplier = 1
                case 49898: multiplier = 2
                default: return nil
                }
                let readMB = diskSampleIndex == 0 ? 10 * multiplier : 40 * multiplier
                let writeMB = diskSampleIndex == 0 ? 5 * multiplier : 15 * multiplier
                return (readBytes: readMB * mib, writeBytes: writeMB * mib)
            },
            swapUsageProvider: { (totalMB: 2_048, usedMB: 128, freeMB: 1_920) },
            swapActivityProvider: {
                (pageSize: mib, swapIns: 0, swapOuts: UInt64(diskSampleIndex * 30))
            },
            nowProvider: { baseDate.addingTimeInterval(TimeInterval(diskSampleIndex * 30)) }
        )

        let initialStatus = sampler.sample(discoverer: RoonLogDiscoverer(environment: [:]), includeOpenFiles: true)
        XCTAssertNil(initialStatus.totalDiskReadRateMBps)

        diskSampleIndex = 1
        let status = sampler.sample(discoverer: RoonLogDiscoverer(environment: [:]), includeOpenFiles: true)

        XCTAssertEqual(status.processes.map(\.name), ["RAATServer", "RoonServer", "RoonAppliance"])
        XCTAssertEqual(status.totalCPUPercent, 1.5, accuracy: 0.01)
        XCTAssertEqual(status.totalMemoryMB, Double(56912 + 94256 + 2153360) / 1024, accuracy: 0.01)
        XCTAssertEqual(status.openFileCount, 137)
        XCTAssertEqual(status.totalDiskReadRateMBps ?? 0, 4.0, accuracy: 0.001)
        XCTAssertEqual(status.totalDiskWriteRateMBps ?? 0, 4.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(status.processes.first { $0.name == "RoonAppliance" }?.diskReadRateMBps ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(status.swapUsedMB, 128)
        XCTAssertEqual(status.swapUsedRatio ?? 0, 0.0625, accuracy: 0.0001)
        XCTAssertEqual(status.swapOutRateMBps ?? 0, 1, accuracy: 0.001)
        XCTAssertFalse(status.processes.contains { $0.name == "RoonLogWatcher" || $0.path.contains("processreaper") })
    }

    private func memoryEvent(time: Date, valueMB: Double) -> RuntimeEvent {
        memoryMetricEvent(title: "Physical Memory", time: time, valueMB: valueMB)
    }

    private func memoryStatsEvents(time: Date, physicalMB: Double) -> [RuntimeEvent] {
        [
            memoryMetricEvent(title: "Virtual Memory", time: time, valueMB: physicalMB + 420_000),
            memoryMetricEvent(title: "Physical Memory", time: time, valueMB: physicalMB),
            memoryMetricEvent(title: "Managed Memory", time: time, valueMB: max(0, physicalMB - 600)),
            memoryMetricEvent(title: "Unmanaged Memory", time: time, valueMB: 600)
        ]
    }

    private func memoryMetricEvent(title: String, time: Date, valueMB: Double) -> RuntimeEvent {
        RuntimeEvent(
            id: UUID().uuidString,
            time: time,
            domain: "memory",
            type: "memory.sample.detected",
            severity: .info,
            title: title,
            message: "\(title): \(Int(valueMB)) MB",
            source: "RoonServer/RoonServer_log.txt",
            valueMB: valueMB,
            zone: nil
        )
    }

    private func localSystemStatus(
        totalMemoryMB: Double,
        totalPhysicalMemoryMB: Double = 16_384,
        swapUsedMB: Double,
        swapTotalMB: Double,
        swapOutRateMBps: Double? = nil
    ) -> LocalSystemStatus {
        LocalSystemStatus(
            sampledAt: Date(),
            host: RoonHostStatus(
                isRoonServerLikely: true,
                reason: "test",
                detectedProcesses: ["RoonAppliance"],
                detectedLogDirectories: ["/tmp/RoonServer/Logs"],
                checkedAt: Date()
            ),
            processes: [
                RoonProcessStatus(
                    pid: 123,
                    name: "RoonAppliance",
                    path: "/Applications/Roon.app/Contents/RoonServer.app/Contents/RoonAppliance.app/Contents/MacOS/RoonAppliance",
                    cpuPercent: 1.0,
                    memoryMB: totalMemoryMB,
                    openFiles: nil
                )
            ],
            totalCPUPercent: 1.0,
            totalMemoryMB: totalMemoryMB,
            totalPhysicalMemoryMB: totalPhysicalMemoryMB,
            openFileCount: nil,
            swapTotalMB: swapTotalMB,
            swapUsedMB: swapUsedMB,
            swapFreeMB: max(0, swapTotalMB - swapUsedMB),
            swapUsedRatio: swapTotalMB > 0 ? swapUsedMB / swapTotalMB : nil,
            swapOutRateMBps: swapOutRateMBps,
            logVolumePath: nil,
            logVolumeFreeMB: nil,
            logVolumeFreeRatio: nil
        )
    }

    private func logTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
