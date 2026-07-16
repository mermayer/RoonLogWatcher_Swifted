import XCTest
@testable import RoonLogWatcherCore

final class DiagnosticAnalysisTests: XCTestCase {
    func testCurrentRoonStatsRejectImpossibleNegativeNativeTelemetry() throws {
        let parser = LogParser()
        let line = "07/10 08:45:47 Info: [stats] 428491mb Virtual; 952mb Physical = 1280mb GC-committed (906mb Managed-live = 70% of committed) + -328mb Native; 0,18% of runtime in GC pauses, 67ms GC pause in last window (0,45% of window)"
        let events = parser.parse(file: "/tmp/RoonServer_log.txt", line: line)

        XCTAssertEqual(events.first { $0.title == "Physical Memory" }?.valueMB, 952)
        XCTAssertEqual(events.first { $0.title == "GC Committed Memory" }?.valueMB, 1_280)
        XCTAssertEqual(events.first { $0.title == "Managed Memory" }?.valueMB, 906)
        XCTAssertNil(events.first { $0.title == "Native Memory" }?.valueMB)
        XCTAssertEqual(events.first { $0.type == "memory.metric.unavailable" }?.severity, .info)
        XCTAssertEqual(events.first { $0.title == "GC Pause Window Percent" }?.numericValue ?? 0, 0.45, accuracy: 0.001)

        let store = RuntimeStore()
        store.ingest(file: "/tmp/RoonServer_log.txt", line: line, events: events, mode: .live)
        let telemetry = store.snapshot().diagnostics.telemetry
        XCTAssertEqual(telemetry.gcCommittedMB, 1_280)
        XCTAssertNil(telemetry.nativeMemoryMB)
        XCTAssertEqual(telemetry.gcPauseWindowMilliseconds, 67)
    }

    func testKnownRoonOperationalWarningsAreDomainSpecificNotGenericWarnings() {
        let parser = LogParser()
        let cases: [(String, String, String)] = [
            ("Warn: [mlradio] [4] Merging tidal-de tracks: Result[Status=Success]", "log.notice", "log"),
            ("Warn: [zone MRIRR] waveform load for track 1 failed with NotFound after 4 attempts; giving up", "log.notice", "log"),
            ("Trace: [roonapi] [apiclient 192.0.2.10:39327] CONNECTION TIMEOUT", "extension.timeout", "extension"),
            ("Error: [mobile] [multinat] Failed to create port mapping.", "remote.port_mapping.failed", "remote"),
            ("Error: [cast/client] [Living Room._googlecast._tcp.local] Unable to authenticate TLS connection", "device.cast.authentication", "device")
        ]

        for (line, type, domain) in cases {
            let events = parser.parse(file: "/tmp/RoonServer_log.txt", line: line)
            XCTAssertEqual(events.first?.type, type, line)
            XCTAssertEqual(events.first?.domain, domain, line)
            XCTAssertEqual(events.first?.severity, .info, line)
        }
    }

