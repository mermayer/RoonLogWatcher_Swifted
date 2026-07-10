import Foundation

public final class RuntimeStore {
    private let lock = NSLock()
    private var configuration: AppConfiguration
    private let runStartedAt = Date()
    private var mode: RuntimeMode = .idle
    private var dashboardURL: String?
    private var sequence = 0
    private var logHistory: BoundedArray<LogLine>
    private var lastReceivedLog: LogLine?
    private var timeline = BoundedArray<RuntimeEvent>(limit: 1_000)
    private var alerts = BoundedArray<RuntimeEvent>(limit: 500)
    private var playback = BoundedArray<RuntimeEvent>(limit: 240)
    private var memoryByMetric: [String: MemoryMetric] = [:]
    private var memoryHistory = BoundedArray<MemoryMetric>(limit: 5_760)
    private var physicalMemoryTrendHistory = BoundedArray<MemoryTrendPoint>(limit: 2_880)
    private var processMemoryHistory = BoundedArray<MemoryTrendPoint>(limit: 2_880)
    private var memoryContextHistory = BoundedArray<MemoryContextLine>(limit: 4_000)
    private var memoryInsights = BoundedArray<MemoryInsight>(limit: 1_000)
    private var lastMemoryStatsSample: MemoryStatsSample?
    private var sources: [String: WatchedSource] = [:]
    private var sourceMetadataRefreshedAt: [String: Date] = [:]
    private var systemStatus: LocalSystemStatus?
    private var healthTrend = BoundedArray<RoonHealthTrendPoint>(limit: 2_880)
    private var recentAlertKeys: [String: Date] = [:]
    private var processedLines = 0
    private var warningCount = 0
    private var criticalCount = 0
    private var logVolumeSlices: [Int: LogVolumeCounts] = [:]
    private var healthRevision = 0
    private var cachedHealth: CachedHealth?
    private var memoryTrendRevision = 0
    private var cachedMemoryTrend: CachedMemoryTrend?
    private let diagnosticEngine: DiagnosticAnalysisEngine
    private let memoryInsightStoreURL: URL?
    private let memoryInsightPersistence = MemoryInsightPersistence()
    private let timestampParser = RoonLogTimestampParser()
    private let alertSnapshotWindow: TimeInterval = 12 * 60 * 60
    private let memoryTrendMinimumSampleInterval: TimeInterval = 30
    private let memoryInsightRetention: TimeInterval = 7 * 24 * 60 * 60
    private let memoryContextRetention: TimeInterval = 10 * 60
    private let memoryInsightContextWindow: TimeInterval = 2 * 60
    private let memoryInsightPruneInterval: TimeInterval = 60
    private let sourceMetadataRefreshInterval: TimeInterval = 5
    private var lastMemoryInsightPruneAt = Date.distantPast
    private let memoryJumpPhysicalThresholdMB: Double = 150
    private let memoryJumpManagedThresholdMB: Double = 250
    private let memoryJumpUnmanagedThresholdMB: Double = 250
    private let diagnosticPersistenceInterval: TimeInterval = 30 * 60
    private var lastDiagnosticPersistenceScheduledAt = Date.distantPast
    private let healthCacheInterval: TimeInterval = 10
    private let memoryTrendCacheInterval: TimeInterval = 60
    private let logVolumeSliceSeconds: TimeInterval = 15
    private let maximumLogVolumeWindow: TimeInterval = 6 * 60 * 60

    public init(configuration: AppConfiguration = .default, memoryInsightStoreURL: URL? = nil) {
        self.configuration = configuration.normalized()
        self.memoryInsightStoreURL = memoryInsightStoreURL
        self.diagnosticEngine = DiagnosticAnalysisEngine()
        self.logHistory = BoundedArray<LogLine>(limit: self.configuration.logHistoryMaxLines)
        loadMemoryInsights()
    }

    public func setDashboardURL(_ url: URL?) {
        lock.withLock {
            dashboardURL = url?.absoluteString
        }
    }

    public func updateConfiguration(_ newConfiguration: AppConfiguration) {
        lock.withLock {
            let normalized = newConfiguration.normalized()
            configuration = normalized
            logHistory.resize(to: normalized.logHistoryMaxLines)
            rebuildLogVolumeSlices()
            invalidateHealth()
        }
    }

    public func flushPersistence() {
        let persistenceRequest = lock.withLock { () -> (MemoryInsightDocument, URL)? in
            guard let memoryInsightStoreURL else { return nil }
            return (persistenceDocument(now: Date()), memoryInsightStoreURL)
        }
        if let (document, url) = persistenceRequest {
            memoryInsightPersistence.saveImmediately(document: document, at: url)
        }
    }

    public func setMode(_ newMode: RuntimeMode) {
        lock.withLock {
            if mode != newMode {
                mode = newMode
                invalidateHealth()
            }
        }
    }

    public func updateSystemStatus(_ status: LocalSystemStatus) {
        lock.withLock {
            systemStatus = status
            diagnosticEngine.updateSystem(status)
            invalidateHealth()
            if status.totalMemoryMB > 0 {
                processMemoryHistory.append(MemoryTrendPoint(
                    time: status.sampledAt,
                    metric: "Roon Process Memory",
                    valueMB: status.totalMemoryMB,
                    source: "macOS process sampler"
                ))
                memoryTrendRevision += 1
                cachedMemoryTrend = nil
            }
            if status.sampledAt.timeIntervalSince(lastDiagnosticPersistenceScheduledAt) >= diagnosticPersistenceInterval {
                lastDiagnosticPersistenceScheduledAt = status.sampledAt
                scheduleMemoryInsightsSave()
            }
        }
    }

