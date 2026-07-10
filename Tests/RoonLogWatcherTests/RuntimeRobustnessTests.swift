import XCTest
@testable import RoonLogWatcherCore

final class RuntimeRobustnessTests: XCTestCase {
    func testBoundedArrayUsesStableOrderAcrossWrapResizeAndRemoval() {
        var values = BoundedArray<Int>(limit: 3)
        values.append(contentsOf: [1, 2, 3, 4, 5])
        XCTAssertEqual(values.items, [3, 4, 5])
        XCTAssertEqual(values.orderedSuffix(2), [4, 5])
        XCTAssertTrue(values.containsInSuffix(2) { $0 == 4 })
        XCTAssertFalse(values.containsInSuffix(2) { $0 == 3 })

        values.resize(to: 2)
        values.append(6)
        XCTAssertEqual(values.items, [5, 6])

        values.removeAll { $0 == 5 }
        XCTAssertEqual(values.items, [6])
    }

    func testLogTailerBuffersPartialUTF8LineUntilNewline() throws {
        let fixture = try makeTailerFixture(maxReadBytes: 1_024)
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.tailer.start())
        defer { fixture.tailer.stop() }

        let prefix = Data("07/10 08:00:00 Info: Grüße ".utf8)
        let emoji = Data("🎵".utf8)
        var firstWrite = prefix
        firstWrite.append(emoji.prefix(2))
        try append(firstWrite, to: fixture.logURL)
        fixture.tailer.pollNowForTesting()
        XCTAssertTrue(fixture.lines().isEmpty)

        var secondWrite = Data(emoji.dropFirst(2))
        secondWrite.append(Data(" vollständig\n".utf8))
        try append(secondWrite, to: fixture.logURL)
        fixture.tailer.pollNowForTesting()