    func testDatabaseMaintenanceAbsorbsRaatDisconnectBurst() {
        let store = RuntimeStore()
        let base = Date().addingTimeInterval(-10)
        store.ingest(file: "/tmp/RoonServer_log.txt", line: "Validating Database", events: [event(time: base, domain: "database", type: "database.maintenance.started", severity: .info)], mode: .live)
        for index in 0..<3 {
            store.ingest(file: "/tmp/RoonServer_log.txt", line: "RAAT disconnected \(index)", events: [event(time: base.addingTimeInterval(Double(index + 1)), domain: "raat", type: "raat.disconnected", severity: .warning, zone: "WiiM Ultra")], mode: .live)
        }

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.diagnostics.incidents.filter { $0.kind == "database.maintenance" }.count, 1)
        XCTAssertFalse(snapshot.diagnostics.incidents.contains { $0.kind == "raat.transport" })
        XCTAssertFalse(snapshot.health.signals.contains { $0.id == "raat.unstable" && $0.impact > 0 })
        XCTAssertEqual(snapshot.health.score, 100)
    }

    func testRaatRecoveryResolvesIncidentAndClearsHealthImpact() {
        let store = RuntimeStore()
        let now = Date().addingTimeInterval(-10)
        store.ingest(file: "/tmp/RAATServer_log.txt", line: "disconnected", events: [event(time: now, domain: "raat", type: "raat.disconnected", severity: .warning, zone: "Kitchen")], mode: .live)
        store.ingest(file: "/tmp/RAATServer_log.txt", line: "connected", events: [event(time: now.addingTimeInterval(2), domain: "raat", type: "raat.connected", severity: .info, zone: "Kitchen")], mode: .live)

        let snapshot = store.snapshot()
        let incident = snapshot.diagnostics.incidents.first { $0.kind == "raat.transport" }
        XCTAssertEqual(incident?.state, .resolved)
        XCTAssertNotNil(incident?.resolvedAt)
        XCTAssertFalse(snapshot.health.signals.contains { $0.domain == "raat" && $0.impact > 0 })
    }

    func testCorrelatedIncidentCapsDuplicateRaatHealthImpact() {
        let store = RuntimeStore()
        let now = Date().addingTimeInterval(-12)
        store.ingest(
            file: "/tmp/RAATServer_log.txt",
            line: "playing",
            events: [event(time: now.addingTimeInterval(-1), domain: "playback", type: "playback.playing", severity: .info, zone: "Office")],
            mode: .live
        )
        for index in 0..<2 {
            store.ingest(file: "/tmp/RAATServer_log.txt", line: "disconnect \(index)", events: [event(time: now.addingTimeInterval(Double(index)), domain: "raat", type: "raat.disconnected", severity: .warning, zone: "Office")], mode: .live)
        }

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.health.score, 88)
        XCTAssertFalse(snapshot.health.signals.contains { $0.id == "raat.unstable" })
        XCTAssertTrue(snapshot.health.signals.contains { $0.id.hasPrefix("incident.") && $0.domain == "raat" })
    }

    func testLargeRoonAPIStatePayloadWinsMemoryAttribution() throws {
        let parser = LogParser()
        let store = RuntimeStore()
        let now = Date()
        let first = statsLine(at: now, physical: 1_000, managed: 700, native: 0)
        store.ingest(file: "/tmp/RoonServer_log.txt", line: first, events: parser.parse(file: "/tmp/RoonServer_log.txt", line: first), mode: .live)

        let payload = "\(timestamp(now.addingTimeInterval(5))) Trace: [roonapi] [apiclient 192.0.2.10:40000] CONTINUE Subscribed {\"items\":\"\(String(repeating: "x", count: 6_000))\",\"token\":\"secret-value\"}"
        store.ingest(file: "/tmp/RoonServer_log.txt", line: payload, events: parser.parse(file: "/tmp/RoonServer_log.txt", line: payload), mode: .live)
        let library = "\(timestamp(now.addingTimeInterval(8))) Info: [library stats] tracks: 36000, albums: 1500"
        store.ingest(file: "/tmp/RoonServer_log.txt", line: library, events: parser.parse(file: "/tmp/RoonServer_log.txt", line: library), mode: .live)

        let second = statsLine(at: now.addingTimeInterval(10), physical: 1_320, managed: 710, native: 40)
        store.ingest(file: "/tmp/RoonServer_log.txt", line: second, events: parser.parse(file: "/tmp/RoonServer_log.txt", line: second), mode: .live)

        let insight = try XCTUnwrap(store.snapshot().memoryInsights.first)
        XCTAssertEqual(insight.category, "extension")
        XCTAssertEqual(insight.relatedEvents.first { $0.category == "extension" }?.relation, "before")
        XCTAssertGreaterThan(insight.relatedEvents.first { $0.category == "extension" }?.byteCount ?? 0, 6_000)
        let incident = try XCTUnwrap(store.snapshot().diagnostics.incidents.first { $0.kind == "extension.sync" })
        XCTAssertFalse(incident.evidence.contains { $0.message.contains("secret-value") })
    }

    func testExtensionConnectionsFromChangingPortsShareOneIncidentAndRedactSecrets() throws {
        let parser = LogParser()
        let store = RuntimeStore()
        let now = Date()
        for (index, port) in [40_001, 40_002].enumerated() {
            let line = "\(timestamp(now.addingTimeInterval(Double(index)))) Trace: [roonapi] [apiclient 192.0.2.10:\(port)] CONTINUE Subscribed {\"items\":\"\(String(repeating: "x", count: 4_100))\",token=plain-secret, authorization:Bearer-secret}"
            store.ingest(file: "/tmp/RoonServer_log.txt", line: line, events: parser.parse(file: "/tmp/RoonServer_log.txt", line: line), mode: .live)
        }

        let incidents = store.snapshot().diagnostics.incidents.filter { $0.kind == "extension.sync" }
        let incident = try XCTUnwrap(incidents.first)
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incident.eventCount, 2)
        XCTAssertFalse(incident.evidence.contains { $0.message.contains("plain-secret") || $0.message.contains("Bearer-secret") })
        XCTAssertFalse(incident.evidence.contains { $0.message.contains("$2") })
    }

    func testBackupEpisodeCapturesDurationVolumeAndMemoryContext() throws {
        let engine = DiagnosticAnalysisEngine()
        let start = Date().addingTimeInterval(-120)
        engine.ingest(
            events: [event(time: start.addingTimeInterval(-1), domain: "memory", type: "memory.sample.detected", severity: .info, title: "Physical Memory", value: 1_000)],
            line: "1000 MB Physical",
            receivedAt: start,
            source: "RoonServer_log.txt"
        )
        engine.ingest(
            events: [event(time: start, domain: "backup", type: "backup.started", severity: .info)],
            line: "[backup] preparing backup",
            receivedAt: start,
            source: "RoonServer_log.txt"
        )
        engine.ingest(
            events: [event(time: start.addingTimeInterval(40), domain: "backup", type: "backup.progress", severity: .info, value: 700 * 1_048_576, unit: "bytes")],
            line: "[backup] bytes transferred",
            receivedAt: start.addingTimeInterval(40),
            source: "RoonServer_log.txt"
        )
        engine.ingest(
            events: [event(time: start.addingTimeInterval(60), domain: "memory", type: "memory.sample.detected", severity: .info, title: "Physical Memory", value: 1_280)],
            line: "1280 MB Physical",
            receivedAt: start.addingTimeInterval(60),
            source: "RoonServer_log.txt"
        )
        engine.ingest(
            events: [event(time: start.addingTimeInterval(90), domain: "backup", type: "backup.completed", severity: .info)],
            line: "[backup] successful sync",
            receivedAt: start.addingTimeInterval(90),
            source: "RoonServer_log.txt"
        )

        let snapshot = engine.snapshot(now: start.addingTimeInterval(100), compact: false)
        let incident = try XCTUnwrap(snapshot.incidents.first { $0.kind == "backup.run" })
        XCTAssertEqual(incident.state, .resolved)
        XCTAssertEqual(incident.severity, .info)
        XCTAssertEqual(incident.durationSeconds ?? 0, 90, accuracy: 0.1)
        XCTAssertEqual(incident.dataBytes, 700 * 1_048_576)
        XCTAssertTrue(incident.details?.contains { $0.contains("Memory change: 280 MB") } == true)
        XCTAssertEqual(snapshot.metrics.first { $0.kind == "backup.status" }?.severity, .info)
    }

    func testShortAuthenticationRetryBurstIsOneInformationalEpisode() throws {
        let engine = DiagnosticAnalysisEngine()
        let start = Date().addingTimeInterval(-30)
        for index in 0..<24 {
            let time = start.addingTimeInterval(Double(index) * 17.0 / 23.0)
            engine.ingest(
                events: [event(time: time, domain: "service", type: "service.auth.failed", severity: .info, zone: "Roon account")],
                line: "EnsureAuthReady failed",
                receivedAt: time,
                source: "RoonServer_log.txt"
            )
        }
        engine.ingest(
            events: [event(time: start.addingTimeInterval(17), domain: "service", type: "service.auth.recovered", severity: .info, zone: "Roon account")],
            line: "AccountStatus=LoggedIn",
            receivedAt: start.addingTimeInterval(17),
            source: "RoonServer_log.txt"
        )

        let incident = try XCTUnwrap(engine.snapshot(now: start.addingTimeInterval(20), compact: false).incidents.first { $0.kind == "service.authentication" })
        XCTAssertEqual(incident.state, .resolved)
        XCTAssertEqual(incident.severity, .info)
        XCTAssertEqual(incident.healthImpact, 0)
        XCTAssertEqual(incident.eventCount, 24)
        XCTAssertEqual(incident.durationSeconds ?? 0, 17, accuracy: 0.1)
    }

    func testBufferingSeverityUsesPlaybackContextAndDuration() throws {
        let engine = DiagnosticAnalysisEngine()
        let start = Date().addingTimeInterval(-20)
        engine.ingest(
            events: [event(time: start, domain: "playback", type: "playback.playing", severity: .info, zone: "Office")],
            line: "playing",
            receivedAt: start,
            source: "RAATServer_log.txt"
        )
        engine.ingest(
            events: [event(time: start.addingTimeInterval(1), domain: "playback", type: "playback.buffering", severity: .info, zone: "Office")],
            line: "buffering",
            receivedAt: start.addingTimeInterval(1),
            source: "RAATServer_log.txt"
        )
        engine.ingest(
            events: [event(time: start.addingTimeInterval(5), domain: "playback", type: "playback.playing", severity: .info, zone: "Office")],
            line: "playing",
            receivedAt: start.addingTimeInterval(5),
            source: "RAATServer_log.txt"
        )
        engine.ingest(
            events: [event(time: start.addingTimeInterval(6), domain: "playback", type: "playback.buffering", severity: .info, zone: "Kitchen")],
            line: "startup buffering",
            receivedAt: start.addingTimeInterval(6),
            source: "RAATServer_log.txt"
        )
        engine.ingest(
            events: [event(time: start.addingTimeInterval(8), domain: "playback", type: "playback.playing", severity: .info, zone: "Kitchen")],
            line: "playing",
            receivedAt: start.addingTimeInterval(8),
            source: "RAATServer_log.txt"
        )

        let incidents = engine.snapshot(now: start.addingTimeInterval(10), compact: false).incidents.filter { $0.kind == "playback.buffering" }
        XCTAssertEqual(incidents.first { $0.zone == "Office" }?.severity, .warning)
        XCTAssertEqual(incidents.first { $0.zone == "Office" }?.durationSeconds ?? 0, 4, accuracy: 0.1)
        XCTAssertEqual(incidents.first { $0.zone == "Kitchen" }?.severity, .info)
    }

    func testOperationalMetricsAggregateLoadLatencyBacklogAndStorage() throws {
        let engine = DiagnosticAnalysisEngine()
        let now = Date()
        let old = now.addingTimeInterval(-2 * 24 * 60 * 60)
        engine.ingest(
            events: [event(time: old, domain: "metadata", type: "metadata.backlog", severity: .info, value: 100, unit: "items")],
            line: "metadata backlog 100",
            receivedAt: old,
            source: "RoonServer_log.txt"
        )
        engine.ingest(
            events: [event(time: now.addingTimeInterval(-600), domain: "metadata", type: "metadata.backlog", severity: .info, value: 2_000, unit: "items")],
            line: "metadata backlog 2000",
            receivedAt: now.addingTimeInterval(-600),
            source: "RoonServer_log.txt"
        )
        for index in 0..<5 {
            let time = now.addingTimeInterval(Double(index - 5))
            engine.ingest(
                events: [event(time: time, domain: "database", type: "database.latency", severity: .info, value: 140, unit: "ms")],
                line: "[dbperf] flush in 140 ms",
                receivedAt: time,
                source: "RoonServer_log.txt"
            )
        }
        engine.ingest(
            events: [event(time: now.addingTimeInterval(-3), domain: "extension", type: "extension.traffic", severity: .info, value: 25 * 1_048_576, zone: "192.0.2.20", unit: "bytes")],
            line: "[roonapi] large update",
            receivedAt: now.addingTimeInterval(-3),
            source: "RoonServer_log.txt"
        )
        for index in 0..<3 {
            let time = now.addingTimeInterval(Double(index - 3))
            engine.ingest(
                events: [event(
                    time: time,
                    domain: "remote",
                    type: "service.http",
                    severity: .info,
                    value: 300,
                    zone: "Roon Remote",
                    unit: "ms",
                    message: "GET to https://porttest.roonlabs.net returned after 300 ms, status code: 504"
                )],
                line: "Roon Remote status code: 504",
                receivedAt: time,
                source: "RoonServer_log.txt"
            )
        }
        engine.ingest(
            events: [event(time: now.addingTimeInterval(-1), domain: "storage", type: "storage.scan.completed", severity: .info, value: 45_000, zone: "Music", unit: "ms")],
            line: "initial scan took 45000 ms",
            receivedAt: now.addingTimeInterval(-1),
            source: "RoonServer_log.txt"
        )

        let snapshot = engine.snapshot(now: now, compact: false)
        XCTAssertEqual(snapshot.metrics.first { $0.kind == "metadata.backlog" }?.severity, .warning)
        XCTAssertEqual(snapshot.metrics.first { $0.kind == "database.flush" }?.severity, .warning)
        XCTAssertEqual(snapshot.metrics.first { $0.kind == "extension.load" }?.severity, .warning)
        XCTAssertEqual(snapshot.metrics.first { $0.kind == "storage.scan" }?.severity, .warning)
        XCTAssertEqual(snapshot.metrics.first { $0.kind == "service.latency" }?.severity, .info)
        XCTAssertEqual(snapshot.incidents.first { $0.kind == "service.http" }?.severity, .info)
    }

    func testRuntimeStoreRedactsSecretsFromLogsAlertsAndEvidence() throws {
        let store = RuntimeStore()
        let secretLine = "Critical: token=super-secret authorization=Bearer-secret user_id=ABCDEF123456 user@example.com \(NSHomeDirectory())/Music"
        let rawEvent = RuntimeEvent(
            id: UUID().uuidString,
            time: Date(),
            domain: "server",
            type: "server.exception",
            severity: .critical,
            title: "Server exception",
            message: secretLine,
            source: "RoonServer/RoonServer_log.txt",
            valueMB: nil,
            zone: nil
        )
        store.ingest(file: "/tmp/RoonServer_log.txt", line: secretLine, events: [rawEvent], mode: .live)

        let snapshot = store.snapshot()
        let exportedText = [
            snapshot.recentLogs.first?.text,
            snapshot.alerts.first?.message,
            snapshot.diagnostics.incidents.first?.evidence.first?.message
        ].compactMap { $0 }.joined(separator: "\n")
        XCTAssertFalse(exportedText.contains("super-secret"))
        XCTAssertFalse(exportedText.contains("Bearer-secret"))
        XCTAssertFalse(exportedText.contains("ABCDEF123456"))
        XCTAssertFalse(exportedText.contains("user@example.com"))
        XCTAssertFalse(exportedText.contains(NSHomeDirectory()))
        XCTAssertTrue(exportedText.contains("[redacted]"))
    }

    func testAdaptiveBaselineProducesExplainableSlowMemoryPrediction() {
        let engine = DiagnosticAnalysisEngine()
        let start = Date().addingTimeInterval(-50 * 60)
        for index in 0..<50 {
            let value = index < 20 ? 800.0 : 800.0 + Double(index - 19) * 24
            let time = start.addingTimeInterval(Double(index) * 60)
            engine.ingest(
                events: [event(time: time, domain: "memory", type: "memory.sample.detected", severity: .info, title: "Physical Memory", value: value)],
                line: "[stats] \(value) MB Physical",
                receivedAt: time,
                source: "RoonServer_log.txt"
            )
        }

        let snapshot = engine.snapshot(now: start.addingTimeInterval(50 * 60), compact: false)
        let prediction = snapshot.predictions.first { $0.kind == "memory.growth" }
        XCTAssertNotNil(prediction)
        XCTAssertGreaterThan(prediction?.confidence ?? 0, 0.5)
        XCTAssertGreaterThan(prediction?.changePerHour ?? 0, 100)
        XCTAssertGreaterThan(snapshot.baseline.sampleCount, 20)
        XCTAssertFalse(prediction?.evidence.isEmpty ?? true)
    }

    func testAdaptiveDiagnosticStatePersistsAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoonDiagnostics-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("memory-insights.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let parser = LogParser()
        let store = RuntimeStore(memoryInsightStoreURL: url)
        let line = statsLine(at: Date(), physical: 920, managed: 710, native: -20)
        store.ingest(file: "/tmp/RoonServer_log.txt", line: line, events: parser.parse(file: "/tmp/RoonServer_log.txt", line: line), mode: .live)
        let library = "\(timestamp(Date())) Info: [library stats] tracks: 36000, albums: 1500"
        store.ingest(file: "/tmp/RoonServer_log.txt", line: library, events: parser.parse(file: "/tmp/RoonServer_log.txt", line: library), mode: .live)
        store.flushPersistence()

        let restored = RuntimeStore(memoryInsightStoreURL: url)
        let diagnostics = restored.snapshot().diagnostics
        XCTAssertEqual(diagnostics.telemetry.physicalMemoryMB, 920)
        XCTAssertGreaterThan(diagnostics.baseline.sampleCount, 0)
        XCTAssertEqual(diagnostics.baseline.physicalMemoryMB, 920)
        XCTAssertEqual(diagnostics.metrics.first { $0.kind == "library.size" }?.latestValue, 36_000)
    }

    private func event(
        time: Date,
        domain: String,
        type: String,
        severity: Severity,
        title: String? = nil,
        value: Double? = nil,
        zone: String? = nil,
        unit: String? = nil,
        message: String? = nil
    ) -> RuntimeEvent {
        RuntimeEvent(
            id: UUID().uuidString,
            time: time,
            domain: domain,
            type: type,
            severity: severity,
            title: title ?? type,
            message: message ?? "[\(zone ?? domain)] \(type)",
            source: "RoonServer/RoonServer_log.txt",
            valueMB: domain == "memory" ? value : nil,
            zone: zone,
            numericValue: value,
            unit: value == nil ? nil : (unit ?? "MB")
        )
    }

    private func statsLine(at date: Date, physical: Int, managed: Int, native: Int) -> String {
        "\(timestamp(date)) Info: [stats] 428491mb Virtual; \(physical)mb Physical = 1280mb GC-committed (\(managed)mb Managed-live = 70% of committed) + \(native)mb Native; 0,18% of runtime in GC pauses, 20ms GC pause in last window (0,14% of window)"
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
