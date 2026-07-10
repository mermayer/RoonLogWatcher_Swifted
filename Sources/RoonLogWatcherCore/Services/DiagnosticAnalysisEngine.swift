import Foundation

final class DiagnosticAnalysisEngine {
    private var telemetry = RoonRuntimeTelemetry()
    private var incidentsByID: [String: DiagnosticIncident] = [:]
    private var incidentOrder: [String] = []
    private var activeIncidentIDs: [String: String] = [:]
    private var observations = BoundedArray<DiagnosticObservation>(limit: 10_080)
    private var baselineState = DiagnosticBaselineState()
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
        let value = DiagnosticAnalysisSnapshot(
            telemetry: telemetry,
            baseline: baselineState.snapshot(),
            incidents: incidents,
            incidentTotalCount: incidents.count,
            activeIncidentCount: incidents.filter { $0.state != .resolved }.count,
            predictions: predictions(now: now, incidents: incidents)
        )
        cachedSnapshot = (revision, now.addingTimeInterval(30), value)
        return compact ? compactSnapshot(value) : value
    }

    func incidentCollection(now: Date) -> [DiagnosticIncident] {
        updateQuietIncidentStates(now: now)
        prune(now: now)
        return visibleIncidents(now: now)
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
            incidents: incidents
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
        invalidate()
    }

    private func compactSnapshot(_ snapshot: DiagnosticAnalysisSnapshot) -> DiagnosticAnalysisSnapshot {
        var compact = snapshot
        compact.incidents = Array(snapshot.incidents.prefix(4))
        compact.predictions = Array(snapshot.predictions.prefix(5))
        return compact
    }

    private func updateTelemetry(from event: RuntimeEvent) {
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
                upsert(key: "raat:\(zone)", kind: "raat.transport", severity: .warning, title: "RAAT transport interruption", summary: "A RAAT endpoint disconnected outside a known maintenance episode.", domains: ["raat", "playback"], impact: 12, event: event, line: line)
            }
        case "raat.connected":
            resolve(key: "raat:\(event.zone ?? "unknown")", event: event, line: line, recovery: "The RAAT endpoint connected again.")
        case "playback.warning.detected":
            let zone = event.zone ?? "unknown"
            upsert(key: "playback:\(zone)", kind: "playback.failure", severity: .warning, title: "Playback interruption", summary: "Playback reported a timeout, failure or network interruption.", domains: ["playback", "raat"], impact: 10, event: event, line: line)
        case "playback.playing":
            resolve(key: "playback:\(event.zone ?? "unknown")", event: event, line: line, recovery: "Playback is running again.")
        case "database.critical":
            upsert(key: "database-failure", kind: "database.failure", severity: .critical, title: "Database integrity risk", summary: "Roon reported database corruption or an unrecoverable database error.", domains: ["database", "server"], impact: 42, event: event, line: line)
        case "database.warning":
            upsert(key: "database-failure", kind: "database.failure", severity: .warning, title: "Database access failure", summary: "Roon could not complete a database operation.", domains: ["database"], impact: 16, event: event, line: line)
        case "database.recovered":
            resolve(key: "database-failure", event: event, line: line, recovery: "A subsequent database operation completed successfully.")
        case "extension.timeout", "extension.disconnected":
            let client = Self.endpointKey(event.message)
            upsert(key: "extension:\(client)", kind: "extension.connection", severity: .info, title: "Roon API client disconnected", summary: "A Roon extension connection timed out; Roon Core remains available.", domains: ["extension"], impact: 0, event: event, line: line)
        case "extension.connected":
            resolve(key: "extension:\(Self.endpointKey(event.message))", event: event, line: line, recovery: "The Roon API client connected again.")
        case "extension.sync":
            let client = Self.endpointKey(event.message)
            upsert(key: "extension-sync:\(client)", kind: "extension.sync", severity: .info, title: "Roon API state synchronization", summary: "An extension subscribed to zones or queues and received a potentially large state payload.", domains: ["extension", "memory"], impact: 0, event: event, line: line)
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
        line: String
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
            evidence: Self.appendingEvidence([], event: event, line: line)
        )
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
        incident.state = .resolved
        incident.updatedAt = max(incident.updatedAt, event.time)
        incident.resolvedAt = event.time
        incident.recoveryMessage = recovery
        incident.evidence = Self.appendingEvidence(incident.evidence, event: event, line: line)
        incidentsByID[id] = incident
    }

    private func updateQuietIncidentStates(now: Date) {
        var changed = false
        var resolvedKeys: [String] = []
        for (key, id) in activeIncidentIDs {
            guard var incident = incidentsByID[id] else { continue }
            let quiet = now.timeIntervalSince(incident.updatedAt)
            let timeout = Self.quietTimeout(for: incident.kind)
            if quiet >= timeout {
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
            guard let incident = incidentsByID[id], incident.updatedAt >= cutoff else { return nil }
            return incident
        }.sorted {
            if $0.state != $1.state { return $0.state.sortRank < $1.state.sortRank }
            if $0.severity.rank != $1.severity.rank { return $0.severity.rank > $1.severity.rank }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func predictions(now: Date, incidents: [DiagnosticIncident]) -> [DiagnosticPrediction] {
        let points = observations.items.filter { $0.time >= now.addingTimeInterval(-24 * 60 * 60) }
        var results: [DiagnosticPrediction] = []
        if let prediction = memoryPrediction(now: now, points: points) { results.append(prediction) }
        if let prediction = gcPrediction(now: now, points: points) { results.append(prediction) }
        if let prediction = cpuPrediction(now: now, points: points) { results.append(prediction) }
        if let prediction = openFilePrediction(now: now, points: points) { results.append(prediction) }
        if let prediction = diskPrediction(now: now, points: points) { results.append(prediction) }
        results.append(contentsOf: recurringIncidentPredictions(now: now, incidents: incidents))
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
        let severity: Severity = trend.perHour > 120 && elevated > 400 ? .warning : .info
        return DiagnosticPrediction(
            id: "prediction.memory-growth",
            kind: "memory.growth",
            severity: severity,
            title: "Roon memory baseline is rising",
            message: "Physical memory is rising by about \(Int(trend.perHour.rounded())) MB per hour and has not returned to the learned baseline.",
            confidence: min(0.95, 0.45 + trend.fit * 0.4 + min(0.1, Double(samples.count) / 500)),
            observedAt: now,
            horizonMinutes: trend.perHour > 0 ? 60 : nil,
            currentValue: current,
            baselineValue: baseline,
            changePerHour: trend.perHour,
            unit: "MB",
            evidence: ["\(samples.count) samples over \(Int(trend.span / 60)) minutes", "Current level is \(Int(elevated.rounded())) MB above baseline"]
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
            severity: average >= 10 ? .warning : .info,
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
        let maintenance = activeIncidentIDs["database-maintenance"] != nil
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
        var value = message
        let patterns = [
            (#"(?i)(\"token\"\s*:\s*\")[^\"]+(\")"#, "$1[redacted]$2"),
            (#"(?i)(token=)[^\s,&]+"#, "$1[redacted]"),
            (#"(?i)(authorization\s*[:=]\s*)[^\s,]+"#, "$1[redacted]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
        }
        return value
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

    private static func quietTimeout(for kind: String) -> TimeInterval {
        switch kind {
        case "database.maintenance", "server.lifecycle": return 2 * 60
        case "raat.transport", "playback.failure": return 5 * 60
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