        XCTAssertEqual(fixture.lines(), ["07/10 08:00:00 Info: Grüße 🎵 vollständig"])
    }

    func testLogTailerReadsLargeBacklogInBoundedChunksWithoutLosingLines() throws {
        let fixture = try makeTailerFixture(maxReadBytes: 1_024)
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.tailer.start())
        defer { fixture.tailer.stop() }

        let lines = (0..<4).map { index in
            "07/10 08:00:0\(index) Info: \(String(repeating: String(index), count: 700))"
        }
        try append(Data((lines.joined(separator: "\n") + "\n").utf8), to: fixture.logURL)

        for _ in 0..<4 {
            fixture.tailer.pollNowForTesting()
        }

        XCTAssertEqual(fixture.lines(), lines)
    }

    func testLogTailerReceivesFileSystemEventsWithoutPolling() throws {
        let fixture = try makeTailerFixture(maxReadBytes: 1_024)
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.tailer.start())
        defer { fixture.tailer.stop() }

        let expected = "07/10 08:00:00 Info: event-driven"
        try append(Data("\(expected)\n".utf8), to: fixture.logURL)
        let deadline = Date().addingTimeInterval(2)
        while fixture.lines().isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertEqual(fixture.lines(), [expected])
    }

    func testRuntimeConfigurationAppliesRetentionAndShowAllImmediately() {
        var configuration = AppConfiguration.default
        configuration.recentLogMaxLines = 200
        configuration.logHistoryMaxLines = 200
        let store = RuntimeStore(configuration: configuration)

        for index in 0..<150 {
            store.ingest(file: "/tmp/RoonServer_log.txt", line: "Info: \(index)", events: [], mode: .live)
        }
        XCTAssertEqual(store.snapshot().recentLogs.count, 150)

        configuration.recentLogMaxLines = 100
        configuration.logHistoryMaxLines = 100
        configuration.showAllLogLines = false
        store.updateConfiguration(configuration)
        store.ingest(file: "/tmp/RoonServer_log.txt", line: "Trace: ignored detail", events: [], mode: .live)

        let filtered = store.snapshot()
        XCTAssertEqual(filtered.recentLogs.count, 100)
        XCTAssertNotNil(filtered.health.lastLogAt)

        store.ingest(
            file: "/tmp/RoonServer_log.txt",
            line: "Warn: visible",
            events: [event(domain: "log", type: "log.highlight", severity: .warning)],
            mode: .live
        )
        XCTAssertEqual(store.snapshot().recentLogs.first?.text, "Warn: visible")
    }

    func testOldServerExceptionExpiresFromHealthWindow() {
        let store = RuntimeStore()
        store.ingest(
            file: "/tmp/RoonServer_log.txt",
            line: "Error: old crash",
            events: [event(
                domain: "server",
                type: "server.exception",
                severity: .critical,
                time: Date().addingTimeInterval(-60 * 60)
            )],
            mode: .live
        )

        let health = store.snapshot().health
        XCTAssertFalse(health.signals.contains { $0.id == "server.exception" })
        XCTAssertNotEqual(health.state, .critical)
    }

    func testParserChoosesNearestYearAcrossNewYear() throws {
        let calendar = Calendar(identifier: .gregorian)
        let januaryReference = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2027,
            month: 1,
            day: 1,
            hour: 0,
            minute: 1
        )))
        let decemberParser = LogParser(nowProvider: { januaryReference })
        let decemberEvent = try XCTUnwrap(decemberParser.parse(
            file: "/tmp/RoonServer_log.txt",
            line: "12/31 23:59:59 Trace: [zone Living Room] state changed: Prepared => Buffering"
        ).first)
        XCTAssertEqual(calendar.component(.year, from: decemberEvent.time), 2026)

        let decemberReference = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 12,
            day: 31,
            hour: 23,
            minute: 59
        )))
        let januaryParser = LogParser(nowProvider: { decemberReference })
        let januaryEvent = try XCTUnwrap(januaryParser.parse(
            file: "/tmp/RoonServer_log.txt",
            line: "01/01 00:00:01 Trace: [zone Living Room] state changed: Prepared => Buffering"
        ).first)
        XCTAssertEqual(calendar.component(.year, from: januaryEvent.time), 2027)
    }

    func testMetadataContainingCrashOrPanicIsNotServerFailure() {
        let parser = LogParser()
        let crashEvents = parser.parse(
            file: "/tmp/RoonServer_log.txt",
            line: "07/10 08:00:00 Trace: [metadata] title=Crash artist=The Primitives"
        )
        let panicEvents = parser.parse(
            file: "/tmp/RoonServer_log.txt",
            line: "07/10 08:00:01 Trace: [metadata] artist=Panic! At The Disco"
        )

        XCTAssertFalse((crashEvents + panicEvents).contains { $0.domain == "server" })
    }

    func testLiveSnapshotIsCompactAndSupportsLogDeltas() throws {
        let store = RuntimeStore()
        for index in 0..<20 {
            store.ingest(
                file: "/tmp/RoonServer_log.txt",
                line: "Info: playback \(index)",
                events: [event(domain: "playback", type: "playback.playing", severity: .info)],
                mode: .live
            )
        }

        let full = store.snapshot()
        let compact = store.liveSnapshot()
        XCTAssertEqual(full.playback.count, 20)
        XCTAssertEqual(compact.playback.count, 12)
        XCTAssertTrue(compact.timeline.isEmpty)
        XCTAssertLessThanOrEqual(compact.healthTrend.count, 48)

        let newestID = try XCTUnwrap(compact.recentLogs.first?.id)
        store.ingest(file: "/tmp/RoonServer_log.txt", line: "Info: next", events: [], mode: .live)
        let delta = store.liveSnapshot(logsAfterID: newestID)
        XCTAssertEqual(delta.recentLogs.map(\.text), ["Info: next"])
    }

    func testHealthReturnsEverySignalUsedForScore() {
        let now = Date()
        let store = RuntimeStore()
        var events = [
            event(domain: "log", type: "log.highlight", severity: .critical, time: now),
            event(domain: "server", type: "server.exception", severity: .critical, time: now),
            event(domain: "server", type: "server.exception.warning", severity: .warning, time: now),
            event(domain: "server", type: "server.stopped", severity: .warning, time: now),
            event(domain: "database", type: "database.critical", severity: .critical, time: now)
        ]
        events += (0..<5).map { _ in event(domain: "raat", type: "raat.disconnected", severity: .warning, time: now) }
        events += (0..<15).map { _ in event(domain: "playback", type: "playback.warning.detected", severity: .warning, time: now) }
        events += [
            memoryEvent("Physical Memory", 5_000, now),
            memoryEvent("Managed Memory", 3_000, now),
            memoryEvent("Unmanaged Memory", 2_500, now)
        ]
        store.ingest(file: "/tmp/RoonServer_log.txt", line: "Error: combined fixture", events: events, mode: .live)
        store.updateSystemStatus(pressuredSystemStatus(now: now))

        let health = store.snapshot().health
        let totalImpact = min(100, health.signals.reduce(0) { $0 + max(0, $1.impact) })
        XCTAssertGreaterThan(health.signals.count, 10)
        XCTAssertEqual(health.score, 100 - totalImpact)
    }

    func testDashboardPortCandidatesDoNotOverflowAndOccupiedPortFallsBack() throws {
        XCTAssertEqual(DashboardServer.candidatePorts(preferredPort: 65_535), [65_535])
        XCTAssertEqual(DashboardServer.candidatePorts(preferredPort: 65_530), Array(65_530...65_535))

        let preferred = UInt16(32_000 + Int.random(in: 0..<1_000))
        let first = dashboardServerFixture()
        let second = dashboardServerFixture()
        try first.server.start(preferredPort: preferred)
        defer { first.server.stop(); first.cleanup() }
        try second.server.start(preferredPort: preferred)
        defer { second.server.stop(); second.cleanup() }

        XCTAssertNotEqual(first.server.url?.port, second.server.url?.port)
    }

    func testActiveSwapOutCreatesWarningWhileInactiveSwapStaysInformational() {
        let inactive = RuntimeStore()
        inactive.updateSystemStatus(systemStatus(swapOutRateMBps: 0))
        inactive.ingest(file: "/tmp/RoonServer_log.txt", line: "Info: alive", events: [], mode: .live)
        XCTAssertTrue(inactive.snapshot().health.signals.contains {
            $0.id == "system.swap.inactive" && $0.impact == 0
        })

        let active = RuntimeStore()
        active.updateSystemStatus(systemStatus(swapOutRateMBps: 0.5))
        active.ingest(file: "/tmp/RoonServer_log.txt", line: "Info: alive", events: [], mode: .live)
        XCTAssertTrue(active.snapshot().health.signals.contains {
            $0.id == "system.swap.used" && $0.severity == .warning
        })
    }

    private func makeTailerFixture(maxReadBytes: Int) throws -> TailerFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonLogTailerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("RoonServer_log.txt")
        try Data().write(to: logURL)
        let configURL = directory.appendingPathComponent("config.json")
        let configStore = AppConfigStore(configURL: configURL)
        var configuration = configStore.configuration
        configuration.autoDiscoverRoonLogDirectories = false
        configuration.logDirectories = [directory.path]
        configuration.watchExistingLogsFromEnd = true
        configuration.pollIntervalSeconds = 30
        try configStore.save(configuration)

        let lineStore = LineStore()
        let tailer = LogTailer(
            discoverer: RoonLogDiscoverer(environment: [:], configStore: configStore),
            configStore: configStore,
            maxReadBytesPerFilePerPoll: maxReadBytes
        ) { _, line in
            lineStore.append(line)
        }
        return TailerFixture(directory: directory, logURL: logURL, tailer: tailer, lineStore: lineStore)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func event(
        domain: String,
        type: String,
        severity: Severity,
        time: Date = Date()
    ) -> RuntimeEvent {
        RuntimeEvent(
            id: UUID().uuidString,
            time: time,
            domain: domain,
            type: type,
            severity: severity,
            title: type,
            message: type,
            source: "RoonServer/RoonServer_log.txt",
            valueMB: nil,
            zone: nil
        )
    }

    private func memoryEvent(_ title: String, _ valueMB: Double, _ time: Date) -> RuntimeEvent {
        RuntimeEvent(
            id: UUID().uuidString,
            time: time,
            domain: "memory",
            type: "memory.sample.detected",
            severity: .info,
            title: title,
            message: title,
            source: "RoonServer/RoonServer_log.txt",
            valueMB: valueMB,
            zone: nil
        )
    }

    private func pressuredSystemStatus(now: Date) -> LocalSystemStatus {
        LocalSystemStatus(
            sampledAt: now,
            host: hostStatus(now: now),
            processes: [RoonProcessStatus(
                pid: 123,
                name: "RoonServer",
                path: "/Applications/RoonServer",
                cpuPercent: 95,
                memoryMB: 10_000,
                openFiles: nil
            )],
            totalCPUPercent: 95,
            totalMemoryMB: 10_000,
            totalPhysicalMemoryMB: 16_384,
            openFileCount: nil,
            swapTotalMB: 4_096,
            swapUsedMB: 2_048,
            swapFreeMB: 2_048,
            swapUsedRatio: 0.5,
            swapOutRateMBps: 6,
            logVolumePath: "/tmp",
            logVolumeFreeMB: 100,
            logVolumeFreeRatio: 0.001
        )
    }

    private func systemStatus(swapOutRateMBps: Double) -> LocalSystemStatus {
        let now = Date()
        return LocalSystemStatus(
            sampledAt: now,
            host: hostStatus(now: now),
            processes: [],
            totalCPUPercent: 0,
            totalMemoryMB: 2_000,
            totalPhysicalMemoryMB: 16_384,
            openFileCount: nil,
            swapTotalMB: 4_096,
            swapUsedMB: 1_024,
            swapFreeMB: 3_072,
            swapUsedRatio: 0.25,
            swapOutRateMBps: swapOutRateMBps,
            logVolumePath: nil,
            logVolumeFreeMB: nil,
            logVolumeFreeRatio: nil
        )
    }

    private func hostStatus(now: Date) -> RoonHostStatus {
        RoonHostStatus(
            isRoonServerLikely: true,
            reason: "test",
            detectedProcesses: ["RoonServer"],
            detectedLogDirectories: ["/tmp"],
            checkedAt: now
        )
    }

    private func dashboardServerFixture() -> DashboardFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoonDashboardTests-\(UUID().uuidString)", isDirectory: true)
        let configStore = AppConfigStore(configURL: directory.appendingPathComponent("config.json"))
        return DashboardFixture(
            directory: directory,
            server: DashboardServer(store: RuntimeStore(), configStore: configStore)
        )
    }
}

private final class LineStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ line: String) {
        lock.lock()
        values.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct TailerFixture {
    var directory: URL
    var logURL: URL
    var tailer: LogTailer
    var lineStore: LineStore

    func lines() -> [String] { lineStore.snapshot() }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private struct DashboardFixture {
    var directory: URL
    var server: DashboardServer

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
