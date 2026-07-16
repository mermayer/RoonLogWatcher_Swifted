import Foundation

final class DiagnosticAnalysisEngine {
    private var telemetry = RoonRuntimeTelemetry()
    private var incidentsByID: [String: DiagnosticIncident] = [:]
    private var incidentOrder: [String] = []
    private var activeIncidentIDs: [String: String] = [:]
    private var observations = BoundedArray<DiagnosticObservation>(limit: 10_080)
    private var metricBuckets: [String: DiagnosticMetricBucket] = [:]
    private var baselineState = DiagnosticBaselineState()
    private var extensionNames: [String: String] = [:]
    private var playbackStates: [String: PlaybackActivityState] = [:]
    private var lastSuccessfulBackupAt: Date?
    private var lastTelemetryObservationAt = Date.distantPast
    private var lastSystemObservationAt = Date.distantPast
    private var revision = 0
    private var cachedSnapshot: (revision: Int, validUntil: Date, value: DiagnosticAnalysisSnapshot)?
    private let retention: TimeInterval = 7 * 24 * 60 * 60
    private let observationInterval: TimeInterval = 60

    func ingest(events: [RuntimeEvent], line: String, receivedAt: Date, source: String) {
        guard !events.isEmpty else { return }
        for event in events {
            updateTelemetry(from: event)
            updateIncident(from: event, line: line)
            recordMetric(from: event)
        }
        captureTelemetryObservation(at: events.first?.time ?? receivedAt)
        invalidate()
    }

    func updateSystem(_ status: LocalSystemStatus) {
        let diskIO = (status.totalDiskReadRateMBps ?? 0) + (status.totalDiskWriteRateMBps ?? 0)
        guard status.sampledAt.timeIntervalSince(lastSystemObservationAt) >= observationInterval else { return }
        lastSystemObservationAt = status.sampledAt
        appendObservation(DiagnosticObservation(
            time: status.sampledAt,
            physicalMemoryMB: nil,
            processMemoryMB: status.totalMemoryMB,
            cpuPercent: status.totalCPUPercent,
            openFiles: status.openFileCount.map(Double.init),
            diskIOMBps: diskIO,
            gcPauseWindowPercent: nil
        ))
        invalidate()
    }

    func snapshot(now: Date, compact: Bool) -> DiagnosticAnalysisSnapshot {
        updateQuietIncidentStates(now: now)
        if let cachedSnapshot,
           cachedSnapshot.revision == revision,
           now < cachedSnapshot.validUntil {
            return compact ? compactSnapshot(cachedSnapshot.value) : cachedSnapshot.value
        }

        prune(now: now)
        let incidents = visibleIncidents(now: now)
        let metrics = metricSummaries(now: now)
        let value = DiagnosticAnalysisSnapshot(
            telemetry: telemetry,
            baseline: baselineState.snapshot(),
            metrics: metrics,
            metricTotalCount: metrics.count,
            incidents: incidents,
            incidentTotalCount: incidents.count,
            activeIncidentCount: incidents.filter { $0.state != .resolved }.count,
            predictions: predictions(now: now, incidents: incidents, metrics: metrics)
        )
        cachedSnapshot = (revision, now.addingTimeInterval(30), value)
        return compact ? compactSnapshot(value) : value
    }

    func incidentCollection(now: Date) -> [DiagnosticIncident] {
        updateQuietIncidentStates(now: now)
        prune(now: now)
        return visibleIncidents(now: now)
    }

    func metricCollection(now: Date) -> [DiagnosticMetricSummary] {
        prune(now: now)
        return metricSummaries(now: now)
    }

    func persistenceState(now: Date) -> DiagnosticPersistenceState {
        var buckets: [Int: DiagnosticObservation] = [:]
        for observation in observations.items where observation.time >= now.addingTimeInterval(-retention) {
            let bucket = Int(observation.time.timeIntervalSince1970 / 300)
            if var existing = buckets[bucket] {
                existing.time = max(existing.time, observation.time)
                existing.physicalMemoryMB = observation.physicalMemoryMB ?? existing.physicalMemoryMB
                existing.processMemoryMB = observation.processMemoryMB ?? existing.processMemoryMB
                existing.cpuPercent = observation.cpuPercent ?? existing.cpuPercent
                existing.openFiles = observation.openFiles ?? existing.openFiles
                existing.diskIOMBps = observation.diskIOMBps ?? existing.diskIOMBps
                existing.gcPauseWindowPercent = observation.gcPauseWindowPercent ?? existing.gcPauseWindowPercent
                buckets[bucket] = existing
            } else {
                buckets[bucket] = observation
            }
        }
        let incidents = visibleIncidents(now: now).map { incident -> DiagnosticIncident in
            var compact = incident
            compact.evidence = incident.evidence.suffix(3).map { evidence in
                var copy = evidence
                copy.message = String(copy.message.prefix(300))
                return copy
            }
            return compact
        }
        return DiagnosticPersistenceState(
            telemetry: telemetry,
            baseline: baselineState,
            observations: buckets.values.sorted { $0.time < $1.time },
            incidents: incidents,
            metricBuckets: metricBuckets.values
                .filter { $0.updatedAt >= now.addingTimeInterval(-retention) }
                .sorted { $0.startedAt < $1.startedAt },
            lastSuccessfulBackupAt: lastSuccessfulBackupAt
        )
    }

    func restore(_ state: DiagnosticPersistenceState) {
        telemetry = state.telemetry
        baselineState = state.baseline
        observations.replace(with: state.observations.sorted { $0.time < $1.time })
        incidentsByID = Dictionary(uniqueKeysWithValues: state.incidents.map { ($0.id, $0) })
        incidentOrder = state.incidents.sorted { $0.startedAt < $1.startedAt }.map(\.id)
        activeIncidentIDs = Dictionary(uniqueKeysWithValues: state.incidents.compactMap { incident in
            incident.state == .resolved ? nil : (incident.correlationKey, incident.id)
        })
        lastTelemetryObservationAt = state.observations.last(where: { $0.physicalMemoryMB != nil })?.time ?? .distantPast
        lastSystemObservationAt = state.observations.last(where: { $0.processMemoryMB != nil || $0.cpuPercent != nil })?.time ?? .distantPast
        metricBuckets = Dictionary(
            uniqueKeysWithValues: (state.metricBuckets ?? []).map { ($0.id, $0) }
        )
        lastSuccessfulBackupAt = state.lastSuccessfulBackupAt
        invalidate()
    }

    private func compactSnapshot(_ snapshot: DiagnosticAnalysisSnapshot) -> DiagnosticAnalysisSnapshot {
        var compact = snapshot
        compact.metrics = Array(snapshot.metrics.prefix(6))
        compact.incidents = Array(snapshot.incidents.prefix(4))
        compact.predictions = Array(snapshot.predictions.prefix(5))
        return compact
    }

    private func updateTelemetry(from event: RuntimeEvent) {
        if event.type == "memory.metric.unavailable", event.title == "Native Memory" {
            telemetry.updatedAt = event.time
            telemetry.nativeMemoryMB = nil
            return
        }
        guard event.domain == "memory" || event.domain == "runtime" else { return }
        let value = event.numericValue ?? event.valueMB
        guard let value else { return }
        telemetry.updatedAt = event.time
        switch event.title {
        case "Virtual Memory": telemetry.virtualMemoryMB = value
        case "Physical Memory": telemetry.physicalMemoryMB = value
        case "GC Committed Memory": telemetry.gcCommittedMB = value
        case "Managed Memory": telemetry.managedLiveMB = value
        case "Native Memory": telemetry.nativeMemoryMB = value
        case "Managed Utilization": telemetry.managedUtilizationPercent = value
        case "GC Pause Runtime": telemetry.gcPauseRuntimePercent = value
        case "GC Pause Window": telemetry.gcPauseWindowMilliseconds = value
        case "GC Pause Window Percent": telemetry.gcPauseWindowPercent = value
        default: break
        }
    }