    public func setWatchedFiles(_ files: [String]) {
        lock.withLock {
            let currentFileSet = Set(files)
            sources = sources.filter { currentFileSet.contains($0.key) }
            sourceMetadataRefreshedAt = sourceMetadataRefreshedAt.filter { currentFileSet.contains($0.key) }
            for file in files {
                let key = file
                if sources[key] == nil {
                    sources[key] = sourceMetadata(
                        id: key,
                        path: file,
                        name: Self.displaySourceName(file),
                        lineCount: 0,
                        lastSeenAt: nil,
                        status: "watching"
                    )
                    sourceMetadataRefreshedAt[key] = Date()
                } else if var source = sources[key] {
                    source = sourceMetadata(
                        id: key,
                        path: file,
                        name: source.name,
                        lineCount: source.lineCount,
                        lastSeenAt: source.lastSeenAt,
                        status: source.status
                    )
                    sources[key] = source
                }
            }
            invalidateHealth()
        }
    }

    public func ingest(file: String, line: String, events: [RuntimeEvent], mode newMode: RuntimeMode) {
        lock.withLock {
            let wasFirstLine = processedLines == 0
            if mode != newMode {
                mode = newMode
                invalidateHealth()
            }
            processedLines += 1
            sequence += 1

            let now = Date()
            let severity = events.map(\.severity).maxSeverity ?? .info
            let sourceName = sources[file]?.name ?? Self.displaySourceName(file)
            let entry = LogLine(
                id: sequence,
                receivedAt: now,
                source: sourceName,
                text: Self.truncatedLogLine(line, maxCharacters: configuration.maxLogLineCharacters),
                severity: severity
            )
            lastReceivedLog = entry
            if configuration.showAllLogLines || !events.isEmpty {
                let evicted = logHistory.appendEvicting(entry)
                appendLogVolume(entry)
                if let evicted {
                    removeLogVolume(evicted)
                }
            }

            if !events.contains(where: { $0.domain == "memory" }) {
                let context = MemoryContextLine(
                    time: events.first?.time ?? timestampParser.parse(line, relativeTo: now) ?? now,
                    message: Self.truncatedLogLine(line, maxCharacters: min(configuration.maxLogLineCharacters, 600)),
                    source: sourceName,
                    byteCount: line.utf8.count
                )
                memoryContextHistory.append(context)
                updateMemoryInsights(with: context, now: now)
            }

            var source = sources[file] ?? sourceMetadata(
                id: file,
                path: file,
                name: sourceName,
                lineCount: 0,
                lastSeenAt: nil,
                status: "watching"
            )
            source.lineCount += 1
            source.lastSeenAt = now
            source.status = newMode == .demo ? "demo" : "live"
            if shouldRefreshSourceMetadata(file: file, now: now) {
                let metadata = Self.fileMetadata(file)
                source.lastModifiedAt = metadata?.modificationDate
                source.fileSizeBytes = metadata?.size
                source.isReadable = FileManager.default.isReadableFile(atPath: file)
                sourceMetadataRefreshedAt[file] = now
            }
            sources[file] = source

            if wasFirstLine || events.contains(where: Self.eventAffectsHealth) {
                invalidateHealth()
            }

            for event in events {
                timeline.append(event)
                switch event.severity {
                case .warning:
                    warningCount += 1
                    appendAlertIfNeeded(event)
                case .critical:
                    criticalCount += 1
                    appendAlertIfNeeded(event)
                case .info:
                    break
                }

                if event.domain == "playback" || event.domain == "raat" {
                    playback.append(event)
                }

                if event.domain == "memory", let value = event.valueMB {
                    let metric = MemoryMetric(
                        metric: event.title,
                        valueMB: value,
                        updatedAt: event.time,
                        source: event.source
                    )
                    memoryByMetric[event.title] = metric
                    memoryHistory.append(metric)
                    appendPhysicalMemoryTrendSampleIfNeeded(metric)
                }
            }
            if let sample = Self.memoryStatsSample(from: events, source: sourceName) {
                appendMemoryInsightIfNeeded(sample: sample, now: now)
            }
            diagnosticEngine.ingest(events: events, line: line, receivedAt: now, source: sourceName)
            pruneMemoryInsightHistory(now: now)
        }
    }

    public func recordSystemMessage(severity: Severity, title: String, message: String) {
        lock.withLock {
            let event = RuntimeEvent(
                id: UUID().uuidString,
                time: Date(),
                domain: "system",
                type: "system.message",
                severity: severity,
                title: title,
                message: message,
                source: "RoonLogWatcher",
                valueMB: nil,
                zone: nil
            )
            timeline.append(event)
            if severity != .info {
                alerts.append(event)
            }
            invalidateHealth()
        }
    }

    public func snapshot() -> RuntimeSnapshot {
        lock.withLock {
            makeSnapshot(now: Date(), compact: false, logsAfterID: nil)
        }
    }

