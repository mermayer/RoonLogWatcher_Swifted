import Foundation

struct RoonHealthEvaluator {
    var configuration: AppConfiguration

    func evaluate(
        now: Date,
        mode: RuntimeMode,
        sources: [WatchedSource],
        logs: [LogLine],
        events: [RuntimeEvent],
        memory: [MemoryMetric],
        memoryHistory: [MemoryMetric],
        system: LocalSystemStatus?,
        processedLines: Int
    ) -> RoonHealth {
        var signals: [RoonHealthSignal] = []
        let rules = configuration.healthRules
        let latestLog = logs.last
        let lastLogAge = latestLog.map { max(0, now.timeIntervalSince($0.receivedAt)) }

        evaluateSources(mode: mode, sources: sources, into: &signals)
        evaluateLogFreshness(latestLog: latestLog, age: lastLogAge, processedLines: processedLines, rules: rules, into: &signals)
        evaluateRecentEventVolume(now: now, events: events, into: &signals)
        evaluateServerState(now: now, events: events, rules: rules, into: &signals)
        evaluateDatabase(now: now, events: events, rules: rules, into: &signals)
        evaluateRaat(now: now, events: events, rules: rules, into: &signals)
        evaluatePlayback(now: now, events: events, rules: rules, into: &signals)
        evaluateMemory(now: now, memory: memory, memoryHistory: memoryHistory, into: &signals)
        evaluateSystem(system, rules: rules, into: &signals)
        evaluateDisk(now: now, sources: sources, system: system, rules: rules, into: &signals)

        let impact = min(100, signals.reduce(0) { $0 + max(0, $1.impact) })
        let score = max(0, 100 - impact)
        let state: RoonHealthState
        if signals.contains(where: { $0.severity == .critical }) || score < 55 {
            state = .critical
        } else if signals.contains(where: { $0.severity == .warning }) || score < 82 {
            state = .degraded
        } else if latestLog == nil && sources.isEmpty {
            state = .unknown
        } else {
            state = .healthy
        }

        let sortedSignals = signals.sorted {
            if $0.severity.rank != $1.severity.rank { return $0.severity.rank > $1.severity.rank }
            if $0.impact != $1.impact { return $0.impact > $1.impact }
            return ($0.observedAt ?? .distantPast) > ($1.observedAt ?? .distantPast)
        }

        return RoonHealth(
            state: state,
            score: score,
            title: title(for: state),
            summary: summary(for: state, signals: sortedSignals),
            evaluatedAt: now,
            lastLogAt: latestLog?.receivedAt,
            lastLogAgeSeconds: lastLogAge,
            signals: Array(sortedSignals.prefix(10))
        )
    }

    private func evaluateSources(mode: RuntimeMode, sources: [WatchedSource], into signals: inout [RoonHealthSignal]) {
        if sources.isEmpty {
            signals.append(signal(
                id: "source.none",
                domain: "source",
                severity: .warning,
                title: "No watched log source",
                message: "No log file is currently being watched.",
                impact: 28
            ))
            return
        }

        let realSources = sources.filter { source in
            source.status != "demo" && !source.path.hasPrefix("/Demo/")
        }
        if realSources.isEmpty && mode == .demo {
            signals.append(signal(
                id: "source.no_real",
                domain: "source",
                severity: .warning,
                title: "No real Roon log source",
                message: "Only generated sample lines are visible.",
                impact: 16,
                count: sources.count
            ))
            return
        }

        let currentSources = realSources.filter(Self.isCurrentSource)
        let inactiveArchiveCount = realSources.count - currentSources.count
        if currentSources.isEmpty {
            signals.append(signal(
                id: "source.archived_only",
                domain: "source",
                severity: .warning,
                title: "No current log source",
                message: "Only rotated or inactive log files were found.",
                impact: 20,
                count: realSources.count
            ))
            return
        }

        signals.append(signal(
            id: "source.active",
            domain: "source",
            severity: .info,
            title: "Log sources active",
            message: "\(currentSources.count) current source(s) are being watched; \(inactiveArchiveCount) rotated or inactive file(s) are hidden from the main list.",
            impact: 0,
            count: currentSources.count
        ))
    }

    private static func isCurrentSource(_ source: WatchedSource) -> Bool {
        return !isRotatedLogFile(source.path)
    }

    private static func isRotatedLogFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty else { return false }