    private func updateIncident(from event: RuntimeEvent, line: String) {
        switch event.type {
        case "database.maintenance.started":
            upsert(
                key: "database-maintenance",
                kind: "database.maintenance",
                severity: .info,
                title: "Database maintenance",
                summary: "Roon is validating or compacting its database.",
                domains: ["database", "raat", "server"],
                impact: 0,
                event: event,
                line: line
            )
        case "database.maintenance.completed":
            markMonitoring(
                key: "database-maintenance",
                event: event,
                line: line,
                recovery: "Database validation completed; watching the restart grace period."
            )
        case "server.stopped":
            upsert(key: "server-state", kind: "server.lifecycle", severity: .critical, title: "Roon Server stopped", summary: "The latest server state indicates a stop.", domains: ["server", "raat", "playback"], impact: 40, event: event, line: line)
        case "server.started":
            markMonitoring(key: "server-state", event: event, line: line, recovery: "Roon Server started again; watching the warm-up period.")
        case "server.exception":
            upsert(key: "server-exception", kind: "server.exception", severity: .critical, title: "Roon Server exception", summary: "An unhandled or fatal server exception was detected.", domains: ["server"], impact: 42, event: event, line: line)
        case "raat.disconnected":
            if let maintenanceID = activeIncidentIDs["database-maintenance"], incidentsByID[maintenanceID]?.state != .resolved {
                appendEvidence(to: maintenanceID, event: event, line: line)
            } else if let restartID = activeIncidentIDs["server-state"], incidentsByID[restartID]?.state != .resolved {
                appendEvidence(to: restartID, event: event, line: line)
            } else {
                let zone = event.zone ?? "unknown"
                let wasPlaying = playbackStates[zone] == .playing
                upsert(
                    key: "raat:\(zone)",
                    kind: "raat.transport",
                    severity: .info,
                    title: "RAAT transport interruption",
                    summary: wasPlaying
                        ? "A RAAT endpoint disconnected while playback was active; duration and recovery determine severity."
                        : "A RAAT endpoint disconnected while no active playback was known.",
                    domains: ["raat", "playback"],
                    impact: 0,
                    event: event,
                    line: line,
                    details: [wasPlaying ? "Playback active at disconnect" : "No active playback at disconnect"]
                )
            }
        case "raat.connected":
            resolve(key: "raat:\(event.zone ?? "unknown")", event: event, line: line, recovery: "The RAAT endpoint connected again.")
        case "playback.buffering":
            let zone = event.zone ?? "unknown"
            let wasPlaying = playbackStates[zone] == .playing
            upsert(
                key: "buffering:\(zone)",
                kind: "playback.buffering",
                severity: .info,
                title: "Playback buffering",
                summary: wasPlaying
                    ? "Buffering began during active playback; duration determines whether it is actionable."
                    : "A normal playback startup buffer was observed.",
                domains: ["playback", "raat", "streaming"],
                impact: 0,
                event: event,
                line: line,
                details: [wasPlaying ? "Mid-playback buffering" : "Startup buffering"]
            )
            playbackStates[zone] = .buffering
        case "playback.warning.detected":
            let zone = event.zone ?? "unknown"
            upsert(key: "playback:\(zone)", kind: "playback.failure", severity: .warning, title: "Playback interruption", summary: "Playback reported a timeout, failure or network interruption.", domains: ["playback", "raat"], impact: 10, event: event, line: line)
        case "playback.playing":
            let zone = event.zone ?? "unknown"
            resolve(key: "buffering:\(zone)", event: event, line: line, recovery: "Playback resumed after buffering.")
            resolve(key: "playback:\(zone)", event: event, line: line, recovery: "Playback is running again.")
            playbackStates[zone] = .playing
        case "playback.stopped":
            playbackStates[event.zone ?? "unknown"] = .idle
        case "database.critical":
            upsert(key: "database-failure", kind: "database.failure", severity: .critical, title: "Database integrity risk", summary: "Roon reported database corruption or an unrecoverable database error.", domains: ["database", "server"], impact: 42, event: event, line: line)
        case "database.warning":
            upsert(key: "database-failure", kind: "database.failure", severity: .warning, title: "Database access failure", summary: "Roon could not complete a database operation.", domains: ["database"], impact: 16, event: event, line: line)
        case "database.recovered":
            resolve(key: "database-failure", event: event, line: line, recovery: "A subsequent database operation completed successfully.")
        case "extension.identified":
            let client = event.zone ?? Self.endpointKey(event.message)
            if let name = Self.extensionName(event.message) {
                extensionNames[client] = name
            }
        case "extension.response_race":
            let client = event.zone ?? "unknown"
            upsert(
                key: "extension-response-race:\(client)",
                kind: "extension.response_race",
                severity: .info,
                title: "Roon API response race",
                summary: "Roon logged a non-fatal duplicate final-response exception. Core playback remains available.",
                domains: ["extension"],
                impact: 0,
                event: event,
                line: line
            )
        case "extension.timeout", "extension.disconnected":
            let client = event.zone ?? Self.endpointKey(event.message)
            upsert(key: "extension:\(client)", kind: "extension.connection", severity: .info, title: "Roon API client disconnected", summary: "A Roon extension connection timed out; Roon Core remains available.", domains: ["extension"], impact: 0, event: event, line: line)
        case "extension.connected":
            resolve(key: "extension:\(event.zone ?? Self.endpointKey(event.message))", event: event, line: line, recovery: "The Roon API client connected again.")
        case "extension.sync":
            let client = event.zone ?? Self.endpointKey(event.message)
            upsert(
                key: "extension-sync:\(client)",
                kind: "extension.sync",
                severity: .info,
                title: extensionNames[client].map { "\($0) synchronization" } ?? "Roon API state synchronization",
                summary: "An extension subscribed to zones or queues and received a potentially large state payload.",
                domains: ["extension", "memory"],
                impact: 0,
                event: event,
                line: line
            )
        case "backup.started":
            upsert(key: "backup-run", kind: "backup.run", severity: .info, title: "Roon backup", summary: "A Roon database backup is in progress.", domains: ["backup", "memory", "database", "storage"], impact: 0, event: event, line: line)
        case "backup.progress":
            updateActiveIncidentMetrics(key: "backup-run", event: event, line: line)
        case "backup.finalizing":
            updateActiveIncidentMetrics(key: "backup-run", event: event, line: line)
        case "backup.completed":
            resolve(key: "backup-run", event: event, line: line, recovery: "The Roon backup completed successfully.")
        case "backup.failed":
            upsert(key: "backup-run", kind: "backup.run", severity: .warning, title: "Roon backup failed", summary: "Roon could not complete its backup.", domains: ["backup", "storage"], impact: 10, event: event, line: line)
        case "metadata.refresh.started":
            upsert(key: "metadata-refresh", kind: "metadata.refresh", severity: .info, title: "Metadata full refresh", summary: "Roon is processing a full metadata refresh.", domains: ["metadata", "memory", "database", "storage"], impact: 0, event: event, line: line)
        case "metadata.refresh.progress":
            updateActiveIncidentMetrics(key: "metadata-refresh", event: event, line: line)
        case "metadata.refresh.completed":
            resolve(key: "metadata-refresh", event: event, line: line, recovery: "The metadata refresh queue reached zero.")
        case "storage.scan.started":
            upsert(key: "storage-scan:\(event.zone ?? "unknown")", kind: "storage.scan", severity: .info, title: "Storage scan", summary: "Roon is scanning a watched storage location.", domains: ["storage", "memory", "database"], impact: 0, event: event, line: line)
        case "storage.scan.completed":
            let storage = event.zone ?? "unknown"
            resolve(key: "storage-scan:\(storage)", event: event, line: line, recovery: "The storage scan completed.")
            resolve(key: "storage-unavailable:\(storage)", event: event, line: line, recovery: "The storage location is reachable again.")
        case "storage.unavailable":
            upsert(key: "storage-unavailable:\(event.zone ?? "unknown")", kind: "storage.unavailable", severity: .warning, title: "Storage location unavailable", summary: "A watched Roon storage location could not be reached.", domains: ["storage", "playback", "library"], impact: 14, event: event, line: line)
        case "service.sync.started":
            upsert(key: "service-sync:\(event.zone ?? "unknown")", kind: "service.sync", severity: .info, title: "\(event.zone ?? "Streaming service") library sync", summary: "Roon is synchronizing a streaming-service library.", domains: ["service", "metadata", "memory", "database"], impact: 0, event: event, line: line)
        case "service.sync.completed":
            resolve(key: "service-sync:\(event.zone ?? "unknown")", event: event, line: line, recovery: "The streaming-service library sync completed.")
        case "service.auth.failed":
            upsert(key: "service-auth:\(event.zone ?? "account")", kind: "service.authentication", severity: .info, title: "Streaming account authentication", summary: "Roon is retrying account authentication; duration determines severity.", domains: ["service", "streaming"], impact: 0, event: event, line: line)
        case "service.auth.recovered":
            resolve(key: "service-auth:\(event.zone ?? "account")", event: event, line: line, recovery: "The account returned to LoggedIn state.")
        case "service.http":
            updateServiceHTTPIncident(event: event, line: line)
        case "streaming.quality_warning":
            upsert(key: "streaming-quality", kind: "streaming.delivery", severity: .info, title: "Streaming delivery delay", summary: "Roon observed a temporary downloader delay; repetition and playback impact determine severity.", domains: ["streaming", "playback"], impact: 0, event: event, line: line)
        case "remote.port_mapping.failed":
            upsert(key: "remote-access", kind: "remote.access", severity: .info, title: "Remote access port mapping failed", summary: "Automatic port mapping failed. This matters for Roon ARC or remote access, not local playback.", domains: ["remote"], impact: 0, event: event, line: line)
        case "remote.connectivity.ok":
            resolve(key: "remote-access", event: event, line: line, recovery: "Remote connectivity succeeded again.")
        case "device.cast.authentication":
            upsert(key: "cast:\(event.zone ?? Self.endpointKey(event.message))", kind: "device.cast", severity: .info, title: "Cast device authentication retry", summary: "A Cast endpoint rejected TLS authentication; other Roon functions are unaffected.", domains: ["device"], impact: 0, event: event, line: line)
        default:
            break
        }
    }

