import Foundation

public final class RuntimeStore {
    private let lock = NSLock()
    private let configuration: AppConfiguration
    private let runStartedAt = Date()
    private var mode: RuntimeMode = .idle
    private var dashboardURL: String?
    private var sequence = 0
    private var recentLogs: BoundedArray<LogLine>
    private var logHistory: BoundedArray<LogLine>
    private var timeline = BoundedArray<RuntimeEvent>(limit: 1_000)
    private var alerts = BoundedArray<RuntimeEvent>(limit: 500)
    private var playback = BoundedArray<RuntimeEvent>(limit: 240)
    private var memoryByMetric: [String: MemoryMetric] = [:]
    private var memoryHistory = BoundedArray<MemoryMetric>(limit: 5_760)
    private var processMemoryHistory = BoundedArray<MemoryTrendPoint>(limit: 2_880)
    private var sources: [String: WatchedSource] = [:]
    private var systemStatus: LocalSystemStatus?
    private var healthTrend = BoundedArray<RoonHealthTrendPoint>(limit: 2_880)
    private var recentAlertKeys: [String: Date] = [:]
    private var processedLines = 0
    private var warningCount = 0
    private var criticalCount = 0

    public init(configuration: AppConfiguration = .default) {
        self.configuration = configuration.normalized()
        self.recentLogs = BoundedArray<LogLine>(limit: self.configuration.recentLogMaxLines)
        self.logHistory = BoundedArray<LogLine>(limit: self.configuration.logHistoryMaxLines)
    }

    public func setDashboardURL(_ url: URL?) {
        lock.withLock {
            dashboardURL = url?.absoluteString
        }
    }

    public func setMode(_ newMode: RuntimeMode) {
        lock.withLock {
            mode = newMode
        }
    }

    public func updateSystemStatus(_ status: LocalSystemStatus) {
        lock.withLock {
            systemStatus = status
            if status.totalMemoryMB > 0 {
                processMemoryHistory.append(MemoryTrendPoint(
                    time: status.sampledAt,
                    metric: "Roon Process Memory",
                    valueMB: status.totalMemoryMB,
                    source: "macOS process sampler"
                ))
            }
        }
    }

    public func setWatchedFiles(_ files: [String]) {
        lock.withLock {
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
        }
    }