    public func liveSnapshot(logsAfterID: Int? = nil) -> RuntimeSnapshot {
        lock.withLock {
            makeSnapshot(now: Date(), compact: true, logsAfterID: logsAfterID)
        }
    }

    public func alertCollection() -> [RuntimeEvent] {
        lock.withLock {
            visibleAlerts(now: Date())
        }
    }

    public func memoryInsightCollection() -> [MemoryInsight] {
        lock.withLock {
            visibleMemoryInsights(now: Date())
        }
    }

    public func playbackCollection() -> [RuntimeEvent] {
        lock.withLock {
            Array(playback.items.reversed())
        }
    }

    public func incidentCollection() -> [DiagnosticIncident] {
        lock.withLock {
            diagnosticEngine.incidentCollection(now: Date())
        }
    }

    private func makeSnapshot(now: Date, compact: Bool, logsAfterID: Int?) -> RuntimeSnapshot {
        let sortedSources = sources.values.sorted { $0.name < $1.name }
        let sortedMemory = memoryByMetric.values.sorted { $0.metric < $1.metric }
        let fullDiagnostics = diagnosticEngine.snapshot(now: now, compact: false)
        let health = currentHealth(now: now, sources: sortedSources, memory: sortedMemory, diagnostics: fullDiagnostics)

        let visibleInsights = visibleMemoryInsights(now: now)
        let allAlerts = visibleAlerts(now: now)
        let allPlayback = Array(playback.items.reversed())
        let diagnostics = compact ? diagnosticEngine.snapshot(now: now, compact: true) : fullDiagnostics
        let orderedRecentLogs = Array(
            logHistory.orderedSuffix(configuration.recentLogMaxLines).reversed()
        )
        let returnedLogs = logsAfterID.map { id in
            orderedRecentLogs.filter { $0.id > id }
        } ?? orderedRecentLogs

        return RuntimeSnapshot(
            ok: true,
            appName: "Roon Log Watcher",
            mode: mode,
            generatedAt: now,
            runStartedAt: runStartedAt,
            dashboardURL: dashboardURL,
            healthScore: health.score,
            health: health,
            healthTrend: compact ? Array(healthTrend.items.suffix(48)) : healthTrend.items,
            memoryTrend24h: memoryTrend24h(now: now),
            memoryInsights: compact ? Array(visibleInsights.prefix(3)) : visibleInsights,
            memoryInsightTotalCount: visibleInsights.count,
            system: systemStatus,
            watchedSources: sortedSources,
            memory: sortedMemory,
            recentLogs: returnedLogs,
            volumeBuckets: volumeBuckets(now: now),
            timeline: compact ? [] : Array(timeline.items.suffix(240).reversed()),
            alerts: compact ? compactAlertPreview(allAlerts) : allAlerts,
            alertTotalCount: allAlerts.count,
            warningAlertTotalCount: allAlerts.filter { $0.severity == .warning }.count,
            criticalAlertTotalCount: allAlerts.filter { $0.severity == .critical }.count,
            playback: compact ? Array(allPlayback.prefix(12)) : allPlayback,
            playbackTotalCount: allPlayback.count,
            diagnostics: diagnostics,
            counters: currentCounters()
        )
    }

    public func statusSummary() -> RuntimeStatusSummary {
        lock.withLock {
            let now = Date()
            let sortedSources = sources.values.sorted { $0.name < $1.name }
            let sortedMemory = memoryByMetric.values.sorted { $0.metric < $1.metric }
            let diagnostics = diagnosticEngine.snapshot(now: now, compact: false)
            let health = currentHealth(now: now, sources: sortedSources, memory: sortedMemory, diagnostics: diagnostics)
            return RuntimeStatusSummary(
                mode: mode,
                healthScore: health.score,
                health: health,
                alerts: visibleAlerts(now: now),
                counters: currentCounters()
            )
        }
    }

    private func currentHealth(
        now: Date,
        sources: [WatchedSource],
        memory: [MemoryMetric],
        diagnostics: DiagnosticAnalysisSnapshot
    ) -> RoonHealth {
        if let cache = cachedHealth,
           cache.revision == healthRevision,
           now < cache.validUntil {
            return refreshedHealth(cache.health, now: now)
        }

        let health = RoonHealthEvaluator(configuration: configuration).evaluate(
            now: now,
            mode: mode,
            sources: sources,
            latestLog: lastReceivedLog,
            events: timeline.items,
            memory: memory,
            memoryHistory: memoryHistory.items,
            system: systemStatus,
            processedLines: processedLines,
            diagnostics: diagnostics
        )
        cachedHealth = CachedHealth(
            revision: healthRevision,
            validUntil: now.addingTimeInterval(healthCacheInterval),
            health: health
        )
        appendHealthTrendIfNeeded(health, now: now)
        return health
    }

    private func refreshedHealth(_ health: RoonHealth, now: Date) -> RoonHealth {
        var refreshed = health
        refreshed.evaluatedAt = now
        refreshed.lastLogAt = lastReceivedLog?.receivedAt
        refreshed.lastLogAgeSeconds = lastReceivedLog.map { max(0, now.timeIntervalSince($0.receivedAt)) }

        if let latestLog = lastReceivedLog,
           let index = refreshed.signals.firstIndex(where: { $0.domain == "logs" }) {
            refreshed.signals[index].observedAt = latestLog.receivedAt
            refreshed.signals[index].ageSeconds = max(0, now.timeIntervalSince(latestLog.receivedAt))
            refreshed.signals[index].source = latestLog.source
        }
        return refreshed
    }