        let pathExtension = url.pathExtension
        let stem: String
        if pathExtension.isEmpty {
            stem = fileName
        } else {
            stem = String(fileName.dropLast(pathExtension.count + 1))
        }

        guard stem.contains("."), let suffix = stem.split(separator: ".").last else {
            return false
        }
        return suffix.allSatisfy(\.isNumber)
    }

    private func evaluateLogFreshness(
        latestLog: LogLine?,
        age: Double?,
        processedLines: Int,
        rules: HealthRuleConfiguration,
        into signals: inout [RoonHealthSignal]
    ) {
        guard let latestLog, let age else {
            let severity: Severity = processedLines == 0 ? .warning : .critical
            signals.append(signal(
                id: "logs.none",
                domain: "logs",
                severity: severity,
                title: "No log lines received",
                message: "The watcher has not processed a log line yet.",
                impact: processedLines == 0 ? 24 : 36
            ))
            return
        }

        if age > rules.logStaleCriticalSeconds {
            signals.append(signal(
                id: "logs.stale_critical",
                domain: "logs",
                severity: .critical,
                title: "Log stream stale",
                message: "The last log line is older than the critical freshness threshold.",
                impact: 34,
                observedAt: latestLog.receivedAt,
                ageSeconds: age,
                source: latestLog.source
            ))
        } else if age > rules.logStaleWarningSeconds {
            signals.append(signal(
                id: "logs.stale_warning",
                domain: "logs",
                severity: .warning,
                title: "Log stream quiet",
                message: "The last log line is older than the warning freshness threshold.",
                impact: 16,
                observedAt: latestLog.receivedAt,
                ageSeconds: age,
                source: latestLog.source
            ))
        } else {
            signals.append(signal(
                id: "logs.fresh",
                domain: "logs",
                severity: .info,
                title: "Log stream fresh",
                message: "Recent log lines are arriving.",
                impact: 0,
                observedAt: latestLog.receivedAt,
                ageSeconds: age,
                source: latestLog.source
            ))
        }
    }

    private func evaluateRecentEventVolume(now: Date, events: [RuntimeEvent], into signals: inout [RoonHealthSignal]) {
        let rules = configuration.healthRules
        let recent = recentEvents(now: now, events: events, minutes: rules.eventWindowMinutes)
            .filter { $0.domain == "log" }
        let critical = recent.filter { $0.severity == .critical }
        let warnings = recent.filter { $0.severity == .warning }

        if !critical.isEmpty {
            signals.append(signal(
                id: "events.critical",
                domain: "events",
                severity: .critical,
                title: "Critical events detected",
                message: "\(critical.count) critical event(s) in the configured window.",
                impact: min(42, 24 + critical.count * 6),
                observedAt: critical.map(\.time).max(),
                count: critical.count,
                windowMinutes: rules.eventWindowMinutes
            ))
        }

        if warnings.count >= rules.warningBurstCount {
            signals.append(signal(
                id: "events.warning",
                domain: "events",
                severity: .warning,
                title: "Warning burst detected",
                message: "\(warnings.count) warning event(s) in the configured window.",
                impact: min(28, 10 + warnings.count * 2),
                observedAt: warnings.map(\.time).max(),
                count: warnings.count,
                windowMinutes: rules.eventWindowMinutes
            ))
        }
    }

    private func evaluateServerState(now: Date, events: [RuntimeEvent], rules: HealthRuleConfiguration, into signals: inout [RoonHealthSignal]) {
        if let exception = events.last(where: { $0.type == "server.exception" }) {
            signals.append(signal(
                id: "server.exception",
                domain: "server",
                severity: .critical,
                title: "Server exception",
                message: exception.message,
                impact: 42,
                observedAt: exception.time,
                source: exception.source
            ))
        }

        let latestServerEvent = events.last { $0.domain == "server" }
        if latestServerEvent?.type == "server.stopped" {
            signals.append(signal(
                id: "server.stopped",
                domain: "server",
                severity: .critical,
                title: "Server stopped",
                message: latestServerEvent?.message ?? "The latest server state indicates a stop.",
                impact: 40,
                observedAt: latestServerEvent?.time,
                source: latestServerEvent?.source
            ))
        }

        let recentExceptionWarnings = recentEvents(now: now, events: events, minutes: rules.eventWindowMinutes)
            .filter { $0.type == "server.exception.warning" }
        if !recentExceptionWarnings.isEmpty {
            signals.append(signal(
                id: "server.exception.warning",
                domain: "server",
                severity: .warning,
                title: "Server exception warning",
                message: "\(recentExceptionWarnings.count) retryable or non-fatal exception warning(s) in the configured window.",
                impact: min(18, 8 + recentExceptionWarnings.count * 2),
                observedAt: recentExceptionWarnings.map(\.time).max(),
                count: recentExceptionWarnings.count,
                windowMinutes: rules.eventWindowMinutes,
                source: recentExceptionWarnings.last?.source
            ))
        }
    }

    private func evaluateDatabase(now: Date, events: [RuntimeEvent], rules: HealthRuleConfiguration, into signals: inout [RoonHealthSignal]) {
        let recentDatabase = recentEvents(now: now, events: events, minutes: rules.databaseWindowMinutes).filter { $0.domain == "database" }
        let critical = recentDatabase.filter { $0.severity == .critical }
        let warnings = recentDatabase.filter { $0.severity == .warning }

        if !critical.isEmpty {
            signals.append(signal(
                id: "database.critical",
                domain: "database",
                severity: .critical,
                title: "Database health risk",
                message: "\(critical.count) critical database event(s) in the configured window.",
                impact: min(42, 26 + critical.count * 5),
                observedAt: critical.map(\.time).max(),
                count: critical.count,
                windowMinutes: rules.databaseWindowMinutes
            ))
        } else if !warnings.isEmpty {
            signals.append(signal(
                id: "database.warning",
                domain: "database",
                severity: .warning,
                title: "Database warning",
                message: "\(warnings.count) database warning(s) in the configured window.",
                impact: min(24, 12 + warnings.count * 3),
                observedAt: warnings.map(\.time).max(),
                count: warnings.count,
                windowMinutes: rules.databaseWindowMinutes
            ))
        }
    }

    private func evaluateRaat(now: Date, events: [RuntimeEvent], rules: HealthRuleConfiguration, into signals: inout [RoonHealthSignal]) {
        let recentRaat = recentEvents(now: now, events: events, minutes: rules.raatWindowMinutes).filter { $0.domain == "raat" }
        let disconnects = recentRaat.filter { $0.type == "raat.disconnected" }

        if disconnects.count >= rules.raatCriticalDisconnects {
            signals.append(signal(
                id: "raat.unstable",
                domain: "raat",
                severity: .critical,
                title: "RAAT unstable",
                message: "\(disconnects.count) disconnect event(s) in the configured window.",
                impact: 34,
                observedAt: disconnects.map(\.time).max(),
                count: disconnects.count,
                windowMinutes: rules.raatWindowMinutes,
                zone: disconnects.last?.zone
            ))
        } else if disconnects.count >= rules.raatWarningDisconnects {
            signals.append(signal(
                id: "raat.unstable",
                domain: "raat",
                severity: .warning,
                title: "RAAT reconnect activity",
                message: "\(disconnects.count) disconnect event(s) in the configured window.",
                impact: 18,
                observedAt: disconnects.map(\.time).max(),
                count: disconnects.count,
                windowMinutes: rules.raatWindowMinutes,
                zone: disconnects.last?.zone
            ))
        } else if let latestRaat = events.last(where: { $0.domain == "raat" }),
                  latestRaat.type == "raat.disconnected",
                  now.timeIntervalSince(latestRaat.time) >= 0,
                  now.timeIntervalSince(latestRaat.time) <= 30 * 60 {
            signals.append(signal(
                id: "raat.disconnected",
                domain: "raat",
                severity: .warning,
                title: "Latest RAAT state disconnected",
                message: latestRaat.message,
                impact: 12,
                observedAt: latestRaat.time,
                source: latestRaat.source,
                zone: latestRaat.zone
            ))
        }
    }

    private func evaluatePlayback(now: Date, events: [RuntimeEvent], rules: HealthRuleConfiguration, into signals: inout [RoonHealthSignal]) {
        let recentPlayback = recentEvents(now: now, events: events, minutes: rules.playbackWindowMinutes).filter {
            $0.domain == "playback" && $0.severity != .info
        }
        guard !recentPlayback.isEmpty else { return }
        let criticalThreshold = max(rules.playbackCriticalCount * 3, rules.playbackCriticalCount + 1)
        let isCritical = recentPlayback.count >= criticalThreshold
        let impact = isCritical ? min(32, 20 + recentPlayback.count) : min(24, 8 + recentPlayback.count * 2)
        signals.append(signal(
            id: "playback.unstable",
            domain: "playback",
            severity: isCritical ? .critical : .warning,
            title: "Playback instability",
            message: "\(recentPlayback.count) playback warning event(s) in the configured window.",
            impact: impact,
            observedAt: recentPlayback.map(\.time).max(),
            count: recentPlayback.count,
            windowMinutes: rules.playbackWindowMinutes,
            zone: recentPlayback.last?.zone
        ))
    }

    private func evaluateMemory(
        now: Date,
        memory: [MemoryMetric],
        memoryHistory: [MemoryMetric],
        into signals: inout [RoonHealthSignal]
    ) {
        guard configuration.memoryAlerts.enabled else { return }
        let thresholds: [String: Double] = [
            "Physical Memory": configuration.memoryAlerts.physicalMemoryMB,
            "Managed Memory": configuration.memoryAlerts.managedMemoryMB,
            "Unmanaged Memory": configuration.memoryAlerts.unmanagedMemoryMB
        ]

        for metric in memory {
            guard let threshold = thresholds[metric.metric] else { continue }
            if metric.valueMB >= threshold {
                signals.append(signal(
                    id: "memory.high",
                    domain: "memory",
                    severity: .critical,
                    title: "High memory usage",
                    message: "\(metric.metric) is above the configured threshold.",
                    impact: 28,
                    observedAt: metric.updatedAt,
                    valueMB: metric.valueMB,
                    thresholdMB: threshold,
                    source: metric.source
                ))
            } else if metric.valueMB >= threshold * 0.82 {
                signals.append(signal(
                    id: "memory.high",
                    domain: "memory",
                    severity: .warning,
                    title: "Memory nearing threshold",
                    message: "\(metric.metric) is nearing the configured threshold.",
                    impact: 12,
                    observedAt: metric.updatedAt,
                    valueMB: metric.valueMB,
                    thresholdMB: threshold,
                    source: metric.source
                ))
            }
        }

        let window = configuration.memoryAlerts.growthWindowMinutes
        for metricName in thresholds.keys {
            let samples = memoryHistory
                .filter { $0.metric == metricName && now.timeIntervalSince($0.updatedAt) <= window * 60 && now.timeIntervalSince($0.updatedAt) >= 0 }
                .sorted { $0.updatedAt < $1.updatedAt }
            guard samples.count >= configuration.memoryAlerts.minSamplesForGrowth,
                  let first = samples.first,
                  let last = samples.last
            else { continue }
            let delta = last.valueMB - first.valueMB
            if delta >= configuration.memoryAlerts.growthThresholdMB {
                signals.append(signal(
                    id: "memory.growth",
                    domain: "memory",
                    severity: .warning,
                    title: "Memory growth detected",
                    message: "\(metricName) grew by \(Int(delta.rounded())) MB.",
                    impact: 18,
                    observedAt: last.updatedAt,
                    valueMB: last.valueMB,
                    deltaMB: delta,
                    windowMinutes: window,
                    source: last.source
                ))
            }
        }
    }

    private func evaluateSystem(_ system: LocalSystemStatus?, rules: HealthRuleConfiguration, into signals: inout [RoonHealthSignal]) {
        guard let system else { return }
        if system.host.isRoonServerLikely {
            signals.append(signal(
                id: "system.host.detected",
                domain: "system",
                severity: .info,
                title: "Local Roon Server detected",
                message: system.host.reason,
                impact: 0,
                observedAt: system.sampledAt,
                count: system.processes.count
            ))
        }

        let cpuHeavy = system.processes.filter { $0.cpuPercent >= rules.processCPUWarningPercent }
        if !cpuHeavy.isEmpty {
            signals.append(signal(
                id: "system.cpu.high",
                domain: "system",
                severity: .warning,
                title: "High Roon process CPU",
                message: "\(cpuHeavy.count) Roon process(es) are above the CPU threshold.",
                impact: 14,
                observedAt: system.sampledAt,
                count: cpuHeavy.count
            ))
        }

        if system.totalMemoryMB >= rules.processMemoryWarningMB {
            signals.append(signal(
                id: "system.memory.high",
                domain: "system",
                severity: .warning,
                title: "High Roon process memory",
                message: "Roon processes are above the memory threshold.",
                impact: 14,
                observedAt: system.sampledAt,
                valueMB: system.totalMemoryMB,
                thresholdMB: rules.processMemoryWarningMB
            ))
        }
    }

    private func evaluateDisk(now: Date, sources: [WatchedSource], system: LocalSystemStatus?, rules: HealthRuleConfiguration, into signals: inout [RoonHealthSignal]) {
        let disk = system.flatMap { status -> (path: String, freeMB: Double, freeRatio: Double)? in
            guard let path = status.logVolumePath,
                  let freeMB = status.logVolumeFreeMB,
                  let ratio = status.logVolumeFreeRatio
            else { return nil }
            return (path, freeMB, ratio)
        } ?? diskStatus(for: sources)
        guard let disk else { return }
        let freeGB = disk.freeMB / 1024
        let severity: Severity
        let impact: Int
        let id: String

        if disk.freeMB < rules.diskCriticalFreeMB || disk.freeRatio < rules.diskCriticalFreeRatio {
            severity = .critical
            impact = 34
            id = "disk.critical"
        } else if disk.freeMB < rules.diskWarningFreeMB || disk.freeRatio < rules.diskWarningFreeRatio {
            severity = .warning
            impact = 14
            id = "disk.low"
        } else {
            severity = .info
            impact = 0
            id = "disk.ok"
        }

        signals.append(signal(
            id: id,
            domain: "disk",
            severity: severity,
            title: "Disk space",
            message: "\(String(format: "%.1f", freeGB)) GB free on the log volume.",
            impact: impact,
            observedAt: now,
            valueMB: disk.freeMB,
            thresholdMB: rules.diskWarningFreeMB,
            source: disk.path
        ))
    }

    private func recentEvents(now: Date, events: [RuntimeEvent], minutes: Double) -> [RuntimeEvent] {
        let interval = minutes * 60
        return events.filter { event in
            let age = now.timeIntervalSince(event.time)
            return age >= 0 && age <= interval
        }
    }

    private func diskStatus(for sources: [WatchedSource]) -> (path: String, freeMB: Double, freeRatio: Double)? {
        let candidates = sources.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
            + [configuration.baseDirectory]
            + [NSHomeDirectory()]

        for candidate in candidates where !candidate.isEmpty {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) else { continue }
            let path = isDirectory.boolValue ? candidate : URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
                  let free = attributes[.systemFreeSize] as? NSNumber,
                  let size = attributes[.systemSize] as? NSNumber,
                  size.doubleValue > 0
            else { continue }
            return (
                path: path,
                freeMB: free.doubleValue / 1_048_576,
                freeRatio: free.doubleValue / size.doubleValue
            )
        }
        return nil
    }

    private func signal(
        id: String,
        domain: String,
        severity: Severity,
        title: String,
        message: String,
        impact: Int,
        observedAt: Date? = nil,
        count: Int? = nil,
        ageSeconds: Double? = nil,
        valueMB: Double? = nil,
        thresholdMB: Double? = nil,
        deltaMB: Double? = nil,
        windowMinutes: Double? = nil,
        source: String? = nil,
        zone: String? = nil
    ) -> RoonHealthSignal {
        RoonHealthSignal(
            id: id,
            domain: domain,
            severity: severity,
            title: title,
            message: message,
            impact: impact,
            observedAt: observedAt,
            count: count,
            ageSeconds: ageSeconds,
            valueMB: valueMB,
            thresholdMB: thresholdMB,
            deltaMB: deltaMB,
            windowMinutes: windowMinutes,
            source: source,
            zone: zone
        )
    }

    private func title(for state: RoonHealthState) -> String {
        switch state {
        case .healthy: return "Roon health stable"
        case .degraded: return "Roon health needs attention"
        case .critical: return "Roon health critical"
        case .unknown: return "Roon health unknown"
        }
    }

    private func summary(for state: RoonHealthState, signals: [RoonHealthSignal]) -> String {
        let actionable = signals.filter { $0.severity != .info || $0.impact > 0 }
        if actionable.isEmpty {
            return "Log ingestion and watched system signals look stable."
        }
        let leading = actionable.prefix(2).map(\.title).joined(separator: ", ")
        switch state {
        case .critical: return "Critical signals: \(leading)."
        case .degraded: return "Warning signals: \(leading)."
        case .healthy: return "No current warning signals."
        case .unknown: return "Waiting for enough log data."
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
