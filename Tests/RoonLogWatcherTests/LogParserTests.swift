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

    func testParsesPlaybackWarningWithZone() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/22 17:03:24 Warn: [zone Living Room] state changed: Prepared => Buffering timeout"
        )

        XCTAssertTrue(events.contains { $0.type == "playback.buffering" && $0.zone == "Living Room" })
        XCTAssertTrue(events.contains { $0.type == "playback.warning.detected" && $0.severity == .warning })
    }

    func testParsesDatabaseLockAsWarningHealthEvent() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/database.log",
            line: "06/22 17:14:13 Error: SQLite busy (database is locked)"
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

    func testClassifiesRetryExceptionsAsWarningNotCritical() {
        let parser = LogParser()
        let events = parser.parse(
            file: "/tmp/RoonServer/Logs/RoonServer_log.txt",
            line: "06/22 23:43:59 Warn: [concurrency] exception caught, but version changed out from under us. retry"
        )

        XCTAssertTrue(events.contains { $0.domain == "server" && $0.type == "server.exception.warning" && $0.severity == .warning })
        XCTAssertFalse(events.contains { $0.severity == .critical })
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

    func testPlaybackBufferingBurstDoesNotZeroHealthScore() {
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
        XCTAssertEqual(playbackSignal?.count, 12)
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