    private func invalidateHealth() {
        healthRevision &+= 1
        cachedHealth = nil
    }

    public func logExportText() -> String {
        lock.withLock {
            let formatter = ISO8601DateFormatter()
            return logHistory.items.map { line in
                "[\(formatter.string(from: line.receivedAt))] \(line.source): \(line.text)"
            }.joined(separator: "\n") + "\n"
        }
    }

    private func appendAlertIfNeeded(_ event: RuntimeEvent) {
        let now = Date()
        guard event.time >= runStartedAt.addingTimeInterval(-60),
              event.time >= now.addingTimeInterval(-alertSnapshotWindow)
        else { return }
        let key = "\(event.type)|\(event.source)|\(event.message)"
        if let last = recentAlertKeys[key], now.timeIntervalSince(last) < configuration.alertDedupeSeconds {
            return
        }
        recentAlertKeys[key] = now
        alerts.append(event)
        recentAlertKeys = recentAlertKeys.filter { now.timeIntervalSince($0.value) < 300 }
    }

    private func visibleAlerts(now: Date) -> [RuntimeEvent] {
        let cutoff = max(
            runStartedAt.addingTimeInterval(-60),
            now.addingTimeInterval(-alertSnapshotWindow)
        )
        return alerts.items
            .filter { $0.time >= cutoff }
            .sorted { $0.time > $1.time }
    }