    private func upsert(
        key: String,
        kind: String,
        severity: Severity,
        title: String,
        summary: String,
        domains: [String],
        impact: Int,
        event: RuntimeEvent,
        line: String,
        details: [String]? = nil
    ) {
        if let id = activeIncidentIDs[key], var incident = incidentsByID[id] {
            incident.updatedAt = max(incident.updatedAt, event.time)
            incident.eventCount += 1
            incident.state = .active
            incident.resolvedAt = nil
            incident.recoveryMessage = nil
            if severity.rank > incident.severity.rank { incident.severity = severity }
            incident.healthImpact = max(incident.healthImpact, impact)
            incident.evidence = Self.appendingEvidence(incident.evidence, event: event, line: line)
            incident.details = Self.mergedDetails(incident.details, details)
            applyIncidentMetrics(&incident, event: event)
            if incident.kind == "device.cast", incident.eventCount >= 3 {
                incident.severity = .warning
                incident.healthImpact = 6
                incident.summary = "The same Cast endpoint repeatedly rejected TLS authentication."
            }
            incidentsByID[id] = incident
            return
        }

        let id = "\(kind)-\(UUID().uuidString)"
        incidentsByID[id] = DiagnosticIncident(
            id: id,
            correlationKey: key,
            kind: kind,
            state: .active,
            severity: severity,
            title: title,
            summary: summary,
            startedAt: event.time,
            updatedAt: event.time,
            resolvedAt: nil,
            recoveryMessage: nil,
            affectedDomains: domains,
            source: event.source,
            zone: event.zone,
            eventCount: 1,
            healthImpact: impact,
            evidence: Self.appendingEvidence([], event: event, line: line),
            details: details
        )
        if var incident = incidentsByID[id] {
            applyIncidentMetrics(&incident, event: event)
            if Self.isMaintenanceKind(incident.kind),
               incident.baselineValue == nil,
               let memory = telemetry.physicalMemoryMB {
                incident.baselineValue = memory
                incident.unit = "MB"
                incident.details = Self.mergedDetails(incident.details, ["Memory at start: \(Int(memory.rounded())) MB"])
            }
            incidentsByID[id] = incident
        }
        activeIncidentIDs[key] = id
        incidentOrder.append(id)
        trimIncidentHistory()
    }

    private func appendEvidence(to id: String, event: RuntimeEvent, line: String) {
        guard var incident = incidentsByID[id] else { return }
        incident.updatedAt = max(incident.updatedAt, event.time)
        incident.eventCount += 1
        incident.evidence = Self.appendingEvidence(incident.evidence, event: event, line: line)
        incidentsByID[id] = incident
    }

    private func markMonitoring(key: String, event: RuntimeEvent, line: String, recovery: String) {
        guard let id = activeIncidentIDs[key], var incident = incidentsByID[id] else { return }
        incident.state = .monitoring
        incident.updatedAt = max(incident.updatedAt, event.time)
        incident.recoveryMessage = recovery
        incident.evidence = Self.appendingEvidence(incident.evidence, event: event, line: line)
        incidentsByID[id] = incident
    }

    private func resolve(key: String, event: RuntimeEvent, line: String, recovery: String) {
        guard let id = activeIncidentIDs.removeValue(forKey: key), var incident = incidentsByID[id] else { return }
        classifyIncident(&incident, at: event.time)
        incident.state = .resolved
        incident.updatedAt = max(incident.updatedAt, event.time)
        incident.resolvedAt = event.time
        incident.durationSeconds = max(0, event.time.timeIntervalSince(incident.startedAt))
        incident.recoveryMessage = recovery
        incident.evidence = Self.appendingEvidence(incident.evidence, event: event, line: line)
        applyIncidentMetrics(&incident, event: event)
        if Self.isMaintenanceKind(incident.kind),
           let memory = telemetry.physicalMemoryMB {
            incident.currentValue = memory
            incident.unit = "MB"
            if let baseline = incident.baselineValue {
                let delta = memory - baseline
                incident.details = Self.mergedDetails(
                    incident.details,
                    ["Memory at completion: \(Int(memory.rounded())) MB", "Memory change: \(Int(delta.rounded())) MB"]
                )
            }
        }
        if incident.kind == "backup.run", incident.severity == .info {
            lastSuccessfulBackupAt = event.time
        }
        incidentsByID[id] = incident
    }

