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
        XCTAssertEqual(signal?.severity, .warning)
        XCTAssertEqual(signal?.valueMB, 1105)
        XCTAssertEqual(signal?.thresholdMB, 1200)
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

        XCTAssertTrue(events.contains { $0.domain == "server" && $0.type == "server.exception.notice" && $0.severity == .info })
        XCTAssertFalse(events.contains { $0.severity == .warning || $0.severity == .critical })
    }

    func testClassifiesRoonOperationalNoiseAsInfo() {
        let parser = LogParser()
        let lines = [
            "06/23 00:08:59 Critical: scx: in OnAfterEntry: System.IndexOutOfRangeException: Index was outside the bounds of the array.",
            "06/22 23:09:12 Warn: [zone MRIRR] Swim failed to start (Result[Status=NotFound]), bailing",
            "06/22 23:09:02 Warn: [swim] Failed to start persisted swim session: Result[Status=NotFound]",
            "06/22 22:46:51 Warn: [storage] [directory] Failed to extract audio format from '/music/example.mp3': CorruptFile"
        ]

        for line in lines {
            let events = parser.parse(file: "/tmp/RoonServer/Logs/RoonServer_log.txt", line: line)
            XCTAssertTrue(events.contains { $0.domain == "log" && $0.type == "log.notice" && $0.severity == .info }, line)
            XCTAssertFalse(events.contains { $0.severity == .warning || $0.severity == .critical }, line)
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

    func testRaatDisconnectBurstEscalatesHealth() {
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
        let raatSignal = snapshot.health.signals.first { $0.id == "raat.unstable" }

        XCTAssertEqual(raatSignal?.severity, .warning)
        XCTAssertEqual(raatSignal?.count, 2)
        XCTAssertEqual(snapshot.counters.warningCount, 2)
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
}
