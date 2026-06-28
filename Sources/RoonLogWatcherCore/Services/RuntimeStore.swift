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
    private var physicalMemoryTrendHistory = BoundedArray<MemoryTrendPoint>(limit: 2_880)
    private var processMemoryHistory = BoundedArray<MemoryTrendPoint>(limit: 2_880)
    private var memoryContextHistory = BoundedArray<MemoryInsightEvidence>(limit: 20_000)
    private var memoryInsights = BoundedArray<MemoryInsight>(limit: 1_000)
    private var lastMemoryStatsSample: MemoryStatsSample?
    private var sources: [String: WatchedSource] = [:]
    private var systemStatus: LocalSystemStatus?
    private var healthTrend = BoundedArray<RoonHealthTrendPoint>(limit: 2_880)
    private var recentAlertKeys: [String: Date] = [:]
    private var processedLines = 0
    private var warningCount = 0
    private var criticalCount = 0
    private let memoryInsightStoreURL: URL?
    private let alertSnapshotWindow: TimeInterval = 12 * 60 * 60
    private let memoryTrendMinimumSampleInterval: TimeInterval = 30
    private let memoryInsightRetention: TimeInterval = 7 * 24 * 60 * 60
    private let memoryInsightContextWindow: TimeInterval = 2 * 60
    private let memoryJumpPhysicalThresholdMB: Double = 150
    private let memoryJumpManagedThresholdMB: Double = 250
    private let memoryJumpUnmanagedThresholdMB: Double = 250

    public init(configuration: AppConfiguration = .default, memoryInsightStoreURL: URL? = nil) {
        self.configuration = configuration.normalized()
        self.memoryInsightStoreURL = memoryInsightStoreURL
        self.recentLogs = BoundedArray<LogLine>(limit: self.configuration.recentLogMaxLines)
        self.logHistory = BoundedArray<LogLine>(limit: self.configuration.logHistoryMaxLines)
        loadMemoryInsights()
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
            let currentFileSet = Set(files)
            sources = sources.filter { currentFileSet.contains($0.key) }
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
            if let context = Self.memoryContextEvidence(
                line: line,
                source: sourceName,
                time: Self.extractTimestamp(from: line) ?? events.first?.time ?? now,
                maxCharacters: configuration.maxLogLineCharacters
            ) {
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
                    appendPhysicalMemoryTrendSampleIfNeeded(metric)
                }
            }
            if let sample = Self.memoryStatsSample(from: events, source: sourceName) {
                appendMemoryInsightIfNeeded(sample: sample, now: now)
            }
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
                memoryInsights: visibleMemoryInsights(now: now),
                system: systemStatus,
                watchedSources: sortedSources,
                memory: sortedMemory,
                recentLogs: recentLogs.items.reversed(),
                volumeBuckets: volumeBuckets(now: now),
                timeline: Array(timeline.items.suffix(240).reversed()),
                alerts: visibleAlerts(now: now),
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
                alerts: visibleAlerts(now: now),
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
        let windowStart = now.addingTimeInterval(-24 * 60 * 60)
        let processSamples = processMemoryHistory.items
            .filter { $0.time >= windowStart && $0.time <= now }
            .sorted { $0.time < $1.time }
        let physicalSamples = physicalMemoryTrendHistory.items
            .filter { $0.time >= windowStart && $0.time <= now }
            .sorted { $0.time < $1.time }
        let samples = physicalSamples.isEmpty ? processSamples : physicalSamples
        guard samples.count > bucketCount else { return samples }

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
        return buckets.compactMap { $0 }
    }

    private func appendPhysicalMemoryTrendSampleIfNeeded(_ metric: MemoryMetric) {
        guard metric.metric == "Physical Memory" else { return }
        let point = MemoryTrendPoint(
            time: metric.updatedAt,
            metric: metric.metric,
            valueMB: metric.valueMB,
            source: metric.source
        )
        guard let previous = physicalMemoryTrendHistory.items.last else {
            physicalMemoryTrendHistory.append(point)
            return
        }
        if point.time < previous.time
            || point.time.timeIntervalSince(previous.time) >= memoryTrendMinimumSampleInterval {
            physicalMemoryTrendHistory.append(point)
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
            relatedEvents: Array(related.prefix(6))
        )
        memoryInsights.append(insight)
        saveMemoryInsights()
    }

    private func updateMemoryInsights(with evidence: MemoryInsightEvidence, now: Date) {
        var updated = false
        let nextInsights = memoryInsights.items.map { insight -> MemoryInsight in
            guard abs(evidence.time.timeIntervalSince(insight.observedAt)) <= memoryInsightContextWindow else {
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
            saveMemoryInsights()
        }
    }

    private func relatedMemoryContext(around date: Date) -> [MemoryInsightEvidence] {
        let start = date.addingTimeInterval(-memoryInsightContextWindow)
        let end = date.addingTimeInterval(memoryInsightContextWindow)
        return Self.sortedMemoryEvidence(
            memoryContextHistory.items.filter { $0.time >= start && $0.time <= end },
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
        let cutoff = now.addingTimeInterval(-memoryInsightRetention)
        let insightCount = memoryInsights.items.count
        memoryInsights.removeAll { $0.observedAt < cutoff }
        memoryContextHistory.removeAll { $0.time < cutoff }
        if memoryInsights.items.count != insightCount {
            saveMemoryInsights()
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
    }

    private func saveMemoryInsights() {
        guard let memoryInsightStoreURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let document = MemoryInsightDocument(insights: memoryInsights.items)
        do {
            try FileManager.default.createDirectory(at: memoryInsightStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(document)
            try data.write(to: memoryInsightStoreURL, options: [.atomic])
        } catch {
            // Persistence is best-effort; live diagnostics should continue even if the cache cannot be written.
        }
    }

    private static func memoryStatsSample(from events: [RuntimeEvent], source: String) -> MemoryStatsSample? {
        let memoryEvents = events.filter { $0.domain == "memory" }
        guard let physical = memoryEvents.first(where: { $0.title == "Physical Memory" })?.valueMB else { return nil }
        return MemoryStatsSample(
            time: memoryEvents.first(where: { $0.title == "Physical Memory" })?.time ?? memoryEvents.first?.time ?? Date(),
            source: source,
            physicalMB: physical,
            managedMB: memoryEvents.first(where: { $0.title == "Managed Memory" })?.valueMB,
            unmanagedMB: memoryEvents.first(where: { $0.title == "Unmanaged Memory" })?.valueMB,
            virtualMB: memoryEvents.first(where: { $0.title == "Virtual Memory" })?.valueMB
        )
    }

    private static func memoryContextEvidence(line: String, source: String, time: Date, maxCharacters: Int) -> MemoryInsightEvidence? {
        let lower = line.lowercased()
        guard !lower.contains("[stats]") else { return nil }
        guard let category = memoryContextCategory(lower) else { return nil }
        return MemoryInsightEvidence(
            id: UUID().uuidString,
            time: time,
            category: category,
            title: memoryCategoryTitle(category),
            message: truncatedLogLine(line, maxCharacters: min(maxCharacters, 600)),
            source: source
        )
    }

    private static func memoryContextCategory(_ lower: String) -> String? {
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
            "startup": 4,
            "metadata": 4,
            "library": 3,
            "streaming": 3,
            "cache": 2,
            "playback": 2,
            "database": 2,
            "network": 1,
            "log": 1
        ]
        let scores = evidence.reduce(into: [String: Int]()) { result, item in
            result[item.category, default: 0] += weights[item.category, default: 1]
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
        case "startup": return "Startup / warm-up"
        case "metadata": return "Metadata update"
        case "library": return "Library work"
        case "streaming": return "Streaming-service sync"
        case "cache": return "Cache / image work"
        case "playback": return "Playback / RAAT"
        case "database": return "Database activity"
        case "network": return "Network/API activity"
        case "log": return "Log warning"
        default: return "Unknown"
        }
    }

    private static func memoryCategoryRank(_ category: String) -> Int {
        ["startup", "metadata", "library", "streaming", "cache", "playback", "database", "network", "log", "unknown"].firstIndex(of: category) ?? 99
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

    private static func extractTimestamp(from line: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{2})/(\d{2})\s+(\d{2}):(\d{2}):(\d{2})"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              match.numberOfRanges == 6
        else { return nil }

        func value(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return Int(line[range])
        }

        var components = Calendar.current.dateComponents([.year], from: Date())
        components.month = value(1)
        components.day = value(2)
        components.hour = value(3)
        components.minute = value(4)
        components.second = value(5)
        return Calendar.current.date(from: components)
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

private struct MemoryStatsSample {
    var time: Date
    var source: String
    var physicalMB: Double
    var managedMB: Double?
    var unmanagedMB: Double?
    var virtualMB: Double?
}

private struct MemoryInsightDocument: Codable {
    var insights: [MemoryInsight]
}

private extension Array where Element == Severity {
    var maxSeverity: Severity? {
        if contains(.critical) { return .critical }
        if contains(.warning) { return .warning }
        if contains(.info) { return .info }
        return nil
    }
}