    private func updateActiveIncidentMetrics(key: String, event: RuntimeEvent, line: String) {
        guard let id = activeIncidentIDs[key], var incident = incidentsByID[id] else { return }
        incident.updatedAt = max(incident.updatedAt, event.time)
        incident.eventCount += 1
        applyIncidentMetrics(&incident, event: event)
        if incident.evidence.count < 2
            || event.type.hasSuffix(".completed")
            || event.type.hasSuffix(".failed")
        {
            incident.evidence = Self.appendingEvidence(incident.evidence, event: event, line: line)
        }
        incidentsByID[id] = incident
    }

    private func applyIncidentMetrics(_ incident: inout DiagnosticIncident, event: RuntimeEvent) {
        incident.durationSeconds = max(0, event.time.timeIntervalSince(incident.startedAt))
        guard let value = event.numericValue else { return }
        if event.unit == "bytes" {
            let bytes = max(0, Int(value.rounded()))
            if event.type == "backup.progress" {
                incident.dataBytes = max(incident.dataBytes ?? 0, bytes)
            } else {
                incident.dataBytes = (incident.dataBytes ?? 0) + bytes
            }
            return
        }
        if incident.baselineValue == nil {
            incident.baselineValue = value
        }
        incident.currentValue = value
        incident.unit = event.unit
    }

    private func classifyIncident(_ incident: inout DiagnosticIncident, at now: Date) {
        let duration = max(0, now.timeIntervalSince(incident.startedAt))
        incident.durationSeconds = duration
        switch incident.kind {
        case "raat.transport":
            let playbackActive = incident.details?.contains("Playback active at disconnect") == true
            if playbackActive && duration >= 10 {
                incident.severity = duration >= 60 ? .critical : .warning
                incident.healthImpact = duration >= 60 ? 22 : 12
                incident.summary = "RAAT remains disconnected during active playback."
            } else {
                incident.severity = .info
                incident.healthImpact = 0
                incident.summary = playbackActive
                    ? "RAAT recovered before the interruption became long enough to affect health."
                    : "RAAT disconnected while the endpoint was idle or powered off."
            }
        case "playback.buffering":
            let midPlayback = incident.details?.contains("Mid-playback buffering") == true
            let warningThreshold = midPlayback ? 3.0 : 5.0
            if duration >= warningThreshold {
                incident.severity = duration >= 15 ? .critical : .warning
                incident.healthImpact = duration >= 15 ? 18 : 8
                incident.summary = "\(midPlayback ? "Mid-playback" : "Startup") buffering exceeded the normal recovery threshold."
            } else {
                incident.severity = .info
                incident.healthImpact = 0
                incident.summary = "Buffering remains within the normal startup or recovery window."
            }
        case "service.authentication":
            if duration >= 60 {
                incident.severity = .warning
                incident.healthImpact = 8
                incident.summary = "Account authentication has remained unavailable for more than one minute."
            } else {
                incident.severity = .info
                incident.healthImpact = 0
                incident.summary = "The authentication retry remains within the normal recovery window."
            }
        case "extension.connection":
            if incident.eventCount >= 6, duration <= 15 * 60 {
                incident.severity = .warning
                incident.healthImpact = 4
                incident.summary = "The same Roon API client is repeatedly reconnecting."
            }
        case "streaming.delivery":
            if incident.eventCount >= 3 {
                incident.severity = .warning
                incident.healthImpact = 6
                incident.summary = "Repeated streaming downloader delays were detected."
            }
        case "service.http":
            let remoteOnly = incident.details?.contains("Remote-only service") == true
            if incident.eventCount >= 3, !remoteOnly {
                incident.severity = .warning
                incident.healthImpact = 6
                incident.summary = "The same external service returned repeated server errors."
            } else if remoteOnly {
                incident.severity = .info
                incident.healthImpact = 0
            }
        case "backup.run":
            if incident.state != .resolved && duration >= 15 * 60 {
                incident.severity = .warning
                incident.healthImpact = 8
                incident.summary = "The backup has been running for more than 15 minutes without a completion marker."
            }
        default:
            break
        }
    }

    private func updateServiceHTTPIncident(event: RuntimeEvent, line: String) {
        let provider = event.zone ?? "Network service"
        guard let status = Self.httpStatusCode(event.message) else { return }
        let key = "service-http:\(provider)"
        if (200..<500).contains(status) {
            resolve(key: key, event: event, line: line, recovery: "\(provider) requests are succeeding again.")
            return
        }
        guard status >= 500 else { return }
        let remoteOnly = provider == "Roon Remote"
        upsert(
            key: key,
            kind: "service.http",
            severity: .info,
            title: "\(provider) service errors",
            summary: remoteOnly
                ? "Roon Remote connectivity returned a server error; local playback is unaffected."
                : "An external Roon service returned a server error; repetition determines severity.",
            domains: remoteOnly ? ["remote"] : ["service", "streaming"],
            impact: 0,
            event: event,
            line: line,
            details: remoteOnly ? ["HTTP \(status)", "Remote-only service"] : ["HTTP \(status)"]
        )
    }

    private func updateQuietIncidentStates(now: Date) {
        var changed = false
        var resolvedKeys: [String] = []
        for (key, id) in activeIncidentIDs {
            guard var incident = incidentsByID[id] else { continue }
            let quiet = now.timeIntervalSince(incident.updatedAt)
            let previousSeverity = incident.severity
            let previousImpact = incident.healthImpact
            let previousSummary = incident.summary
            classifyIncident(&incident, at: now)
            if incident.severity != previousSeverity
                || incident.healthImpact != previousImpact
                || incident.summary != previousSummary
            {
                incidentsByID[id] = incident
                changed = true
            }
            let timeout = Self.quietTimeout(for: incident.kind)
            if quiet >= timeout {
                classifyIncident(&incident, at: incident.updatedAt.addingTimeInterval(timeout))
                incident.state = .resolved
                incident.resolvedAt = incident.updatedAt.addingTimeInterval(timeout)
                incident.recoveryMessage = incident.recoveryMessage ?? "No further matching errors occurred during the recovery window."
                incidentsByID[id] = incident
                resolvedKeys.append(key)
                changed = true
            } else if quiet >= timeout / 2, incident.state == .active {
                incident.state = .monitoring
                incident.recoveryMessage = "No repeat detected; monitoring recovery."
                incidentsByID[id] = incident
                changed = true
            }
        }
        for key in resolvedKeys { activeIncidentIDs[key] = nil }
        if changed { invalidate() }
    }

    private func captureTelemetryObservation(at time: Date) {
        guard time.timeIntervalSince(lastTelemetryObservationAt) >= observationInterval else { return }
        lastTelemetryObservationAt = time
        appendObservation(DiagnosticObservation(
            time: time,
            physicalMemoryMB: telemetry.physicalMemoryMB,
            processMemoryMB: nil,
            cpuPercent: nil,
            openFiles: nil,
            diskIOMBps: nil,
            gcPauseWindowPercent: telemetry.gcPauseWindowPercent
        ))
    }

    private func appendObservation(_ observation: DiagnosticObservation) {
        observations.append(observation)
        if !hasActiveHealthIncident {
            baselineState.update(observation)
        }
    }

    private var hasActiveHealthIncident: Bool {
        activeIncidentIDs.values.contains { id in
            guard let incident = incidentsByID[id] else { return false }
            return incident.state == .active && incident.healthImpact > 0
        }
    }

