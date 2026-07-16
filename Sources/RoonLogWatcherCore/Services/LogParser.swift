import Foundation

public struct LogParser {
    private let nowProvider: () -> Date
    private let timestampParser = RoonLogTimestampParser()
    private let memoryPatterns: [(metric: String, regex: NSRegularExpression)]
    private let currentStatsRegex: NSRegularExpression?
    private let namedZoneRegex: NSRegularExpression?
    private let playbackZoneRegex: NSRegularExpression?
    private let raatEndpointRegex: NSRegularExpression?
    private let raatDeviceRegex: NSRegularExpression?
    private let roonAPIClientRegex: NSRegularExpression?
    private let backupProgressRegex: NSRegularExpression?
    private let metadataPendingRegex: NSRegularExpression?
    private let metadataQueueRegex: NSRegularExpression?
    private let easyHTTPRegex: NSRegularExpression?
    private let streamingDownloadRegex: NSRegularExpression?
    private let dbPerformanceRegex: NSRegularExpression?
    private let libraryMutationRegex: NSRegularExpression?
    private let storageScanRegex: NSRegularExpression?
    private let libraryStatsRegex: NSRegularExpression?

    public init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
        self.memoryPatterns = [
            ("Virtual Memory", #"(\d+(?:\.\d+)?)\s*(kb|kib|mb|mib|gb|gib)\s+Virtual\b"#),
            ("Physical Memory", #"(\d+(?:\.\d+)?)\s*(kb|kib|mb|mib|gb|gib)\s+Physical\b"#),
            ("Managed Memory", #"(\d+(?:\.\d+)?)\s*(kb|kib|mb|mib|gb|gib)\s+Managed\b"#),
            ("Unmanaged Memory", #"(\d+(?:\.\d+)?)\s*(kb|kib|mb|mib|gb|gib)\s+(?:estimated\s+)?Unmanaged\b"#)
        ].compactMap { metric, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (metric, regex)
        }
        self.currentStatsRegex = try? NSRegularExpression(
            pattern: #"([+-]?\d+(?:[.,]\d+)?)\s*(?:mb|mib)\s+Virtual;\s*([+-]?\d+(?:[.,]\d+)?)\s*(?:mb|mib)\s+Physical\s*=\s*([+-]?\d+(?:[.,]\d+)?)\s*(?:mb|mib)\s+GC-committed\s*\(([+-]?\d+(?:[.,]\d+)?)\s*(?:mb|mib)\s+Managed-live\s*=\s*([+-]?\d+(?:[.,]\d+)?)%\s+of\s+committed\)\s*\+\s*([+-]?\d+(?:[.,]\d+)?)\s*(?:mb|mib)\s+Native;\s*([+-]?\d+(?:[.,]\d+)?)%\s+of\s+runtime\s+in\s+GC\s+pauses,\s*([+-]?\d+(?:[.,]\d+)?)ms\s+GC\s+pause\s+in\s+last\s+window\s*\(([+-]?\d+(?:[.,]\d+)?)%\s+of\s+window\)"#,
            options: [.caseInsensitive]
        )
        self.namedZoneRegex = try? NSRegularExpression(
            pattern: #"\[zone\s+([^\]]+)\]"#,
            options: [.caseInsensitive]
        )
        self.playbackZoneRegex = try? NSRegularExpression(
            pattern: #"\[([^\]]+)\]\s+\[(?:PLAYING|LOADING|STOPPED)\s+@"#,
            options: [.caseInsensitive]
        )
        self.raatEndpointRegex = try? NSRegularExpression(
            pattern: #"\[(?:raat|raat_ll/client)\]\s+\[([^\]]+)\]"#,
            options: [.caseInsensitive]
        )
        self.raatDeviceRegex = try? NSRegularExpression(
            pattern: #"\[RAAT::([^\]]+)\]"#,
            options: [.caseInsensitive]
        )
        self.roonAPIClientRegex = try? NSRegularExpression(
            pattern: #"\[apiclient\s+([^\]]+)\]"#,
            options: [.caseInsensitive]
        )
        self.backupProgressRegex = try? NSRegularExpression(
            pattern: #"bytes transferred:\s*(\d+)/(\d+)\s*\((\d+)%\)"#,
            options: [.caseInsensitive]
        )
        self.metadataPendingRegex = try? NSRegularExpression(
            pattern: #"pending adds=(\d+),\s*pending removes=(\d+),\s*current q size=(\d+)"#,
            options: [.caseInsensitive]
        )
        self.metadataQueueRegex = try? NSRegularExpression(
            pattern: #"_SpinQueue:\s*q size=(\d+)"#,
            options: [.caseInsensitive]
        )
        self.easyHTTPRegex = try? NSRegularExpression(
            pattern: #"(?:GET|POST|PUT|DELETE|HEAD)\s+to\s+(https?://[^\s]+)\s+returned after\s+(\d+)\s*ms,\s*status code:\s*(\d+)"#,
            options: [.caseInsensitive]
        )
        self.streamingDownloadRegex = try? NSRegularExpression(
            pattern: #"download speed:\s*(\d+)kbps\s+response time:\s*(\d+)ms"#,
            options: [.caseInsensitive]
        )
        self.dbPerformanceRegex = try? NSRegularExpression(
            pattern: #"\[dbperf\].*\bin\s+(\d+)\s*ms"#,
            options: [.caseInsensitive]
        )
        self.libraryMutationRegex = try? NSRegularExpression(
            pattern: #"\[library\]\s+endmutation in\s+(\d+)\s*ms"#,
            options: [.caseInsensitive]
        )
        self.storageScanRegex = try? NSRegularExpression(
            pattern: #"initial scan of\s+(.+?)\s+took:\s*(\d+)\s*ms"#,
            options: [.caseInsensitive]
        )
        self.libraryStatsRegex = try? NSRegularExpression(
            pattern: #"\[library stats\].*\btracks:\s*(\d+)"#,
            options: [.caseInsensitive]
        )
    }

    public func parse(file: String, line: String) -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        let source = displaySourceName(file)
        let now = nowProvider()
        let time = timestampParser.parse(line, relativeTo: now) ?? now
        let lower = line.lowercased()

        let operationalEvents = parseOperational(line: line, lower: lower, source: source, time: time)
        if !operationalEvents.isEmpty {
            return operationalEvents
        }

        if isKnownInformationalRoonNoise(lower) {
            return [event(
                domain: "log",
                type: "log.notice",
                severity: .info,
                title: "Roon log notice",
                message: trimmed(line),
                source: source,
                time: time
            )]
        }

        if Self.mayContainMemoryStats(lower) {
            events.append(contentsOf: parseMemory(line: line, source: source, time: time))
        }
        events.append(contentsOf: parsePlayback(line: line, lower: lower, source: source, time: time))
        events.append(contentsOf: parseRaat(line: line, lower: lower, source: source, time: time))
        events.append(contentsOf: parseRoonCache(line: line, lower: lower, source: source, time: time))
        events.append(contentsOf: parseMediaRetries(line: line, lower: lower, source: source, time: time))
        events.append(contentsOf: parseServer(line: line, lower: lower, source: source, time: time))
        events.append(contentsOf: parseDatabase(line: line, lower: lower, source: source, time: time))

        if events.isEmpty, isInteresting(line: lower) {
            events.append(event(
                domain: "log",
                type: "log.highlight",
                severity: severity(for: lower),
                title: "Highlighted log line",
                message: trimmed(line),
                source: source,
                time: time
            ))
        }

        return events
    }

    private func parseMemory(line: String, source: String, time: Date) -> [RuntimeEvent] {
        if let values = currentMemoryStats(from: line) {
            var events = [
                metricEvent(title: "Virtual Memory", value: values.virtualMB, unit: "MB", source: source, time: time, isMemory: true),
                metricEvent(title: "Physical Memory", value: values.physicalMB, unit: "MB", source: source, time: time, isMemory: true),
                metricEvent(title: "GC Committed Memory", value: values.gcCommittedMB, unit: "MB", source: source, time: time, isMemory: true),
                metricEvent(title: "Managed Memory", value: values.managedLiveMB, unit: "MB", source: source, time: time, isMemory: true),
                metricEvent(title: "Managed Utilization", value: values.managedUtilizationPercent, unit: "%", source: source, time: time),
                metricEvent(title: "GC Pause Runtime", value: values.gcPauseRuntimePercent, unit: "%", source: source, time: time),
                metricEvent(title: "GC Pause Window", value: values.gcPauseWindowMilliseconds, unit: "ms", source: source, time: time),
                metricEvent(title: "GC Pause Window Percent", value: values.gcPauseWindowPercent, unit: "%", source: source, time: time)
            ]
            if values.nativeMB >= 0 {
                events.insert(
                    metricEvent(title: "Native Memory", value: values.nativeMB, unit: "MB", source: source, time: time, isMemory: true),
                    at: 4
                )
            } else {
                events.insert(
                    event(
                        domain: "memory",
                        type: "memory.metric.unavailable",
                        severity: .info,
                        title: "Native Memory",
                        message: "Native Memory is not meaningful because GC committed memory exceeds physical RSS.",
                        source: source,
                        time: time,
                        unit: "MB"
                    ),
                    at: 4
                )
            }
            return events
        }
        let samples = memorySamples(from: line)
        return samples.map { sample in
            event(
                domain: "memory",
                type: "memory.sample.detected",
                severity: .info,
                title: sample.metric,
                message: "\(sample.metric): \(Int(sample.valueMB.rounded())) MB",
                source: source,
                time: time,
                valueMB: sample.valueMB
            )
        }
    }

    private func parseOperational(line: String, lower: String, source: String, time: Date) -> [RuntimeEvent] {
        if lower.contains("already sent a final response") {
            return [event(
                domain: "extension",
                type: "extension.response_race",
                severity: .info,
                title: "Roon API response race",
                message: trimmed(line),
                source: source,
                time: time,
                zone: extractRoonAPIClient(from: line)
            )]
        }

        if let backup = parseBackup(line: line, lower: lower, source: source, time: time) {
            return [backup]
        }
        if let metadata = parseMetadataOrLibrary(line: line, lower: lower, source: source, time: time) {
            return [metadata]
        }
        if let service = parseServiceHealth(line: line, lower: lower, source: source, time: time) {
            return [service]
        }
        if let performance = parseOperationalPerformance(line: line, lower: lower, source: source, time: time) {
            return [performance]
        }

        if lower.contains("[broker/database/vacuum]") {
            if lower.contains("validating database") || lower.contains("validating /") {
                return [event(domain: "database", type: "database.maintenance.started", severity: .info, title: "Database maintenance started", message: trimmed(line), source: source, time: time)]
            }
            if lower.contains("finished validation") {
                return [event(domain: "database", type: "database.maintenance.completed", severity: .info, title: "Database maintenance completed", message: trimmed(line), source: source, time: time)]
            }
        }

        if lower.contains("[leveldb]") && lower.contains("re-opening") {
            return [event(domain: "database", type: "database.recovered", severity: .info, title: "Database reopened", message: trimmed(line), source: source, time: time)]
        }

        if lower.contains("[roonapi]") || lower.contains("[roonapi/registry]") {
            let client = extractRoonAPIClient(from: line)
            if lower.contains("[roonapi/registry]") && lower.contains("=> [") {
                return [event(domain: "extension", type: "extension.identified", severity: .info, title: "Roon API client identified", message: trimmed(line), source: source, time: time, zone: client)]
            }
            if lower.contains("connection timeout") {
                return [event(domain: "extension", type: "extension.timeout", severity: .info, title: "Roon API client timeout", message: trimmed(line), source: source, time: time, zone: client)]
            }
            if lower.contains("disconnected") {
                return [event(domain: "extension", type: "extension.disconnected", severity: .info, title: "Roon API client disconnected", message: trimmed(line), source: source, time: time, zone: client)]
            }
            if lower.contains("connected (websocket)") || lower.contains("continue registered") {
                return [event(domain: "extension", type: "extension.connected", severity: .info, title: "Roon API client connected", message: trimmed(line), source: source, time: time, zone: client)]
            }
            if lower.contains("continue subscribed")
                || lower.contains("continue changed")
                || lower.contains("subscribe_queue")
            {
                let isInitialSync = line.utf8.count >= 4_096
                    && (lower.contains("continue subscribed") || lower.contains("subscribe_queue"))
                return [event(
                    domain: "extension",
                    type: isInitialSync ? "extension.sync" : "extension.traffic",
                    severity: .info,
                    title: isInitialSync ? "Roon API state synchronization" : "Roon API traffic",
                    message: trimmed(line),
                    source: source,
                    time: time,
                    zone: client,
                    numericValue: Double(line.utf8.count),
                    unit: "bytes"
                )]
            }
        }

        if lower.contains("[mobile]") && (lower.contains("error mapping port") || lower.contains("failed to create port mapping") || lower.contains("unexpectedupnpcontrolresponse")) {
            return [event(domain: "remote", type: "remote.port_mapping.failed", severity: .info, title: "Remote access port mapping failed", message: trimmed(line), source: source, time: time)]
        }
        if lower.contains("[mobile]") && (lower.contains("port check success") || lower.contains("success: true")) {
            return [event(domain: "remote", type: "remote.connectivity.ok", severity: .info, title: "Remote connectivity succeeded", message: trimmed(line), source: source, time: time)]
        }

        if lower.contains("[cast/client]") && lower.contains("unable to authenticate tls connection") {
            return [event(domain: "device", type: "device.cast.authentication", severity: .info, title: "Cast TLS authentication retry", message: trimmed(line), source: source, time: time, zone: extractBracketedClient(from: line))]
        }

        if lower.contains("[mlradio]") && lower.contains("status=success")
            || lower.contains("waveform load") && lower.contains("notfound")
            || lower.contains("[airplay]") && lower.contains("disconnected")
        {
            return [event(domain: "log", type: "log.notice", severity: .info, title: "Roon operational notice", message: trimmed(line), source: source, time: time)]
        }

        return []
    }

    private func parseBackup(line: String, lower: String, source: String, time: Date) -> RuntimeEvent? {
        guard lower.contains("[backup]") || lower.contains("[broker/backups]") else { return nil }
        if lower.contains("preparing backup") {
            return event(domain: "backup", type: "backup.started", severity: .info, title: "Roon backup started", message: trimmed(line), source: source, time: time)
        }
        if let match = firstMatch(regex: backupProgressRegex, in: line),
           match.count == 4,
           let transferred = Double(match[1]) {
            return event(domain: "backup", type: "backup.progress", severity: .info, title: "Roon backup progress", message: trimmed(line), source: source, time: time, numericValue: transferred, unit: "bytes")
        }
        if lower.contains("writing backup manifest") {
            return event(domain: "backup", type: "backup.finalizing", severity: .info, title: "Roon backup finalizing", message: trimmed(line), source: source, time: time)
        }
        if lower.contains("successful sync") || lower.contains("on done") {
            return event(domain: "backup", type: "backup.completed", severity: .info, title: "Roon backup completed", message: trimmed(line), source: source, time: time)
        }
        if lower.contains("retrieving backup manifest for cleanup")
            || lower.contains("excessive backups")
            || lower.contains("unneeded files")
        {
            return event(domain: "backup", type: "backup.cleanup", severity: .info, title: "Roon backup retention cleanup", message: trimmed(line), source: source, time: time)
        }
        if containsAny(lower, ["failed", "unable", "error", "cancelled", "canceled"]) {
            return event(domain: "backup", type: "backup.failed", severity: .warning, title: "Roon backup failed", message: trimmed(line), source: source, time: time)
        }
        return nil
    }

    private func parseMetadataOrLibrary(line: String, lower: String, source: String, time: Date) -> RuntimeEvent? {
        if lower.contains("[updatemetadata]") {
            if lower.contains("ready for full refresh") && !lower.contains("not ready") {
                return event(domain: "metadata", type: "metadata.refresh.started", severity: .info, title: "Metadata full refresh started", message: trimmed(line), source: source, time: time)
            }
            if let match = firstMatch(regex: metadataPendingRegex, in: line),
               match.count == 4,
               let pendingAdds = Double(match[1]),
               let pendingRemoves = Double(match[2]),
               let queueSize = Double(match[3]) {
                return event(
                    domain: "metadata",
                    type: "metadata.backlog",
                    severity: .info,
                    title: "Metadata backlog",
                    message: trimmed(line),
                    source: source,
                    time: time,
                    numericValue: pendingAdds + pendingRemoves + queueSize,
                    unit: "items"
                )
            }
            if let match = firstMatch(regex: metadataQueueRegex, in: line),
               match.count == 2,
               let queueSize = Double(match[1]) {
                return event(domain: "metadata", type: queueSize == 0 ? "metadata.refresh.completed" : "metadata.refresh.progress", severity: .info, title: "Metadata refresh queue", message: trimmed(line), source: source, time: time, numericValue: queueSize, unit: "items")
            }
        }
        if let match = firstMatch(regex: libraryStatsRegex, in: line),
           match.count == 2,
           let tracks = Double(match[1]) {
            return event(domain: "library", type: "library.stats", severity: .info, title: "Library tracks", message: trimmed(line), source: source, time: time, numericValue: tracks, unit: "tracks")
        }
        if lower.contains("[devicemap]") && lower.contains("device map updated") {
            return event(domain: "maintenance", type: "maintenance.device_database", severity: .info, title: "Device database updated", message: trimmed(line), source: source, time: time)
        }
        return nil
    }

    private func parseServiceHealth(line: String, lower: String, source: String, time: Date) -> RuntimeEvent? {
        if lower.contains("ensureauthready failed") {
            return event(domain: "service", type: "service.auth.failed", severity: .info, title: "Roon account authentication retry", message: trimmed(line), source: source, time: time, zone: "Roon account")
        }
        if lower.contains("accountstatus=loggedin") {
            return event(domain: "service", type: "service.auth.recovered", severity: .info, title: "Roon account authenticated", message: trimmed(line), source: source, time: time, zone: "Roon account")
        }
        if let match = firstMatch(regex: easyHTTPRegex, in: line),
           match.count == 4,
           let latency = Double(match[2]) {
            let provider = serviceProvider(for: match[1])
            return event(domain: provider == "Roon Remote" ? "remote" : "service", type: "service.http", severity: .info, title: "\(provider) request", message: trimmed(line), source: source, time: time, zone: provider, numericValue: latency, unit: "ms")
        }
        if let match = firstMatch(regex: streamingDownloadRegex, in: line),
           match.count == 3,
           let speed = Double(match[1]) {
            return event(domain: "streaming", type: "streaming.download", severity: .info, title: "Streaming download speed", message: trimmed(line), source: source, time: time, zone: "Streaming media", numericValue: speed, unit: "kbps")
        }
        if lower.contains("poor connection") || lower.contains("block downloader too much time locked") {
            return event(domain: "streaming", type: "streaming.quality_warning", severity: .info, title: "Streaming delivery delay", message: trimmed(line), source: source, time: time, zone: "Streaming media")
        }
        if lower.contains("[tidal/storage]") && lower.contains("scan ") && lower.contains(": starting") {
            return event(domain: "service", type: "service.sync.started", severity: .info, title: "TIDAL library sync started", message: trimmed(line), source: source, time: time, zone: "TIDAL")
        }
        if lower.contains("[tidal/storage]") && lower.contains("scan ") && lower.contains(": finished") {
            return event(domain: "service", type: "service.sync.completed", severity: .info, title: "TIDAL library sync completed", message: trimmed(line), source: source, time: time, zone: "TIDAL")
        }
        return nil
    }

    private func parseOperationalPerformance(line: String, lower: String, source: String, time: Date) -> RuntimeEvent? {
        if let match = firstMatch(regex: dbPerformanceRegex, in: line),
           match.count == 2,
           let milliseconds = Double(match[1]) {
            return event(domain: "database", type: "database.latency", severity: .info, title: "Database flush latency", message: trimmed(line), source: source, time: time, numericValue: milliseconds, unit: "ms")
        }
        if let match = firstMatch(regex: libraryMutationRegex, in: line),
           match.count == 2,
           let milliseconds = Double(match[1]) {
            return event(domain: "database", type: "database.mutation", severity: .info, title: "Library mutation latency", message: trimmed(line), source: source, time: time, numericValue: milliseconds, unit: "ms")
        }
        if lower.contains("[storage]") && lower.contains("force rescan requested for") {
            return event(domain: "storage", type: "storage.scan.started", severity: .info, title: "Storage scan started", message: trimmed(line), source: source, time: time, zone: lastPathComponent(in: line))
        }
        if let match = firstMatch(regex: storageScanRegex, in: line),
           match.count == 3,
           let milliseconds = Double(match[2]) {
            return event(domain: "storage", type: "storage.scan.completed", severity: .info, title: "Storage scan completed", message: trimmed(line), source: source, time: time, zone: URL(fileURLWithPath: match[1]).lastPathComponent, numericValue: milliseconds, unit: "ms")
        }
        if lower.contains("[storage]")
            && containsAny(lower, ["unreachable", "not available", "directory not found", "no such file", "permission denied"])
        {
            return event(domain: "storage", type: "storage.unavailable", severity: .warning, title: "Storage location unavailable", message: trimmed(line), source: source, time: time, zone: lastPathComponent(in: line))
        }
        return nil
    }

    private func parsePlayback(line: String, lower: String, source: String, time: Date) -> [RuntimeEvent] {
        guard lower.contains("playback")
            || lower.contains("[playing @")
            || lower.contains("[loading @")
            || lower.contains("[stopped @")
            || lower.contains(#""status":"buffering""#)
            || lower.contains(#""status":"playing""#)
            || lower.contains(#""status":"stopped""#)
            || lower.contains("startstream")
            || lower.contains("onplayfeedback")
            || lower.contains("signalpath quality")
            || lower.contains("state changed:")
        else { return [] }

        let zone = extractZone(from: line)
        var events = [
            event(
                domain: "playback",
                type: "playback.activity.detected",
                severity: .info,
                title: "Playback activity",
                message: trimmed(line),
                source: source,
                time: time,
                zone: zone
            )
        ]

        let hasBuffering = lower.contains("buffering")
        let hasPlaybackProblem = lower.contains("timeout")
            || lower.contains("failed")
            || lower.contains("networkerror")
            || lower.contains("network error")
            || lower.contains("dropped")
        if hasPlaybackProblem {
            events.append(event(
                domain: "playback",
                type: "playback.warning.detected",
                severity: .warning,
                title: "Playback issue",
                message: trimmed(line),
                source: source,
                time: time,
                zone: zone
            ))
        } else if hasBuffering {
            events.append(event(
                domain: "playback",
                type: "playback.buffering",
                severity: .info,
                title: "Playback buffering observed",
                message: trimmed(line),
                source: source,
                time: time,
                zone: zone
            ))
        }
        if lower.contains("[playing @") || lower.contains("onplayfeedback playing") {
            events.append(event(domain: "playback", type: "playback.playing", severity: .info, title: "Playback playing", message: trimmed(line), source: source, time: time, zone: zone))
        }
        if lower.contains(#""status":"playing""#) {
            events.append(event(domain: "playback", type: "playback.playing", severity: .info, title: "Playback playing", message: trimmed(line), source: source, time: time, zone: zone))
        }
        if lower.contains("[stopped @") || lower.contains("onplayfeedback stopped") || lower.contains(#""status":"stopped""#) {
            events.append(event(domain: "playback", type: "playback.stopped", severity: .info, title: "Playback stopped", message: trimmed(line), source: source, time: time, zone: zone))
        }

        return events
    }

    private func parseRaat(line: String, lower: String, source: String, time: Date) -> [RuntimeEvent] {
        let hasRaatContext = lower.contains("raat")
            || lower.contains("tcpaudiosource")
            || lower.contains("transport lost")
            || lower.contains("device lost")
        guard hasRaatContext else { return [] }

        let zone = extractZone(from: line)
        if lower.contains("transport lost") || lower.contains("device lost") || lower.contains("disconnected") {
            return [event(domain: "raat", type: "raat.disconnected", severity: .info, title: "RAAT transport interruption", message: trimmed(line), source: source, time: time, zone: zone)]
        }
        if lower.contains("connected") || lower.contains("reconnect") {
            return [event(domain: "raat", type: "raat.connected", severity: .info, title: "RAAT connected", message: trimmed(line), source: source, time: time, zone: zone)]
        }
        return []
    }

    private func parseRoonCache(line: String, lower: String, source: String, time: Date) -> [RuntimeEvent] {
        guard lower.contains("ftmsi-b")
            || lower.contains("filecache")
            || lower.contains("download status:")
        else { return [] }

        return [event(
            domain: "cache",
            type: "cache.status",
            severity: .info,
            title: "Roon file cache status",
            message: trimmed(line),
            source: source,
            time: time
        )]
    }

    private func parseMediaRetries(line: String, lower: String, source: String, time: Date) -> [RuntimeEvent] {
        let imageFetchRetry = lower.contains("failed to get image data")
            && (lower.contains("ioexception") || lower.contains("attempt"))
        let imageProcessingNotice = lower.contains("image_process")
            && (lower.contains("notsupportedexception") || lower.contains("image format"))
        guard imageFetchRetry || imageProcessingNotice else { return [] }

        let exhaustedRetries = lower.contains("attempt 3/3") || lower.contains("attempt 3 of 3")
        return [event(
            domain: "media",
            type: imageProcessingNotice ? "media.image_processing_notice" : (exhaustedRetries ? "media.image_failed" : "media.image_retry"),
            severity: .info,
            title: imageProcessingNotice ? "Image processing notice" : (exhaustedRetries ? "Image fetch failed" : "Image fetch retry"),
            message: trimmed(line),
            source: source,
            time: time
        )]
    }

    private func parseServer(line: String, lower: String, source: String, time: Date) -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        guard !isPlaybackStatusLine(lower) else { return events }

        if lower.contains("starting roon") || lower.contains("roonserver start") || lower.contains("server startup") {
            events.append(event(domain: "server", type: "server.started", severity: .info, title: "Server startup", message: trimmed(line), source: source, time: time))
        }
        if lower.contains("shutdown") || lower.contains("stopping roon") || lower.contains("server stopped") {
            events.append(event(domain: "server", type: "server.stopped", severity: .warning, title: "Server stopped", message: trimmed(line), source: source, time: time))
        }
        if isFatalServerProblem(lower) {
            events.append(event(domain: "server", type: "server.exception", severity: .critical, title: "Server exception", message: trimmed(line), source: source, time: time))
        } else if lower.contains("exception"), isKnownNonFatalRoonException(lower) {
            events.append(event(domain: "server", type: "server.exception.notice", severity: .info, title: "Server exception notice", message: trimmed(line), source: source, time: time))
        } else if lower.contains("critical:") {
            events.append(event(domain: "server", type: "server.critical.warning", severity: .warning, title: "Server critical log entry", message: trimmed(line), source: source, time: time))
        } else if lower.contains("exception") {
            events.append(event(domain: "server", type: "server.exception.warning", severity: .warning, title: "Server exception warning", message: trimmed(line), source: source, time: time))
        }
        return events
    }

    private func parseDatabase(line: String, lower: String, source: String, time: Date) -> [RuntimeEvent] {
        guard lower.contains("database")
            || lower.contains("sqlite")
            || lower.contains("slow query")
            || lower.contains("query took")
            || lower.contains("vacuum")
            || lower.contains("checkpoint")
        else { return [] }

        if lower.contains("database disk image is malformed")
            || lower.contains("database corruption")
            || lower.contains("corrupt")
        {
            return [event(
                domain: "database",
                type: "database.critical",
                severity: .critical,
                title: "Database critical",
                message: trimmed(line),
                source: source,
                time: time
            )]
        }

        if lower.contains("database is locked")
            || lower.contains("sqlite busy")
            || lower.contains("sqlite_busy")
            || lower.contains("db locked")
            || lower.contains("database locked")
            || lower.contains("slow query")
            || lower.contains("query took")
            || lower.contains("timeout")
            || lower.contains("rollback")
        {
            return [event(
                domain: "database",
                type: "database.notice",
                severity: .info,
                title: "Database transient state",
                message: trimmed(line),
                source: source,
                time: time
            )]
        }

        if lower.contains("failed")
            || lower.contains("unable to open")
            || lower.contains("cannot open")
            || lower.contains("i/o error")
            || lower.contains("io error")
        {
            return [event(
                domain: "database",
                type: "database.warning",
                severity: .warning,
                title: "Database failure",
                message: trimmed(line),
                source: source,
                time: time
            )]
        }

        if lower.contains("vacuum completed") || lower.contains("checkpoint complete") {
            return [event(
                domain: "database",
                type: "database.maintenance",
                severity: .info,
                title: "Database maintenance",
                message: trimmed(line),
                source: source,
                time: time
            )]
        }

        return []
    }

    private func memorySamples(from line: String) -> [(metric: String, valueMB: Double)] {
        var samples: [(String, Double)] = []
        for (metric, regex) in memoryPatterns {
            guard let match = firstMatch(regex: regex, in: line) else { continue }
            guard let value = Double(match[1]) else { continue }
            samples.append((metric, toMB(value, unit: match[2])))
        }
        return samples
    }

    private func currentMemoryStats(from line: String) -> CurrentMemoryStats? {
        guard let match = firstMatch(regex: currentStatsRegex, in: line), match.count == 10 else { return nil }
        let values = match.dropFirst().compactMap(Self.numericValue)
        guard values.count == 9 else { return nil }
        return CurrentMemoryStats(
            virtualMB: values[0],
            physicalMB: values[1],
            gcCommittedMB: values[2],
            managedLiveMB: values[3],
            managedUtilizationPercent: values[4],
            nativeMB: values[5],
            gcPauseRuntimePercent: values[6],
            gcPauseWindowMilliseconds: values[7],
            gcPauseWindowPercent: values[8]
        )
    }

    private func metricEvent(title: String, value: Double, unit: String, source: String, time: Date, isMemory: Bool = false) -> RuntimeEvent {
        event(
            domain: isMemory ? "memory" : "runtime",
            type: isMemory ? "memory.sample.detected" : "runtime.metric.detected",
            severity: .info,
            title: title,
            message: "\(title): \(value) \(unit)",
            source: source,
            time: time,
            valueMB: isMemory ? value : nil,
            numericValue: value,
            unit: unit
        )
    }

    private static func mayContainMemoryStats(_ lower: String) -> Bool {
        lower.contains(" physical")
            || lower.contains(" managed")
            || lower.contains(" unmanaged")
            || lower.contains(" virtual")
    }

    private func firstMatch(regex: NSRegularExpression?, in text: String) -> [String]? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let swiftRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func extractZone(from line: String) -> String? {
        if let match = firstMatch(regex: namedZoneRegex, in: line), match.count > 1 {
            return match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = firstMatch(regex: playbackZoneRegex, in: line), match.count > 1 {
            return match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = firstMatch(regex: raatEndpointRegex, in: line), match.count > 1 {
            return match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = firstMatch(regex: raatDeviceRegex, in: line), match.count > 1 {
            return match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func extractRoonAPIClient(from line: String) -> String? {
        guard let match = firstMatch(regex: roonAPIClientRegex, in: line), match.count > 1 else {
            return nil
        }
        return match[1].replacingOccurrences(
            of: #":\d+$"#,
            with: "",
            options: .regularExpression
        )
    }

    private func serviceProvider(for rawURL: String) -> String {
        guard let host = URL(string: rawURL)?.host?.lowercased() else { return "Network service" }
        if host.contains("tidal") { return "TIDAL" }
        if host.contains("qobuz") { return "Qobuz" }
        if host.contains("porttest.roonlabs.net") { return "Roon Remote" }
        if host.contains("roonlabs.net") { return "Roon Labs" }
        if host == "127.0.0.1" || host == "localhost" { return "Local Roon service" }
        return host
    }

    private func lastPathComponent(in line: String) -> String? {
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        guard let path = tokens.last(where: { $0.contains("/") }) else { return nil }
        let cleaned = String(path).trimmingCharacters(in: CharacterSet(charactersIn: "'\","))
        let component = URL(fileURLWithPath: cleaned).lastPathComponent
        return component.isEmpty ? nil : component
    }

    private func extractBracketedClient(from line: String) -> String? {
        let parts = line.split(separator: "[")
        guard parts.count >= 3, let end = parts[2].firstIndex(of: "]") else { return nil }
        return String(parts[2][..<end])
    }

    private func event(
        domain: String,
        type: String,
        severity: Severity,
        title: String,
        message: String,
        source: String,
        time: Date,
        valueMB: Double? = nil,
        zone: String? = nil,
        numericValue: Double? = nil,
        unit: String? = nil
    ) -> RuntimeEvent {
        RuntimeEvent(
            id: UUID().uuidString,
            time: time,
            domain: domain,
            type: type,
            severity: severity,
            title: title,
            message: message,
            source: source,
            valueMB: valueMB,
            zone: zone,
            numericValue: numericValue,
            unit: unit
        )
    }

    private func severity(for lower: String) -> Severity {
        if isFatalServerProblem(lower)
            || lower.contains("database disk image is malformed")
            || lower.contains("database corruption")
        {
            return .critical
        }
        if lower.contains("critical:") && !isKnownNonFatalRoonException(lower) {
            return .warning
        }
        if containsAny(lower, [
            "failed to start roon",
            "failed to start server",
            "failed starting roon",
            "roonserver failed to start",
            "server failed to start",
            "cannot open",
            "unable to open",
            "permission denied",
            "access denied",
            "authentication failed",
            "i/o error",
            "io error"
        ]) {
            return .warning
        }
        return .info
    }

    private func isInteresting(line lower: String) -> Bool {
        ["error", "warning", "failed", "timeout", "disconnect", "database", "exception"].contains { lower.contains($0) }
    }

    private func isPlaybackStatusLine(_ lower: String) -> Bool {
        lower.contains("[playing @")
            || lower.contains("[loading @")
            || lower.contains("[stopped @")
            || lower.contains("onplayfeedback playing")
            || lower.contains("onplayfeedback stopped")
    }

    private func trimmed(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
    }

    private func isFatalServerProblem(_ lower: String) -> Bool {
        containsAny(lower, [
            "fatal:",
            "fatal error",
            "[fatal]",
            "roonserver crash",
            "server crash",
            "process crash",
            "crash report",
            "crashed unexpectedly",
            "panic:",
            "panic occurred",
            "unhandled exception",
            "uncaught exception",
            "outofmemory",
            "out of memory",
            "segmentation fault"
        ])
    }

    private func isKnownNonFatalRoonException(_ lower: String) -> Bool {
        containsAny(lower, [
            "version changed out from under us",
            "already sent a final response",
            "exception caught",
            "exception thrown. restarting connection",
            "operationcanceled",
            "operation canceled",
            "connectionclosedprematurely",
            "websocket connection",
            "web exception without response",
            "hostnotfound",
            "connectionreset",
            "failed to get image data",
            "ioexception",
            "indexoutofrangeexception",
            "not supported",
            "image format"
        ])
    }

    private func isKnownInformationalRoonNoise(_ lower: String) -> Bool {
        containsAny(lower, [
            "[swim]",
            " swim failed to start",
            "failed to start persisted swim session",
            "result[status=notfound]",
            "failed to extract audio format",
            "corruptfile",
            "failed to load device db",
            "scx: in onafterentry",
            "scx: in onbeforeentry",
            "scx: in onafterexit",
            "failed to perform search for query",
            "autodetect script failed",
            "keynotfoundexception"
        ])
    }

    private func containsAny(_ lower: String, _ patterns: [String]) -> Bool {
        patterns.contains { lower.contains($0) }
    }

    private func toMB(_ value: Double, unit: String) -> Double {
        switch unit.lowercased() {
        case "kb", "kib": return value / 1024.0
        case "gb", "gib": return value * 1024.0
        default: return value
        }
    }

    private static func numericValue(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: "."))
    }

    private func displaySourceName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let file = url.lastPathComponent.isEmpty ? "log" : url.lastPathComponent
        let parent = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        if parent.isEmpty {
            return file
        }
        return "\(parent)/\(file)"
    }
}

private struct CurrentMemoryStats {
    var virtualMB: Double
    var physicalMB: Double
    var gcCommittedMB: Double
    var managedLiveMB: Double
    var managedUtilizationPercent: Double
    var nativeMB: Double
    var gcPauseRuntimePercent: Double
    var gcPauseWindowMilliseconds: Double
    var gcPauseWindowPercent: Double
}