    public func ingest(file: String, line: String, events: [RuntimeEvent], mode newMode: RuntimeMode) {
        lock.withLock {
            mode = newMode
            processedLines += 1
            sequence += 1

            let now = Date()
            let severity = events.map(\.severity).maxSeverity ?? .info
            let sourceName = Self.displaySourceName(file)
            let entry = LogLine(
                id: sequence,
                receivedAt: now,
                source: sourceName,
                text: Self.truncatedLogLine(line, maxCharacters: configuration.maxLogLineCharacters),
                severity: severity
            )
            recentLogs.append(entry)
            logHistory.append(entry)

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
            source.lastModifiedAt = Self.modificationDate(file)
            source.fileSizeBytes = Self.fileSize(file)
            source.isReadable = FileManager.default.isReadableFile(atPath: file)
            sources[file] = source

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
                }
            }
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
        }
    }

    public func snapshot() -> RuntimeSnapshot {
        lock.withLock {
            let now = Date()
            let sortedSources = sources.values.sorted { $0.name < $1.name }
            let sortedMemory = memoryByMetric.values.sorted { $0.metric < $1.metric }
            let health = RoonHealthEvaluator(configuration: configuration).evaluate(
                now: now,
                mode: mode,
                sources: sortedSources,
                logs: logHistory.items,
                events: timeline.items,
                memory: sortedMemory,
                memoryHistory: memoryHistory.items,
                system: systemStatus,
                processedLines: processedLines
            )
            appendHealthTrendIfNeeded(health, now: now)
            return RuntimeSnapshot(
                ok: true,
                appName: "Roon Log Watcher",
                mode: mode,
                generatedAt: now,
                runStartedAt: runStartedAt,
                dashboardURL: dashboardURL,
                healthScore: health.score,
                health: health,
                healthTrend: healthTrend.items,
                memoryTrend24h: memoryTrend24h(now: now),
                system: systemStatus,
                watchedSources: sortedSources,
                memory: sortedMemory,
                recentLogs: recentLogs.items.reversed(),
                volumeBuckets: volumeBuckets(now: now),
                timeline: timeline.items.reversed(),
                alerts: alerts.items.reversed(),
                playback: playback.items.reversed(),
                counters: currentCounters()
            )
        }
    }

    public func statusSummary() -> RuntimeStatusSummary {
        lock.withLock {
            let now = Date()
            let sortedSources = sources.values.sorted { $0.name < $1.name }
            let sortedMemory = memoryByMetric.values.sorted { $0.metric < $1.metric }
            let health = RoonHealthEvaluator(configuration: configuration).evaluate(
                now: now,
                mode: mode,
                sources: sortedSources,
                logs: logHistory.items,
                events: timeline.items,
                memory: sortedMemory,
                memoryHistory: memoryHistory.items,
                system: systemStatus,
                processedLines: processedLines
            )
            appendHealthTrendIfNeeded(health, now: now)
            return RuntimeStatusSummary(
                mode: mode,
                healthScore: health.score,
                health: health,
                alerts: alerts.items.reversed(),
                counters: currentCounters()
            )
        }
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
        let key = "\(event.type)|\(event.source)|\(event.message)"
        if let last = recentAlertKeys[key], now.timeIntervalSince(last) < configuration.alertDedupeSeconds {
            return
        }
        recentAlertKeys[key] = now
        alerts.append(event)
        recentAlertKeys = recentAlertKeys.filter { now.timeIntervalSince($0.value) < 300 }
    }

    private func appendHealthTrendIfNeeded(_ health: RoonHealth, now: Date) {
        let sample = RoonHealthTrendPoint(time: now, score: health.score, state: health.state)
        guard let previous = healthTrend.items.last else {
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

        for line in logHistory.items {
            guard line.receivedAt >= start && line.receivedAt <= end else { continue }
            let index = min(
                safeBucketCount - 1,
                max(0, Int(line.receivedAt.timeIntervalSince(start) / bucketSeconds))
            )
            buckets[index].total += 1
            switch line.severity {
            case .warning:
                buckets[index].warning += 1
            case .critical:
                buckets[index].critical += 1
            case .info:
                break
            }
        }
        return buckets
    }

    private func memoryTrend24h(now: Date, bucketCount: Int = 48) -> [MemoryTrendPoint] {
        let start = now.addingTimeInterval(-24 * 60 * 60)
        let processSamples = processMemoryHistory.items
            .filter { $0.time >= start && $0.time <= now }
            .sorted { $0.time < $1.time }
        let physicalSamples = memoryHistory.items
            .filter { $0.metric == "Physical Memory" && $0.updatedAt >= start && $0.updatedAt <= now }
            .sorted { $0.updatedAt < $1.updatedAt }
            .map {
                MemoryTrendPoint(
                    time: $0.updatedAt,
                    metric: $0.metric,
                    valueMB: $0.valueMB,
                    source: $0.source
                )
            }
        let samples = processSamples.isEmpty ? physicalSamples : processSamples
        guard samples.count > bucketCount else { return samples }

        let bucketSeconds = now.timeIntervalSince(start) / Double(max(1, bucketCount))
        var buckets = Array<MemoryTrendPoint?>(repeating: nil, count: max(1, bucketCount))
        for sample in samples {
            let index = min(
                buckets.count - 1,
                max(0, Int(sample.time.timeIntervalSince(start) / bucketSeconds))
            )
            buckets[index] = sample
        }
        return buckets.compactMap { $0 }
    }

    private func sourceMetadata(
        id: String,
        path: String,
        name: String,
        lineCount: Int,
        lastSeenAt: Date?,
        status: String
    ) -> WatchedSource {
        WatchedSource(
            id: id,
            path: path,
            name: name,
            lineCount: lineCount,
            lastSeenAt: lastSeenAt,
            status: status,
            lastModifiedAt: Self.modificationDate(path),
            fileSizeBytes: Self.fileSize(path),
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

    private static func fileSize(_ path: String) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
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