    private func compactAlertPreview(_ allAlerts: [RuntimeEvent]) -> [RuntimeEvent] {
        let candidates = Array(allAlerts.prefix(24))
            + Array(allAlerts.filter { $0.severity == .warning }.prefix(8))
            + Array(allAlerts.filter { $0.severity == .critical }.prefix(8))
        var seen: Set<String> = []
        return candidates
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.time > $1.time }
    }

    private func appendHealthTrendIfNeeded(_ health: RoonHealth, now: Date) {
        let sample = RoonHealthTrendPoint(time: now, score: health.score, state: health.state)
        guard let previous = healthTrend.last else {
            healthTrend.append(sample)
            return
        }
        let rules = configuration.healthRules
        if now.timeIntervalSince(previous.time) >= rules.trendSampleSeconds
            || previous.state != health.state
            || abs(previous.score - health.score) >= 5 {
            healthTrend.append(sample)
        }
    }

    private func currentCounters() -> RuntimeCounters {
        RuntimeCounters(
            processedLines: processedLines,
            warningCount: warningCount,
            criticalCount: criticalCount,
            memoryPointCount: memoryByMetric.count,
            watchedFileCount: sources.count
        )
    }

    private func volumeBuckets(now: Date, bucketCount: Int = 60) -> [LogVolumeBucket] {
        let safeBucketCount = max(1, bucketCount)
        let windowSeconds = TimeInterval(configuration.logVolumeWindowMinutes * 60)
        let endInterval = floor(now.timeIntervalSince1970 / 60) * 60 + 60
        let end = Date(timeIntervalSince1970: endInterval)
        let start = end.addingTimeInterval(-windowSeconds)
        let bucketSeconds = windowSeconds / TimeInterval(safeBucketCount)
        var buckets = (0..<safeBucketCount).map { index in
            let bucketStart = start.addingTimeInterval(TimeInterval(index) * bucketSeconds)
            return LogVolumeBucket(
                startAt: bucketStart,
                endAt: bucketStart.addingTimeInterval(bucketSeconds),
                total: 0,
                warning: 0,
                critical: 0
            )
        }

        for (slice, counts) in logVolumeSlices {
            let receivedAt = Date(timeIntervalSince1970: TimeInterval(slice) * logVolumeSliceSeconds)
            guard receivedAt >= start && receivedAt <= end else { continue }
            let index = min(
                safeBucketCount - 1,
                max(0, Int(receivedAt.timeIntervalSince(start) / bucketSeconds))
            )
            buckets[index].total += counts.total
            buckets[index].warning += counts.warning
            buckets[index].critical += counts.critical
        }
        return buckets
    }

    private func appendLogVolume(_ line: LogLine) {
        let slice = Int(floor(line.receivedAt.timeIntervalSince1970 / logVolumeSliceSeconds))
        var counts = logVolumeSlices[slice] ?? LogVolumeCounts()
        counts.total += 1
        if line.severity == .warning { counts.warning += 1 }
        if line.severity == .critical { counts.critical += 1 }
        logVolumeSlices[slice] = counts
    }

    private func removeLogVolume(_ line: LogLine) {
        let slice = Int(floor(line.receivedAt.timeIntervalSince1970 / logVolumeSliceSeconds))
        guard var counts = logVolumeSlices[slice] else { return }
        counts.total = max(0, counts.total - 1)
        if line.severity == .warning { counts.warning = max(0, counts.warning - 1) }
        if line.severity == .critical { counts.critical = max(0, counts.critical - 1) }
        if counts.total == 0 {
            logVolumeSlices[slice] = nil
        } else {
            logVolumeSlices[slice] = counts
        }
    }

    private func rebuildLogVolumeSlices() {
        logVolumeSlices.removeAll(keepingCapacity: true)
        for line in logHistory.items {
            appendLogVolume(line)
        }
    }

    private func memoryTrend24h(now: Date, bucketCount: Int = 48) -> [MemoryTrendPoint] {
        if let cache = cachedMemoryTrend,
           cache.revision == memoryTrendRevision,
           cache.bucketCount == bucketCount,
           now < cache.validUntil {
            return cache.points
        }

        let windowStart = now.addingTimeInterval(-24 * 60 * 60)
        let processSamples = processMemoryHistory.items
            .filter { $0.time >= windowStart && $0.time <= now }
            .sorted { $0.time < $1.time }
        let physicalSamples = physicalMemoryTrendHistory.items
            .filter { $0.time >= windowStart && $0.time <= now }
            .sorted { $0.time < $1.time }
        let samples = physicalSamples.isEmpty ? processSamples : physicalSamples
        guard samples.count > bucketCount else {
            cachedMemoryTrend = CachedMemoryTrend(
                revision: memoryTrendRevision,
                bucketCount: bucketCount,
                validUntil: now.addingTimeInterval(memoryTrendCacheInterval),
                points: samples
            )
            return samples
        }

        let start = max(windowStart, samples.first?.time ?? windowStart)
        let bucketSeconds = max(1, now.timeIntervalSince(start)) / Double(max(1, bucketCount))
        var buckets = Array<MemoryTrendPoint?>(repeating: nil, count: max(1, bucketCount))
        for sample in samples {
            let index = min(
                buckets.count - 1,
                max(0, Int(sample.time.timeIntervalSince(start) / bucketSeconds))
            )
            buckets[index] = sample
        }
        let points = buckets.compactMap { $0 }
        cachedMemoryTrend = CachedMemoryTrend(
            revision: memoryTrendRevision,
            bucketCount: bucketCount,
            validUntil: now.addingTimeInterval(memoryTrendCacheInterval),
            points: points
        )
        return points
    }

    private func appendPhysicalMemoryTrendSampleIfNeeded(_ metric: MemoryMetric) {
        guard metric.metric == "Physical Memory" else { return }
        let point = MemoryTrendPoint(
            time: metric.updatedAt,
            metric: metric.metric,
            valueMB: metric.valueMB,
            source: metric.source
        )
        guard let previous = physicalMemoryTrendHistory.last else {
            physicalMemoryTrendHistory.append(point)
            memoryTrendRevision += 1
            cachedMemoryTrend = nil
            return
        }
        if point.time < previous.time
            || point.time.timeIntervalSince(previous.time) >= memoryTrendMinimumSampleInterval {
            physicalMemoryTrendHistory.append(point)
            memoryTrendRevision += 1
            cachedMemoryTrend = nil
        }
    }

    private func appendMemoryInsightIfNeeded(sample: MemoryStatsSample, now: Date) {
        defer { lastMemoryStatsSample = sample }
        guard let previous = lastMemoryStatsSample else { return }
        guard sample.time >= previous.time else { return }
        let windowSeconds = sample.time.timeIntervalSince(previous.time)
        guard windowSeconds > 0, windowSeconds <= 10 * 60 else { return }

        let deltaPhysical = sample.physicalMB - previous.physicalMB
        let deltaManaged = sample.managedMB.flatMap { current in previous.managedMB.map { current - $0 } }
        let deltaUnmanaged = sample.unmanagedMB.flatMap { current in previous.unmanagedMB.map { current - $0 } }
        let deltaVirtual = sample.virtualMB.flatMap { current in previous.virtualMB.map { current - $0 } }
        let deltaGCCommitted = sample.gcCommittedMB.flatMap { current in previous.gcCommittedMB.map { current - $0 } }
        let deltaGCPause = sample.gcPauseWindowPercent.flatMap { current in previous.gcPauseWindowPercent.map { current - $0 } }
        let isJump = abs(deltaPhysical) >= memoryJumpPhysicalThresholdMB
            || abs(deltaManaged ?? 0) >= memoryJumpManagedThresholdMB
            || abs(deltaUnmanaged ?? 0) >= memoryJumpUnmanagedThresholdMB
        guard isJump else { return }

        let related = relatedMemoryContext(around: sample.time)
        let category = Self.strongestMemoryCategory(from: related)
        let confidence = Self.memoryInsightConfidence(category: category, relatedEvents: related)
        let direction = deltaPhysical >= 0 ? "increase" : "decrease"
        let insight = MemoryInsight(
            id: "\(Int(sample.time.timeIntervalSince1970))-\(direction)-\(Int(abs(deltaPhysical).rounded()))",
            observedAt: sample.time,
            source: sample.source,
            direction: direction,
            category: category,
            confidence: confidence,
            summary: Self.memoryInsightSummary(direction: direction, category: category, deltaPhysicalMB: deltaPhysical, relatedCount: related.count),
            windowSeconds: windowSeconds,
            beforePhysicalMB: previous.physicalMB,
            afterPhysicalMB: sample.physicalMB,
            deltaPhysicalMB: deltaPhysical,
            deltaManagedMB: deltaManaged,
            deltaUnmanagedMB: deltaUnmanaged,
            deltaVirtualMB: deltaVirtual,
            relatedEvents: Array(related.prefix(6)),
            deltaGCCommittedMB: deltaGCCommitted,
            deltaGCPauseWindowPercent: deltaGCPause
        )
        memoryInsights.append(insight)
        scheduleMemoryInsightsSave()
    }

    private func updateMemoryInsights(with context: MemoryContextLine, now: Date) {
        guard memoryInsights.containsInSuffix(8, where: {
            abs(context.time.timeIntervalSince($0.observedAt)) <= memoryInsightContextWindow
        })
        else { return }

        let existingInsights = memoryInsights.items
        var updated = false
        let nextInsights = existingInsights.map { insight -> MemoryInsight in
            guard abs(context.time.timeIntervalSince(insight.observedAt)) <= memoryInsightContextWindow else {
                return insight
            }
            guard let evidence = Self.memoryContextEvidence(from: context, around: insight.observedAt) else {
                return insight
            }
            guard !insight.relatedEvents.contains(where: { $0.time == evidence.time && $0.message == evidence.message }) else {
                return insight
            }

            var copy = insight
            copy.relatedEvents.append(evidence)
            copy.relatedEvents = Array(Self.sortedMemoryEvidence(copy.relatedEvents, around: copy.observedAt).prefix(6))
            copy.category = Self.strongestMemoryCategory(from: copy.relatedEvents)
            copy.confidence = Self.memoryInsightConfidence(category: copy.category, relatedEvents: copy.relatedEvents)
            copy.summary = Self.memoryInsightSummary(
                direction: copy.direction,
                category: copy.category,
                deltaPhysicalMB: copy.deltaPhysicalMB,
                relatedCount: copy.relatedEvents.count
            )
            updated = true
            return copy
        }
        if updated {
            memoryInsights.replace(with: nextInsights)
            pruneMemoryInsightHistory(now: now)
            scheduleMemoryInsightsSave()
        }
    }

    private func relatedMemoryContext(around date: Date) -> [MemoryInsightEvidence] {
        let start = date.addingTimeInterval(-memoryInsightContextWindow)
        let end = date.addingTimeInterval(memoryInsightContextWindow)
        return Self.sortedMemoryEvidence(
            memoryContextHistory.items.compactMap { context in
                guard context.time >= start && context.time <= end else { return nil }
                return Self.memoryContextEvidence(from: context, around: date)
            },
            around: date
        )
    }

    private func visibleMemoryInsights(now: Date) -> [MemoryInsight] {
        let cutoff = now.addingTimeInterval(-memoryInsightRetention)
        return memoryInsights.items
            .filter { $0.observedAt >= cutoff }
            .sorted { $0.observedAt > $1.observedAt }
    }

    private func pruneMemoryInsightHistory(now: Date) {
        guard now.timeIntervalSince(lastMemoryInsightPruneAt) >= memoryInsightPruneInterval else { return }
        lastMemoryInsightPruneAt = now
        let cutoff = now.addingTimeInterval(-memoryInsightRetention)
        let contextCutoff = now.addingTimeInterval(-memoryContextRetention)
        let volumeCutoff = Int(floor(now.addingTimeInterval(-maximumLogVolumeWindow - 60).timeIntervalSince1970 / logVolumeSliceSeconds))
        let insightCount = memoryInsights.count
        memoryInsights.removeAll { $0.observedAt < cutoff }
        memoryContextHistory.removeAll { $0.time < contextCutoff }
        logVolumeSlices = logVolumeSlices.filter { $0.key >= volumeCutoff }
        if memoryInsights.count != insightCount {
            scheduleMemoryInsightsSave()
        }
    }

    private func loadMemoryInsights() {
        guard let memoryInsightStoreURL,
              let data = try? Data(contentsOf: memoryInsightStoreURL)
        else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(MemoryInsightDocument.self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-memoryInsightRetention)
        memoryInsights.replace(with: document.insights.filter { $0.observedAt >= cutoff }.sorted { $0.observedAt < $1.observedAt })
        if let diagnostics = document.diagnostics {
            diagnosticEngine.restore(diagnostics)
        }
    }

    private func scheduleMemoryInsightsSave() {
        guard let memoryInsightStoreURL else { return }
        memoryInsightPersistence.schedule(
            document: persistenceDocument(now: Date()),
            at: memoryInsightStoreURL
        )
    }

    private func persistenceDocument(now: Date) -> MemoryInsightDocument {
        MemoryInsightDocument(
            insights: memoryInsights.items,
            diagnostics: diagnosticEngine.persistenceState(now: now)
        )
    }

    private static func memoryStatsSample(from events: [RuntimeEvent], source: String) -> MemoryStatsSample? {
        let memoryEvents = events.filter { $0.domain == "memory" }
        guard let physical = memoryEvents.first(where: { $0.title == "Physical Memory" })?.valueMB else { return nil }
        return MemoryStatsSample(
            time: memoryEvents.first(where: { $0.title == "Physical Memory" })?.time ?? memoryEvents.first?.time ?? Date(),
            source: source,
            physicalMB: physical,
            managedMB: memoryEvents.first(where: { $0.title == "Managed Memory" })?.valueMB,
            unmanagedMB: memoryEvents.first(where: { $0.title == "Unmanaged Memory" || $0.title == "Native Memory" })?.valueMB,
            virtualMB: memoryEvents.first(where: { $0.title == "Virtual Memory" })?.valueMB,
            gcCommittedMB: memoryEvents.first(where: { $0.title == "GC Committed Memory" })?.valueMB,
            gcPauseWindowPercent: events.first(where: { $0.title == "GC Pause Window Percent" })?.numericValue
        )
    }

    private static func eventAffectsHealth(_ event: RuntimeEvent) -> Bool {
        event.severity != .info
            || ["memory", "runtime", "server", "database", "raat", "playback", "device"].contains(event.domain)
    }

    private static func memoryContextEvidence(from context: MemoryContextLine, around date: Date) -> MemoryInsightEvidence? {
        let lower = context.message.lowercased()
        guard !lower.contains("[stats]") else { return nil }
        guard let category = memoryContextCategory(lower) else { return nil }
        return MemoryInsightEvidence(
            id: UUID().uuidString,
            time: context.time,
            category: category,
            title: memoryCategoryTitle(category),
            message: context.message,
            source: context.source,
            byteCount: context.byteCount,
            relativeSeconds: context.time.timeIntervalSince(date),
            relation: context.time <= date ? "before" : "after"
        )
    }

    private static func memoryContextCategory(_ lower: String) -> String? {
        if containsAny(lower, ["[roonapi]", "[roonapi/registry]", "subscribe_queue", "continue subscribed", "apiclient"]) {
            return "extension"
        }
        if containsAny(lower, ["[broker/database/vacuum]", "validating database", "finished validation", "[leveldb]"]) {
            return "maintenance"
        }
        if containsAny(lower, ["starting roon", "roonserver start", "server startup", "loaded 100", "loaded ", "cache entries", "adding storage location", "media availability", "initializing filebrowser", "created disabled location"]) {
            return "startup"
        }
        if containsAny(lower, ["metadatasvc", "metadata", "updatemetadata", "identification", "clumping", "dirty tracks", "dirty albums"]) {
            return "metadata"
        }
        if containsAny(lower, ["[library]", "library stats", "library/compute", "computing ", "cleanup", "tracks:", "albums:", "import", "analysis", "scanner"]) {
            return "library"
        }
        if containsAny(lower, ["tidal", "qobuz", "favorite albums", "favorite tracks", "favorite playlists", "playlists cached", "[swim]", "broker/accounts"]) {
            return "streaming"
        }
        if containsAny(lower, ["httpcache", "filecache", "image", "cache", "coverart", "artwork"]) {
            return "cache"
        }
        if containsAny(lower, ["raat", "playback", "zone", "transport", "audio", "buffering", "signalpath"]) {
            return "playback"
        }
        if containsAny(lower, ["database", "sqlite", "query", "checkpoint", "vacuum"]) {
            return "database"
        }
        if containsAny(lower, ["[mobile]", "multinat", "remoteconnectivity", "port mapping"]) {
            return "remote"
        }
        if containsAny(lower, ["easyhttp", "timeout", "network", "api.roonlabs.net"]) {
            return "network"
        }
        if containsAny(lower, ["warn:", "error:", "exception", "failed"]) {
            return "log"
        }
        return nil
    }

    private static func strongestMemoryCategory(from evidence: [MemoryInsightEvidence]) -> String {
        guard !evidence.isEmpty else { return "unknown" }
        let weights = [
            "extension": 6,
            "maintenance": 5,
            "startup": 4,
            "metadata": 4,
            "library": 3,
            "streaming": 3,
            "cache": 2,
            "playback": 2,
            "database": 2,
            "remote": 1,
            "network": 1,
            "log": 1
        ]
        let scores = evidence.reduce(into: [String: Double]()) { result, item in
            let relative = item.relativeSeconds ?? 0
            let temporalWeight: Double
            if relative <= 0 {
                temporalWeight = abs(relative) <= 60 ? 2.0 : 1.25
            } else {
                temporalWeight = relative <= 30 ? 0.8 : 0.45
            }
            let bytes = Double(item.byteCount ?? 0)
            let payloadWeight = 1 + min(4, log2(max(1, bytes / 1_024 + 1)))
            result[item.category, default: 0] += Double(weights[item.category, default: 1]) * temporalWeight * payloadWeight
        }
        return scores.sorted {
            if $0.value == $1.value {
                return memoryCategoryRank($0.key) < memoryCategoryRank($1.key)
            }
            return $0.value > $1.value
        }.first?.key ?? "unknown"
    }

    private static func memoryInsightConfidence(category: String, relatedEvents: [MemoryInsightEvidence]) -> Double {
        guard category != "unknown", !relatedEvents.isEmpty else { return 0.2 }
        let matching = relatedEvents.filter { $0.category == category }.count
        return min(0.95, 0.35 + Double(relatedEvents.count) * 0.06 + Double(matching) * 0.08)
    }

    private static func memoryInsightSummary(direction: String, category: String, deltaPhysicalMB: Double, relatedCount: Int) -> String {
        let sign = deltaPhysicalMB >= 0 ? "+" : "-"
        let amount = "\(sign)\(Int(abs(deltaPhysicalMB).rounded())) MB"
        let directionText = direction == "increase" ? "increase" : "release"
        let categoryText = memoryCategoryTitle(category).lowercased()
        if category == "unknown" {
            return "Memory \(directionText) \(amount); no clear nearby log cause found."
        }
        return "Memory \(directionText) \(amount) near \(categoryText) activity (\(relatedCount) related log lines)."
    }

    private static func memoryCategoryTitle(_ category: String) -> String {
        switch category {
        case "extension": return "Roon API synchronization"
        case "maintenance": return "Database maintenance"
        case "startup": return "Startup / warm-up"
        case "metadata": return "Metadata update"
        case "library": return "Library work"
        case "streaming": return "Streaming-service sync"
        case "cache": return "Cache / image work"
        case "playback": return "Playback / RAAT"
        case "database": return "Database activity"
        case "remote": return "Remote access activity"
        case "network": return "Network/API activity"
        case "log": return "Log warning"
        default: return "Unknown"
        }
    }

    private static func memoryCategoryRank(_ category: String) -> Int {
        ["extension", "maintenance", "startup", "metadata", "library", "streaming", "cache", "playback", "database", "remote", "network", "log", "unknown"].firstIndex(of: category) ?? 99
    }

    private static func containsAny(_ lower: String, _ patterns: [String]) -> Bool {
        patterns.contains { lower.contains($0) }
    }

    private static func sortedMemoryEvidence(_ evidence: [MemoryInsightEvidence], around date: Date) -> [MemoryInsightEvidence] {
        evidence.sorted {
            let left = abs($0.time.timeIntervalSince(date))
            let right = abs($1.time.timeIntervalSince(date))
            if left == right {
                return memoryCategoryRank($0.category) < memoryCategoryRank($1.category)
            }
            return left < right
        }
    }

    private func shouldRefreshSourceMetadata(file: String, now: Date) -> Bool {
        guard !file.hasPrefix("/Demo/") else { return false }
        guard let previous = sourceMetadataRefreshedAt[file] else { return true }
        return now.timeIntervalSince(previous) >= sourceMetadataRefreshInterval
    }

    private func sourceMetadata(
        id: String,
        path: String,
        name: String,
        lineCount: Int,
        lastSeenAt: Date?,
        status: String
    ) -> WatchedSource {
        let metadata = Self.fileMetadata(path)
        return WatchedSource(
            id: id,
            path: path,
            name: name,
            lineCount: lineCount,
            lastSeenAt: lastSeenAt,
            status: status,
            lastModifiedAt: metadata?.modificationDate,
            fileSizeBytes: metadata?.size,
            isReadable: FileManager.default.isReadableFile(atPath: path)
        )
    }

    private static func displaySourceName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let file = url.lastPathComponent.isEmpty ? "log" : url.lastPathComponent
        let parent = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        if parent.isEmpty {
            return file
        }
        return "\(parent)/\(file)"
    }

    private static func truncatedLogLine(_ line: String, maxCharacters: Int) -> String {
        guard line.count > maxCharacters else {
            return line
        }
        return String(line.prefix(maxCharacters)) + " ... [truncated]"
    }

    private static func fileMetadata(_ path: String) -> (size: UInt64?, modificationDate: Date?)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (
            (attributes[.size] as? NSNumber)?.uint64Value,
            attributes[.modificationDate] as? Date
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private struct MemoryStatsSample {
    var time: Date
    var source: String
    var physicalMB: Double
    var managedMB: Double?
    var unmanagedMB: Double?
    var virtualMB: Double?
    var gcCommittedMB: Double?
    var gcPauseWindowPercent: Double?
}

private struct MemoryContextLine {
    var time: Date
    var message: String
    var source: String
    var byteCount: Int
}

private struct LogVolumeCounts {
    var total = 0
    var warning = 0
    var critical = 0
}

private struct CachedHealth {
    var revision: Int
    var validUntil: Date
    var health: RoonHealth
}

private struct CachedMemoryTrend {
    var revision: Int
    var bucketCount: Int
    var validUntil: Date
    var points: [MemoryTrendPoint]
}

private struct MemoryInsightDocument: Codable, Sendable {
    var insights: [MemoryInsight]
    var diagnostics: DiagnosticPersistenceState? = nil
}

private final class MemoryInsightPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RoonLogWatcher.MemoryInsightPersistence", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var lastWrittenData: Data?

    func schedule(document: MemoryInsightDocument, at url: URL) {
        let scheduledGeneration = lock.withLock {
            generation += 1
            return generation
        }

        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  self.lock.withLock({ self.generation == scheduledGeneration })
            else { return }

            self.write(document: document, to: url)
        }
    }

    func saveImmediately(document: MemoryInsightDocument, at url: URL) {
        lock.withLock {
            generation += 1
        }
        queue.sync {
            write(document: document, to: url)
        }
    }

    private func write(document: MemoryInsightDocument, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(document)
            guard lock.withLock({ lastWrittenData != data }) else { return }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            lock.withLock {
                lastWrittenData = data
            }
        } catch {
            // Persistence is best-effort; live diagnostics should continue if the cache cannot be written.
        }
    }
}

private extension Array where Element == Severity {
    var maxSeverity: Severity? {
        if contains(.critical) { return .critical }
        if contains(.warning) { return .warning }
        if contains(.info) { return .info }
        return nil
    }
}
