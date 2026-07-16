import Foundation

struct RoonHealthEvaluator {
    var configuration: AppConfiguration
    private let memoryNearThresholdRatio = 0.92
    private let swapWarningMB = 256.0
    private let swapOutWarningRateMBps = 0.05
    private let swapOutCriticalRateMBps = 5.0
    private let roonMemoryShareWarningRatio = 0.35
    private let roonMemoryShareCriticalRatio = 0.55

    func evaluate(
        now: Date,
        mode: RuntimeMode,
        sources: [WatchedSource],
        latestLog: LogLine?,
        events: [RuntimeEvent],
        memory: [MemoryMetric],
        memoryHistory: [MemoryMetric],
        system: LocalSystemStatus?,
        processedLines: Int,
        diagnostics: DiagnosticAnalysisSnapshot? = nil
    ) -> RoonHealth {
        var signals: [RoonHealthSignal] = []
        let rules = configuration.healthRules
        let lastLogAge = latestLog.map { max(0, now.timeIntervalSince($0.receivedAt)) }

        evaluateSources(mode: mode, sources: sources, into: &signals)
        evaluateLogFreshness(latestLog: latestLog, age: lastLogAge, processedLines: processedLines, rules: rules, into: &signals)
        evaluateRecentEventVolume(now: now, events: events, into: &signals)
        evaluateServerState(now: now, events: events, rules: rules, into: &signals)
        evaluateDatabase(now: now, events: events, rules: rules, into: &signals)
        evaluatePlayback(now: now, events: events, rules: rules, into: &signals)
        evaluateMemory(now: now, memory: memory, memoryHistory: memoryHistory, system: system, into: &signals)
        evaluateSystem(system, rules: rules, into: &signals)
        evaluateDisk(now: now, sources: sources, system: system, rules: rules, into: &signals)
        applyDiagnosticContext(diagnostics, to: &signals)
        evaluateDiagnosticIncidents(diagnostics, into: &signals)
        evaluatePredictions(diagnostics, into: &signals)

        let impact = effectiveImpact(signals: signals, diagnostics: diagnostics)
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
            signals: sortedSignals
        )
    }

    private func applyDiagnosticContext(_ diagnostics: DiagnosticAnalysisSnapshot?, to signals: inout [RoonHealthSignal]) {
        guard let diagnostics else { return }
        let contextualDomains: Set<String> = [
            "server",
            "database",
            "raat",
            "playback",
            "memory",
            "storage",
            "service",
            "streaming",
            "metadata",
            "backup"
        ]
        for index in signals.indices where signals[index].impact > 0 {
            guard contextualDomains.contains(signals[index].domain),
                  let observedAt = signals[index].observedAt
            else { continue }

            let matching = diagnostics.incidents.first { incident in
                incident.healthImpact == 0
                    && incident.affectedDomains.contains(signals[index].domain)
                    && observedAt >= incident.startedAt.addingTimeInterval(-30)
                    && observedAt <= (incident.resolvedAt ?? incident.updatedAt.addingTimeInterval(2 * 60))
            }
            if let matching {
                signals[index].severity = .info
                signals[index].impact = 0
                signals[index].message = "Correlated with \(matching.title.lowercased()); not counted as a separate failure."
                continue
            }

            let recovered = diagnostics.incidents.first { incident in
                incident.state == .resolved
                    && incident.affectedDomains.contains(signals[index].domain)
                    && incident.resolvedAt.map { $0 >= observedAt } == true
            }
            if let recovered {
                signals[index].severity = .info
                signals[index].impact = 0
                signals[index].message = recovered.recoveryMessage ?? "A later recovery event resolved this condition."
            }
        }
    }

    private func evaluateDiagnosticIncidents(_ diagnostics: DiagnosticAnalysisSnapshot?, into signals: inout [RoonHealthSignal]) {
        guard let diagnostics else { return }
        for incident in diagnostics.incidents.prefix(12) where incident.state != .resolved && incident.healthImpact > 0 {
            signals.append(signal(
                id: "incident.\(incident.id)",
                domain: incident.affectedDomains.first ?? "incident",
                severity: incident.severity,
                title: incident.title,
                message: incident.summary,
                impact: incident.healthImpact,
                observedAt: incident.updatedAt,
                count: incident.eventCount,
                source: incident.source,
                zone: incident.zone
            ))
        }

        for incident in diagnostics.incidents.prefix(6) where incident.state == .resolved {
            signals.append(signal(
                id: "incident.recovered.\(incident.id)",
                domain: "recovery",
                severity: .info,
                title: "Recovered: \(incident.title)",
                message: incident.recoveryMessage ?? "The incident has recovered.",
                impact: 0,
                observedAt: incident.resolvedAt,
                count: incident.eventCount,
                source: incident.source,
                zone: incident.zone
            ))
        }
    }

    private func evaluatePredictions(_ diagnostics: DiagnosticAnalysisSnapshot?, into signals: inout [RoonHealthSignal]) {
        guard let diagnostics else { return }
        for prediction in diagnostics.predictions where prediction.severity != .info {
            let impact: Int
            switch prediction.kind {
            case "memory.growth", "files.growth": impact = 8
            case "gc.pressure", "cpu.sustained", "disk.sustained": impact = 6
            case "backup.overdue", "metadata.backlog": impact = 8
            case "extension.load": impact = 3
            case "service.latency", "streaming.throughput", "streaming.quality",
                 "database.flush", "database.mutation", "storage.scan": impact = 5
            default: impact = 5
            }
            signals.append(signal(
                id: "prediction.\(prediction.kind)",
                domain: "prediction",
                severity: prediction.severity,
                title: prediction.title,
                message: prediction.message,
                impact: impact,
                observedAt: prediction.observedAt,
                count: prediction.currentValue.map { Int($0.rounded()) }
            ))
        }
    }

    private func effectiveImpact(signals: [RoonHealthSignal], diagnostics: DiagnosticAnalysisSnapshot?) -> Int {
        let activeIncidents = diagnostics?.incidents.filter { $0.state != .resolved && $0.healthImpact > 0 } ?? []
        var grouped: [String: Int] = [:]
        for signal in signals where signal.impact > 0 {
            let group: String
            if signal.id.hasPrefix("memory.")
                || signal.id.hasPrefix("system.swap")
                || signal.id == "system.memory.high"
                || signal.id == "prediction.memory.growth"
                || signal.id == "prediction.gc.pressure" {
                group = "memory-pressure"
            } else if signal.id == "system.cpu.high" || signal.id == "prediction.cpu.sustained" {
                group = "cpu"
            } else if let incident = activeIncidents.first(where: { "incident.\($0.id)" == signal.id }) {
                group = "incident:\(incident.id)"
            } else if signal.domain == "prediction" {
                group = signal.id
            } else if let incident = activeIncidents
                .filter({ incident in
                    guard incident.affectedDomains.contains(signal.domain) else { return false }
                    if let signalZone = signal.zone, let incidentZone = incident.zone,
                       signalZone != incidentZone {
                        return false
                    }
                    guard let observedAt = signal.observedAt else { return true }
                    return observedAt >= incident.startedAt.addingTimeInterval(-30)
                        && observedAt <= incident.updatedAt.addingTimeInterval(30)
                })
                .max(by: { $0.healthImpact < $1.healthImpact }) {
                group = "incident:\(incident.id)"
            } else {
                group = "domain:\(signal.domain)"
            }
            grouped[group] = max(grouped[group, default: 0], signal.impact)
        }
        return min(100, grouped.values.reduce(0, +))
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
            message: "\(currentSources.count) current source(s) are being watched; \(inactiveArchiveCount) inactive or non-current file(s) are ignored for live health.",
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
        let recentServerEvents = recentEvents(now: now, events: events, minutes: rules.eventWindowMinutes)
        if let exception = recentServerEvents.last(where: { $0.type == "server.exception" }) {
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

        let recentExceptionWarnings = recentServerEvents.filter { $0.type == "server.exception.warning" }
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

    private func evaluatePlayback(now: Date, events: [RuntimeEvent], rules: HealthRuleConfiguration, into signals: inout [RoonHealthSignal]) {
        let recentPlayback = recentEvents(now: now, events: events, minutes: rules.playbackWindowMinutes).filter {
            $0.domain == "playback" && $0.type == "playback.warning.detected" && $0.severity == .warning
        }
        guard recentPlayback.count >= rules.playbackCriticalCount else { return }
        let criticalThreshold = max(rules.playbackCriticalCount * 3, rules.playbackCriticalCount + 1)
        let isCritical = recentPlayback.count >= criticalThreshold
        let impact = isCritical ? min(32, 20 + recentPlayback.count) : min(24, 8 + recentPlayback.count * 2)
        signals.append(signal(
            id: "playback.unstable",
            domain: "playback",
            severity: isCritical ? .critical : .warning,
            title: "Playback instability",
            message: "\(recentPlayback.count) visible playback timeout or failure warning(s) in the configured window.",
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
        system: LocalSystemStatus?,
        into signals: inout [RoonHealthSignal]
    ) {
        guard configuration.memoryAlerts.enabled else { return }
        let thresholds: [String: Double] = [
            "Physical Memory": configuration.memoryAlerts.physicalMemoryMB,
            "Managed Memory": configuration.memoryAlerts.managedMemoryMB,
            "Unmanaged Memory": configuration.memoryAlerts.unmanagedMemoryMB,
            "Native Memory": configuration.memoryAlerts.unmanagedMemoryMB
        ]
        let swapSeverity = swapPressureSeverity(system)
        let processShareSeverity = roonMemoryShareSeverity(system)

        for metric in memory {
            guard let threshold = thresholds[metric.metric] else { continue }
            let signalIDs = memorySignalIDs(for: metric.metric)
            if metric.valueMB >= threshold {
                let severity = memoryThresholdSeverity(swapSeverity: swapSeverity, processShareSeverity: processShareSeverity)
                signals.append(signal(
                    id: signalIDs.high,
                    domain: "memory",
                    severity: severity,
                    title: "\(metric.metric) over threshold",
                    message: memoryThresholdMessage(metric: metric.metric, severity: severity),
                    impact: memoryThresholdImpact(severity),
                    observedAt: metric.updatedAt,
                    valueMB: metric.valueMB,
                    thresholdMB: threshold,
                    source: metric.source
                ))
            } else if metric.valueMB >= threshold * memoryNearThresholdRatio {
                let severity: Severity = swapSeverity == nil ? .info : .warning
                signals.append(signal(
                    id: signalIDs.near,
                    domain: "memory",
                    severity: severity,
                    title: "\(metric.metric) near threshold",
                    message: memoryNearThresholdMessage(metric: metric.metric, severity: severity),
                    impact: severity == .warning ? 8 : 0,
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
                let threshold = thresholds[metricName] ?? .greatestFiniteMagnitude
                let latestNearThreshold = last.valueMB >= threshold * memoryNearThresholdRatio
                let severity: Severity = (swapSeverity != nil || (latestNearThreshold && processShareSeverity != nil)) ? .warning : .info
                signals.append(signal(
                    id: "memory.growth",
                    domain: "memory",
                    severity: severity,
                    title: "Memory growth detected",
                    message: memoryGrowthMessage(metric: metricName, delta: delta, severity: severity),
                    impact: severity == .warning ? 14 : 0,
                    observedAt: last.updatedAt,
                    valueMB: last.valueMB,
                    deltaMB: delta,
                    windowMinutes: window,
                    source: last.source
                ))
            }
        }
    }

    private func memorySignalIDs(for metric: String) -> (high: String, near: String) {
        switch metric {
        case "Physical Memory":
            return ("memory.physical_high", "memory.physical_near_threshold")
        case "Managed Memory":
            return ("memory.managed_high", "memory.managed_near_threshold")
        case "Unmanaged Memory", "Native Memory":
            return ("memory.unmanaged_high", "memory.unmanaged_near_threshold")
        default:
            return ("memory.high", "memory.near_threshold")
        }
    }

    private func memoryThresholdSeverity(swapSeverity: Severity?, processShareSeverity: Severity?) -> Severity {
        if swapSeverity == .critical || processShareSeverity == .critical {
            return .critical
        }
        if swapSeverity == .warning || processShareSeverity == .warning {
            return .warning
        }
        return .info
    }

    private func memoryThresholdImpact(_ severity: Severity) -> Int {
        switch severity {
        case .critical: return 28
        case .warning: return 12
        case .info: return 0
        }
    }

    private func memoryThresholdMessage(metric: String, severity: Severity) -> String {
        switch severity {
        case .critical:
            return "\(metric) is above the configured threshold while the system is under memory pressure."
        case .warning:
            return "\(metric) is above the configured threshold and system pressure or process share makes it relevant."
        case .info:
            return "\(metric) is above the configured threshold, but macOS is not reporting meaningful swap pressure."
        }
    }

    private func memoryNearThresholdMessage(metric: String, severity: Severity) -> String {
        switch severity {
        case .critical, .warning:
            return "\(metric) is near the configured threshold while system memory pressure is present."
        case .info:
            return "\(metric) is near the configured threshold; this is treated as observation without system memory pressure."
        }
    }

    private func memoryGrowthMessage(metric: String, delta: Double, severity: Severity) -> String {
        let roundedDelta = Int(delta.rounded())
        if severity == .warning {
            return "\(metric) grew by \(roundedDelta) MB while memory pressure indicators are active."
        }
        return "\(metric) grew by \(roundedDelta) MB, but no system memory pressure is currently visible."
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

        evaluateSwap(system, into: &signals)

        if system.totalMemoryMB >= rules.processMemoryWarningMB {
            let severity = roonMemoryShareSeverity(system) ?? swapPressureSeverity(system) ?? .info
            signals.append(signal(
                id: severity == .info ? "system.memory.observed" : "system.memory.high",
                domain: "system",
                severity: severity,
                title: "High Roon process memory",
                message: processMemoryMessage(for: system, severity: severity),
                impact: severity == .critical ? 28 : (severity == .warning ? 14 : 0),
                observedAt: system.sampledAt,
                valueMB: system.totalMemoryMB,
                thresholdMB: rules.processMemoryWarningMB
            ))
        }
    }

    private func evaluateSwap(_ system: LocalSystemStatus, into signals: inout [RoonHealthSignal]) {
        guard let swapUsedMB = system.swapUsedMB else { return }
        let severity = swapPressureSeverity(system)

        guard let severity else {
            let hasAllocatedSwap = swapUsedMB >= swapWarningMB
            signals.append(signal(
                id: hasAllocatedSwap ? "system.swap.inactive" : "system.swap.ok",
                domain: "system",
                severity: .info,
                title: hasAllocatedSwap ? "System swap inactive" : "System swap low",
                message: hasAllocatedSwap
                    ? "macOS has allocated swap, but no active swap-out pressure is visible."
                    : "macOS swap usage is currently low.",
                impact: 0,
                observedAt: system.sampledAt,
                valueMB: swapUsedMB,
                thresholdMB: swapWarningMB
            ))
            return
        }

        signals.append(signal(
            id: severity == .critical ? "system.swap.critical" : "system.swap.used",
            domain: "system",
            severity: severity,
            title: severity == .critical ? "System swap critical" : "System swap in use",
            message: swapMessage(for: system, severity: severity),
            impact: severity == .critical ? 42 : 24,
            observedAt: system.sampledAt,
            valueMB: swapUsedMB,
            thresholdMB: nil
        ))
    }

    private func swapPressureSeverity(_ system: LocalSystemStatus?) -> Severity? {
        guard let outRate = system?.swapOutRateMBps else { return nil }
        if outRate >= swapOutCriticalRateMBps {
            return .critical
        }
        if outRate >= swapOutWarningRateMBps {
            return .warning
        }
        return nil
    }

    private func roonMemoryShareSeverity(_ system: LocalSystemStatus?) -> Severity? {
        guard let system,
              let physicalMB = system.totalPhysicalMemoryMB,
              physicalMB > 0
        else { return nil }
        let ratio = system.totalMemoryMB / physicalMB
        if ratio >= roonMemoryShareCriticalRatio {
            return .critical
        }
        if ratio >= roonMemoryShareWarningRatio {
            return .warning
        }
        return nil
    }

    private func swapMessage(for system: LocalSystemStatus, severity: Severity) -> String {
        let used = system.swapUsedMB ?? 0
        let total = system.swapTotalMB ?? 0
        let ratio = system.swapUsedRatio.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
        let outRate = system.swapOutRateMBps ?? 0
        if severity == .critical {
            return "macOS is actively swapping out at \(String(format: "%.2f", outRate)) MB/s; \(Int(used.rounded())) MB of \(Int(total.rounded())) MB is allocated\(ratio)."
        }
        return "macOS is swapping out at \(String(format: "%.2f", outRate)) MB/s; \(Int(used.rounded())) MB of \(Int(total.rounded())) MB is allocated\(ratio)."
    }

    private func processMemoryMessage(for system: LocalSystemStatus, severity: Severity) -> String {
        let share = system.totalPhysicalMemoryMB.flatMap { total -> String? in
            guard total > 0 else { return nil }
            return "\(Int(((system.totalMemoryMB / total) * 100).rounded()))% of physical memory"
        } ?? "an unknown share of physical memory"

        switch severity {
        case .critical:
            return "Roon processes use \(share) and memory pressure is critical."
        case .warning:
            return "Roon processes use \(share), which is high enough to affect system headroom."
        case .info:
            return "Roon processes are above the configured memory threshold, but macOS is not under memory pressure."
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