    private func visibleIncidents(now: Date) -> [DiagnosticIncident] {
        let cutoff = now.addingTimeInterval(-retention)
        return incidentOrder.reversed().compactMap { id in
            guard var incident = incidentsByID[id], incident.updatedAt >= cutoff else { return nil }
            if incident.state != .resolved {
                incident.durationSeconds = max(0, now.timeIntervalSince(incident.startedAt))
            }
            return incident
        }.sorted {
            if $0.state != $1.state { return $0.state.sortRank < $1.state.sortRank }
            if $0.severity.rank != $1.severity.rank { return $0.severity.rank > $1.severity.rank }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func recordMetric(from event: RuntimeEvent) {
        let descriptor: (kind: String, entity: String, value: Double?, unit: String?, bytes: Int, failure: Bool)?
        switch event.type {
        case "extension.traffic", "extension.sync":
            let endpoint = event.zone ?? Self.endpointKey(event.message)
            descriptor = (
                "extension.load",
                extensionNames[endpoint] ?? endpoint,
                nil,
                nil,
                max(0, Int((event.numericValue ?? 0).rounded())),
                false
            )
        case "service.http":
            let status = Self.httpStatusCode(event.message) ?? 0
            descriptor = (
                "service.latency",
                event.zone ?? "Network service",
                event.numericValue,
                "ms",
                0,
                status >= 500
            )
        case "streaming.download":
            descriptor = ("streaming.throughput", event.zone ?? "Streaming media", event.numericValue, "kbps", 0, false)
        case "streaming.quality_warning":
            descriptor = ("streaming.quality", event.zone ?? "Streaming media", nil, nil, 0, true)
        case "metadata.backlog":
            descriptor = ("metadata.backlog", "Roon metadata", event.numericValue, "items", 0, false)
        case "database.latency":
            descriptor = ("database.flush", "Roon database", event.numericValue, "ms", 0, false)
        case "database.mutation":
            descriptor = ("database.mutation", "Roon library", event.numericValue, "ms", 0, false)
        case "storage.scan.completed":
            descriptor = ("storage.scan", event.zone ?? "Storage", event.numericValue, "ms", 0, false)
        case "storage.unavailable":
            descriptor = ("storage.availability", event.zone ?? "Storage", nil, nil, 0, true)
        case "library.stats":
            descriptor = ("library.size", "Roon library", event.numericValue, event.unit, 0, false)
        default:
            descriptor = nil
        }
        guard let descriptor else { return }

        let bucketStart = floor(event.time.timeIntervalSince1970 / 300) * 300
        let id = "\(descriptor.kind)|\(descriptor.entity)|\(Int(bucketStart))"
        var bucket = metricBuckets[id] ?? DiagnosticMetricBucket(
            id: id,
            kind: descriptor.kind,
            entity: descriptor.entity,
            startedAt: Date(timeIntervalSince1970: bucketStart),
            updatedAt: event.time,
            count: 0,
            failureCount: 0,
            totalBytes: 0,
            valueCount: 0,
            totalValue: 0,
            minimumValue: nil,
            maximumValue: nil,
            latestValue: nil,
            unit: descriptor.unit
        )
        bucket.updatedAt = max(bucket.updatedAt, event.time)
        bucket.count += 1
        bucket.failureCount += descriptor.failure ? 1 : 0
        bucket.totalBytes += descriptor.bytes
        if let value = descriptor.value, value.isFinite {
            bucket.valueCount += 1
            bucket.totalValue += value
            bucket.minimumValue = min(bucket.minimumValue ?? value, value)
            bucket.maximumValue = max(bucket.maximumValue ?? value, value)
            bucket.latestValue = value
            bucket.unit = descriptor.unit
        }
        metricBuckets[id] = bucket
        if metricBuckets.count > 20_000 {
            let oldest = metricBuckets.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(1_000)
            for bucket in oldest { metricBuckets[bucket.id] = nil }
        }
    }

    private func metricSummaries(now: Date) -> [DiagnosticMetricSummary] {
        let currentCutoff = now.addingTimeInterval(-24 * 60 * 60)
        let baselineCutoff = now.addingTimeInterval(-retention)
        let recentBuckets = metricBuckets.values.filter { $0.updatedAt >= currentCutoff && $0.updatedAt <= now }
        let grouped = Dictionary(grouping: recentBuckets, by: { "\($0.kind)|\($0.entity)" })

        var summaries: [DiagnosticMetricSummary] = grouped.compactMap { element -> DiagnosticMetricSummary? in
            let (key, buckets) = element
            guard let latest = buckets.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
            let history = metricBuckets.values.filter {
                $0.kind == latest.kind
                    && $0.entity == latest.entity
                    && $0.updatedAt >= baselineCutoff
                    && $0.updatedAt < currentCutoff
            }
            return makeMetricSummary(
                id: key,
                kind: latest.kind,
                entity: latest.entity,
                buckets: buckets,
                history: history,
                now: now
            )
        }
        if let lastSuccessfulBackupAt {
            let ageDays = max(0, now.timeIntervalSince(lastSuccessfulBackupAt) / 86_400)
            summaries.append(DiagnosticMetricSummary(
                id: "backup.status",
                kind: "backup.status",
                entity: "Roon backup",
                severity: ageDays >= 8 ? .warning : .info,
                title: "Roon backup status",
                summary: "The last successful Roon backup completed \(String(format: "%.1f", ageDays)) day(s) ago.",
                observedAt: lastSuccessfulBackupAt,
                windowMinutes: ageDays * 24 * 60,
                sampleCount: 1,
                failureCount: 0,
                totalBytes: nil,
                averageValue: nil,
                maximumValue: nil,
                latestValue: ageDays,
                baselineValue: nil,
                changeValue: nil,
                unit: "days",
                details: ["A warning appears after eight days without another successful backup"]
            ))
        }
        return summaries.sorted {
            if $0.severity.rank != $1.severity.rank { return $0.severity.rank > $1.severity.rank }
            return $0.observedAt > $1.observedAt
        }
    }

    private func makeMetricSummary(
        id: String,
        kind: String,
        entity: String,
        buckets: [DiagnosticMetricBucket],
        history: [DiagnosticMetricBucket],
        now: Date
    ) -> DiagnosticMetricSummary {
        let count = buckets.reduce(0) { $0 + $1.count }
        let failures = buckets.reduce(0) { $0 + $1.failureCount }
        let bytes = buckets.reduce(0) { $0 + $1.totalBytes }
        let valueCount = buckets.reduce(0) { $0 + $1.valueCount }
        let totalValue = buckets.reduce(0) { $0 + $1.totalValue }
        let average = valueCount > 0 ? totalValue / Double(valueCount) : nil
        let maximum = buckets.compactMap(\.maximumValue).max()
        let latestBucket = buckets.max { $0.updatedAt < $1.updatedAt }
        let latest = latestBucket?.latestValue
        let historyValueCount = history.reduce(0) { $0 + $1.valueCount }
        let baseline = historyValueCount > 0
            ? history.reduce(0) { $0 + $1.totalValue } / Double(historyValueCount)
            : nil
        let change = latest.flatMap { value in baseline.map { value - $0 } }
        let oneHour = buckets.filter { $0.updatedAt >= now.addingTimeInterval(-60 * 60) }
        let hourCount = oneHour.reduce(0) { $0 + $1.count }
        let hourBytes = oneHour.reduce(0) { $0 + $1.totalBytes }
        let hourFailures = oneHour.reduce(0) { $0 + $1.failureCount }
        let maintenance = hasActiveMaintenance

        var severity: Severity = .info
        var title = entity
        var summary = "\(count) sample(s) during the last 24 hours."
        var details: [String] = []
        switch kind {
        case "extension.load":
            title = "\(entity) API load"
            severity = hourBytes >= 20 * 1_048_576 || hourCount >= 2_000 ? .warning : .info
            summary = "\(count) API update(s) transferred \(Self.formattedBytes(bytes)) during the last 24 hours."
            details = ["Last hour: \(hourCount) updates", "Last hour: \(Self.formattedBytes(hourBytes))"]
        case "service.latency":
            title = "\(entity) service health"
            let slow = (average ?? 0) >= 2_000 || (maximum ?? 0) >= 10_000
            severity = entity == "Roon Remote"
                ? .info
                : (hourFailures >= 3 || slow ? .warning : .info)
            summary = "\(count) request(s), \(failures) server error(s), average \(Int((average ?? 0).rounded())) ms."
            details = ["Maximum: \(Int((maximum ?? 0).rounded())) ms", "Last hour errors: \(hourFailures)"]
        case "streaming.throughput":
            title = "Streaming throughput"
            severity = valueCount >= 3 && (average ?? .greatestFiniteMagnitude) < 1_500 ? .warning : .info
            summary = "Average download speed \(Int((average ?? 0).rounded())) kbps across \(valueCount) transfer(s)."
            details = ["Minimum and maximum are retained in five-minute buckets", "Maximum: \(Int((maximum ?? 0).rounded())) kbps"]
        case "streaming.quality":
            title = "Streaming delivery notices"
            severity = failures >= 3 ? .warning : .info
            summary = "\(failures) downloader delay notice(s) occurred during the last 24 hours."
            details = ["Warnings require repeated notices or a correlated playback interruption"]
        case "metadata.backlog":
            title = "Metadata backlog"
            let growth = change ?? 0
            severity = growth > max(1_000, (baseline ?? 0) * 0.25) ? .warning : .info
            summary = "\(Int((latest ?? 0).rounded())) metadata item(s) are pending."
            details = baseline.map { ["Seven-day baseline: \(Int($0.rounded())) items", "Change: \(Int(growth.rounded())) items"] }
                ?? ["Learning a seven-day baseline"]
        case "database.flush":
            title = "Database flush latency"
            severity = !maintenance && valueCount >= 5 && (average ?? 0) >= 100 ? .warning : .info
            summary = "Average \(Int((average ?? 0).rounded())) ms, maximum \(Int((maximum ?? 0).rounded())) ms across \(valueCount) flushes."
            details = [maintenance ? "Elevated values are correlated with maintenance" : "No active maintenance context"]
        case "database.mutation":
            title = "Library mutation latency"
            severity = !maintenance && valueCount >= 5 && (average ?? 0) >= 500 ? .warning : .info
            summary = "Average \(Int((average ?? 0).rounded())) ms, maximum \(Int((maximum ?? 0).rounded())) ms across \(valueCount) mutations."
            details = [maintenance ? "Elevated values are correlated with maintenance" : "Sustained latency is weighted more than isolated peaks"]
        case "storage.scan":
            title = "\(entity) scan duration"
            let threshold = max(30_000, (baseline ?? 0) * 2)
            severity = (latest ?? 0) > threshold ? .warning : .info
            summary = "Latest scan \(String(format: "%.1f", (latest ?? 0) / 1_000)) seconds."
            details = baseline.map { ["Seven-day baseline: \(String(format: "%.1f", $0 / 1_000)) seconds"] }
                ?? ["Learning a seven-day baseline"]
        case "storage.availability":
            title = "\(entity) availability"
            severity = failures > 0 ? .warning : .info
            summary = "\(failures) unavailable-storage event(s) occurred during the last 24 hours."
        case "library.size":
            title = "Roon library size"
            severity = .info
            summary = "\(Int((latest ?? 0).rounded())) tracks are currently reported."
            details = change.map { ["Change from learned baseline: \(Int($0.rounded())) tracks"] }
                ?? ["Learning a seven-day baseline"]
        default:
            break
        }

        return DiagnosticMetricSummary(
            id: id,
            kind: kind,
            entity: entity,
            severity: severity,
            title: title,
            summary: summary,
            observedAt: latestBucket?.updatedAt ?? now,
            windowMinutes: 24 * 60,
            sampleCount: count,
            failureCount: failures,
            totalBytes: bytes > 0 ? bytes : nil,
            averageValue: average,
            maximumValue: maximum,
            latestValue: latest,
            baselineValue: baseline,
            changeValue: change,
            unit: latestBucket?.unit,
            details: details
        )
    }

    private var hasActiveMaintenance: Bool {
        let maintenanceKinds: Set<String> = [
            "database.maintenance",
            "backup.run",
            "metadata.refresh",
            "storage.scan",
            "service.sync"
        ]
        return activeIncidentIDs.values.contains { id in
            guard let incident = incidentsByID[id] else { return false }
            return incident.state != .resolved && maintenanceKinds.contains(incident.kind)
        }
    }

    private func predictions(
        now: Date,
        incidents: [DiagnosticIncident],
        metrics: [DiagnosticMetricSummary]
    ) -> [DiagnosticPrediction] {
        let points = observations.items.filter { $0.time >= now.addingTimeInterval(-24 * 60 * 60) }
        var results: [DiagnosticPrediction] = []
        if let prediction = memoryPrediction(now: now, points: points) { results.append(prediction) }
        if let prediction = gcPrediction(now: now, points: points) { results.append(prediction) }
        if let prediction = cpuPrediction(now: now, points: points) { results.append(prediction) }
        if let prediction = openFilePrediction(now: now, points: points) { results.append(prediction) }
        if let prediction = diskPrediction(now: now, points: points) { results.append(prediction) }
        results.append(contentsOf: recurringIncidentPredictions(now: now, incidents: incidents))
        results.append(contentsOf: operationalPredictions(now: now, metrics: metrics, incidents: incidents))
        return results.sorted {
            if $0.severity.rank != $1.severity.rank { return $0.severity.rank > $1.severity.rank }
            return $0.confidence > $1.confidence
        }
    }

    private func memoryPrediction(now: Date, points: [DiagnosticObservation]) -> DiagnosticPrediction? {
        let samples = points.compactMap { point in point.physicalMemoryMB.map { (point.time, $0) } }
        guard let trend = Self.linearTrend(samples: samples, minimumSpan: 30 * 60),
              let current = samples.last?.1,
              let baseline = baselineState.physicalMemory.value
        else { return nil }
        let elevated = current - baseline
        guard trend.perHour > 35, elevated > max(150, baseline * 0.12) else { return nil }
        let maintenance = hasActiveMaintenance
        let severity: Severity = maintenance ? .info : (trend.perHour > 120 && elevated > 400 ? .warning : .info)
        return DiagnosticPrediction(
            id: "prediction.memory-growth",
            kind: "memory.growth",
            severity: severity,
            title: "Roon memory baseline is rising",
            message: maintenance
                ? "Physical memory is elevated during a known Roon maintenance workload; recovery to baseline is being monitored."
                : "Physical memory is rising by about \(Int(trend.perHour.rounded())) MB per hour and has not returned to the learned baseline.",
            confidence: min(0.95, 0.45 + trend.fit * 0.4 + min(0.1, Double(samples.count) / 500)),
            observedAt: now,
            horizonMinutes: trend.perHour > 0 ? 60 : nil,
            currentValue: current,
            baselineValue: baseline,
            changePerHour: trend.perHour,
            unit: "MB",
            evidence: [
                "\(samples.count) samples over \(Int(trend.span / 60)) minutes",
                "Current level is \(Int(elevated.rounded())) MB above baseline",
                maintenance ? "Known maintenance workload is active" : "No maintenance workload is active"
            ]
        )
    }

    private func gcPrediction(now: Date, points: [DiagnosticObservation]) -> DiagnosticPrediction? {
        let values = points.suffix(15).compactMap(\.gcPauseWindowPercent)
        guard values.count >= 5 else { return nil }
        let average = values.reduce(0, +) / Double(values.count)
        let baseline = baselineState.gcPause.value ?? 0
        guard average > max(3, baseline * 3) else { return nil }
        return DiagnosticPrediction(
            id: "prediction.gc-pressure",
            kind: "gc.pressure",
            severity: hasActiveMaintenance ? .info : (average >= 10 ? .warning : .info),
            title: "Garbage-collection pressure is increasing",
            message: "Recent GC pauses average \(String(format: "%.1f", average))% of each measurement window.",
            confidence: min(0.95, 0.55 + Double(values.count) / 50),
            observedAt: now,
            horizonMinutes: 15,
            currentValue: average,
            baselineValue: baseline,
            changePerHour: nil,
            unit: "%",
            evidence: ["\(values.count) recent GC windows", "Learned baseline \(String(format: "%.1f", baseline))%"]
        )
    }

    private func cpuPrediction(now: Date, points: [DiagnosticObservation]) -> DiagnosticPrediction? {
        let values = points.suffix(5).compactMap(\.cpuPercent)
        guard values.count >= 3 else { return nil }
        let average = values.reduce(0, +) / Double(values.count)
        let baseline = baselineState.cpu.value ?? 0
        guard average > 75, average > baseline + 30 else { return nil }
        return DiagnosticPrediction(id: "prediction.cpu", kind: "cpu.sustained", severity: average > 120 ? .warning : .info, title: "Roon CPU load remains elevated", message: "CPU usage stayed near \(Int(average.rounded()))% across several samples instead of returning to its learned level.", confidence: 0.75, observedAt: now, horizonMinutes: 5, currentValue: average, baselineValue: baseline, changePerHour: nil, unit: "%", evidence: ["\(values.count) consecutive samples", "Baseline \(Int(baseline.rounded()))%"])
    }

    private func openFilePrediction(now: Date, points: [DiagnosticObservation]) -> DiagnosticPrediction? {
        let samples = points.compactMap { point in point.openFiles.map { (point.time, $0) } }
        guard let trend = Self.linearTrend(samples: samples, minimumSpan: 60 * 60),
              let current = samples.last?.1,
              let baseline = baselineState.openFiles.value,
              trend.perHour > 30,
              current > baseline + max(150, baseline * 0.25)
        else { return nil }
        return DiagnosticPrediction(id: "prediction.open-files", kind: "files.growth", severity: .warning, title: "Open-file count is not returning to baseline", message: "Roon is accumulating about \(Int(trend.perHour.rounded())) additional descriptors per hour.", confidence: min(0.9, 0.5 + trend.fit * 0.4), observedAt: now, horizonMinutes: 60, currentValue: current, baselineValue: baseline, changePerHour: trend.perHour, unit: "files", evidence: ["Observed over \(Int(trend.span / 3600)) hours", "Current \(Int(current)) vs baseline \(Int(baseline))"])
    }

    private func diskPrediction(now: Date, points: [DiagnosticObservation]) -> DiagnosticPrediction? {
        let values = points.suffix(10).compactMap(\.diskIOMBps)
        guard values.count >= 5 else { return nil }
        let average = values.reduce(0, +) / Double(values.count)
        let baseline = baselineState.diskIO.value ?? 0
        guard average > 10, average > baseline * 5 + 2 else { return nil }
        let maintenance = hasActiveMaintenance
        return DiagnosticPrediction(id: "prediction.disk-io", kind: "disk.sustained", severity: maintenance ? .info : .warning, title: "Sustained Roon disk activity", message: maintenance ? "Disk activity is elevated during a known database-maintenance episode." : "Disk throughput remains well above the learned Roon baseline without a known maintenance event.", confidence: 0.72, observedAt: now, horizonMinutes: 10, currentValue: average, baselineValue: baseline, changePerHour: nil, unit: "MB/s", evidence: ["\(values.count) recent samples", maintenance ? "Correlated with database maintenance" : "No maintenance episode detected"])
    }

    private func recurringIncidentPredictions(now: Date, incidents: [DiagnosticIncident]) -> [DiagnosticPrediction] {
        let recent = incidents.filter { $0.startedAt >= now.addingTimeInterval(-24 * 60 * 60) }
        let grouped = Dictionary(grouping: recent.filter { $0.kind == "raat.transport" || $0.kind == "playback.failure" || $0.kind == "device.cast" }, by: { "\($0.kind)|\($0.zone ?? $0.source ?? "unknown")" })
        return grouped.compactMap { key, matches in
            guard matches.count >= 3 else { return nil }
            let first = matches[0]
            return DiagnosticPrediction(id: "prediction.recurring.\(key)", kind: "incident.recurring", severity: matches.count >= 6 ? .warning : .info, title: "Recurring \(first.title.lowercased())", message: "The same endpoint produced \(matches.count) separate episodes during the last 24 hours.", confidence: min(0.95, 0.55 + Double(matches.count) * 0.06), observedAt: now, horizonMinutes: 24 * 60, currentValue: Double(matches.count), baselineValue: nil, changePerHour: nil, unit: "episodes", evidence: matches.prefix(3).map { "\($0.title) at \(ISO8601DateFormatter().string(from: $0.startedAt))" })
        }
    }

    private func operationalPredictions(
        now: Date,
        metrics: [DiagnosticMetricSummary],
        incidents: [DiagnosticIncident]
    ) -> [DiagnosticPrediction] {
        var results = metrics.compactMap { metric -> DiagnosticPrediction? in
            guard metric.severity == .warning,
                  !["storage.availability", "backup.status"].contains(metric.kind)
            else { return nil }
            return DiagnosticPrediction(
                id: "prediction.metric.\(metric.id)",
                kind: metric.kind,
                severity: .warning,
                title: metric.title,
                message: metric.summary,
                confidence: metric.sampleCount >= 10 ? 0.82 : 0.68,
                observedAt: metric.observedAt,
                horizonMinutes: metric.windowMinutes,
                currentValue: metric.latestValue ?? metric.averageValue,
                baselineValue: metric.baselineValue,
                changePerHour: nil,
                unit: metric.unit,
                evidence: metric.details
            )
        }

        if let lastSuccessfulBackupAt {
            let days = now.timeIntervalSince(lastSuccessfulBackupAt) / 86_400
            let backupRunning = incidents.contains { $0.kind == "backup.run" && $0.state != .resolved }
            if days >= 8, !backupRunning {
                results.append(DiagnosticPrediction(
                    id: "prediction.backup.overdue",
                    kind: "backup.overdue",
                    severity: .warning,
                    title: "Roon backup overdue",
                    message: "No successful Roon backup has been observed for \(Int(days.rounded(.down))) days.",
                    confidence: 0.9,
                    observedAt: now,
                    horizonMinutes: nil,
                    currentValue: days,
                    baselineValue: 7,
                    changePerHour: nil,
                    unit: "days",
                    evidence: ["Last successful backup: \(ISO8601DateFormatter().string(from: lastSuccessfulBackupAt))"]
                ))
            }
        }
        return results
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        let retained = incidentOrder.filter { id in
            guard let incident = incidentsByID[id] else { return false }
            return incident.updatedAt >= cutoff || incident.state != .resolved
        }
        if retained.count != incidentOrder.count {
            let retainedSet = Set(retained)
            incidentsByID = incidentsByID.filter { retainedSet.contains($0.key) }
            incidentOrder = retained
            invalidate()
        }
        let metricCount = metricBuckets.count
        metricBuckets = metricBuckets.filter { $0.value.updatedAt >= cutoff }
        if metricBuckets.count != metricCount {
            invalidate()
        }
    }

    private func trimIncidentHistory() {
        while incidentOrder.count > 300,
              let index = incidentOrder.firstIndex(where: { incidentsByID[$0]?.state == .resolved }) {
            let id = incidentOrder.remove(at: index)
            incidentsByID[id] = nil
        }
    }

    private func invalidate() {
        revision &+= 1
        cachedSnapshot = nil
    }

    private static func appendingEvidence(_ existing: [DiagnosticEvidence], event: RuntimeEvent, line: String) -> [DiagnosticEvidence] {
        var evidence = existing
        let message = redacted(String(line.prefix(1_000)))
        guard !evidence.contains(where: { $0.time == event.time && $0.message == message }) else { return evidence }
        evidence.append(DiagnosticEvidence(id: UUID().uuidString, time: event.time, title: event.title, message: message, source: event.source, domain: event.domain))
        return Array(evidence.suffix(8))
    }

    private static func redacted(_ message: String) -> String {
        LogRedactor.redact(message)
    }

    private static func endpointKey(_ message: String) -> String {
        let patterns = [#"apiclient\s+([^\]]+)"#, #"\[([^\]]+\._googlecast\._tcp\.local)\]"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(message.startIndex..<message.endIndex, in: message)
            guard let match = regex.firstMatch(in: message, range: range),
                  match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: message)
            else { continue }
            let endpoint = String(message[swiftRange])
            return endpoint.replacingOccurrences(
                of: #":\d+$"#,
                with: "",
                options: .regularExpression
            )
        }
        return "unknown"
    }

    private static func extensionName(_ message: String) -> String? {
        guard let range = message.range(of: "=> [") else { return nil }
        let suffix = message[range.upperBound...]
        guard let end = suffix.firstIndex(of: "]") else { return nil }
        let fields = suffix[..<end].split(separator: ",", maxSplits: 1)
        guard let value = fields.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return String(value.prefix(120))
    }

    private static func httpStatusCode(_ message: String) -> Int? {
        guard let regex = try? NSRegularExpression(
            pattern: #"status code:\s*(\d+)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: message)
        else { return nil }
        return Int(message[valueRange])
    }

    private static func mergedDetails(_ existing: [String]?, _ added: [String]?) -> [String]? {
        let values = (existing ?? []) + (added ?? [])
        var seen: Set<String> = []
        let unique = values.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : Array(unique.suffix(8))
    }

    private static func isMaintenanceKind(_ kind: String) -> Bool {
        [
            "database.maintenance",
            "backup.run",
            "metadata.refresh",
            "storage.scan",
            "service.sync"
        ].contains(kind)
    }

    private static func formattedBytes(_ bytes: Int) -> String {
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
        if bytes >= 1_024 {
            return String(format: "%.1f KB", Double(bytes) / 1_024)
        }
        return "\(bytes) B"
    }

    private static func quietTimeout(for kind: String) -> TimeInterval {
        switch kind {
        case "database.maintenance", "server.lifecycle": return 2 * 60
        case "raat.transport": return 30 * 60
        case "playback.buffering": return 2 * 60
        case "playback.failure": return 5 * 60
        case "backup.run": return 2 * 60 * 60
        case "metadata.refresh", "storage.scan", "service.sync": return 30 * 60
        case "service.authentication": return 15 * 60
        case "service.http", "streaming.delivery": return 10 * 60
        case "extension.response_race": return 2 * 60
        case "extension.connection", "extension.sync": return 5 * 60
        case "remote.access", "device.cast": return 30 * 60
        case "database.failure", "server.exception": return 30 * 60
        default: return 10 * 60
        }
    }

    private static func linearTrend(samples: [(Date, Double)], minimumSpan: TimeInterval) -> (perHour: Double, fit: Double, span: TimeInterval)? {
        guard samples.count >= 5, let first = samples.first, let last = samples.last else { return nil }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= minimumSpan else { return nil }
        let xs = samples.map { $0.0.timeIntervalSince(first.0) / 3600 }
        let ys = samples.map(\.1)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let varianceX = xs.reduce(0) { $0 + pow($1 - meanX, 2) }
        guard varianceX > 0 else { return nil }
        let slope = covariance / varianceX
        let totalVariance = ys.reduce(0) { $0 + pow($1 - meanY, 2) }
        let residual = zip(xs, ys).reduce(0) { result, pair in
            let estimate = meanY + slope * (pair.0 - meanX)
            return result + pow(pair.1 - estimate, 2)
        }
        let fit = totalVariance > 0 ? max(0, min(1, 1 - residual / totalVariance)) : 1
        return (slope, fit, span)
    }
}

struct DiagnosticPersistenceState: Codable, Sendable {
    var telemetry: RoonRuntimeTelemetry
    var baseline: DiagnosticBaselineState
    var observations: [DiagnosticObservation]
    var incidents: [DiagnosticIncident]
    var metricBuckets: [DiagnosticMetricBucket]? = nil
    var lastSuccessfulBackupAt: Date? = nil
}

struct DiagnosticMetricBucket: Codable, Sendable {
    var id: String
    var kind: String
    var entity: String
    var startedAt: Date
    var updatedAt: Date
    var count: Int
    var failureCount: Int
    var totalBytes: Int
    var valueCount: Int
    var totalValue: Double
    var minimumValue: Double?
    var maximumValue: Double?
    var latestValue: Double?
    var unit: String?
}

struct DiagnosticObservation: Codable, Sendable {
    var time: Date
    var physicalMemoryMB: Double?
    var processMemoryMB: Double?
    var cpuPercent: Double?
    var openFiles: Double?
    var diskIOMBps: Double?
    var gcPauseWindowPercent: Double?
}

private enum PlaybackActivityState {
    case idle
    case buffering
    case playing
}

struct DiagnosticBaselineState: Codable, Sendable {
    var physicalMemory = AdaptiveMean()
    var processMemory = AdaptiveMean()
    var cpu = AdaptiveMean()
    var openFiles = AdaptiveMean()
    var diskIO = AdaptiveMean()
    var gcPause = AdaptiveMean()
    var updatedAt: Date?

    mutating func update(_ sample: DiagnosticObservation) {
        if let value = sample.physicalMemoryMB { physicalMemory.update(value) }
        if let value = sample.processMemoryMB { processMemory.update(value) }
        if let value = sample.cpuPercent { cpu.update(value) }
        if let value = sample.openFiles { openFiles.update(value) }
        if let value = sample.diskIOMBps { diskIO.update(value) }
        if let value = sample.gcPauseWindowPercent { gcPause.update(value) }
        updatedAt = sample.time
    }

    func snapshot() -> AdaptiveResourceBaseline {
        AdaptiveResourceBaseline(
            sampleCount: [physicalMemory.count, processMemory.count, cpu.count, openFiles.count, diskIO.count, gcPause.count].max() ?? 0,
            updatedAt: updatedAt,
            physicalMemoryMB: physicalMemory.value,
            processMemoryMB: processMemory.value,
            cpuPercent: cpu.value,
            openFiles: openFiles.value,
            diskIOMBps: diskIO.value,
            gcPauseWindowPercent: gcPause.value
        )
    }
}

struct AdaptiveMean: Codable, Sendable {
    var count = 0
    var mean = 0.0
    var value: Double? { count > 0 ? mean : nil }

    mutating func update(_ value: Double) {
        guard value.isFinite else { return }
        count += 1
        let alpha = count < 20 ? 1 / Double(count) : 0.04
        mean += alpha * (value - mean)
    }
}

private extension DiagnosticIncidentState {
    var sortRank: Int {
        switch self {
        case .active: return 0
        case .monitoring: return 1
        case .resolved: return 2
        }
    }
}

private extension Severity {
    var rank: Int {
        switch self {
        case .critical: return 3
        case .warning: return 2
        case .info: return 1
        }
    }
}
