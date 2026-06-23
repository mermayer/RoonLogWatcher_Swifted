import Foundation

public struct LogParser {
    public init() {}

    public func parse(file: String, line: String) -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        let source = displaySourceName(file)
        let time = extractTimestamp(from: line) ?? Date()
        let lower = line.lowercased()

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

        events.append(contentsOf: parseMemory(line: line, source: source, time: time))
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

    private func parsePlayback(line: String, lower: String, source: String, time: Date) -> [RuntimeEvent] {
        guard lower.contains("playback")
            || lower.contains("[playing @")
            || lower.contains("[loading @")
            || lower.contains("[stopped @")
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
        if hasBuffering || hasPlaybackProblem {
            events.append(event(
                domain: "playback",
                type: hasBuffering ? "playback.buffering" : "playback.warning.detected",
                severity: .info,
                title: hasBuffering ? "Playback buffering observed" : "Playback issue observed",
                message: trimmed(line),
                source: source,
                time: time,
                zone: zone
            ))
        }
        if lower.contains("[playing @") || lower.contains("onplayfeedback playing") {
            events.append(event(domain: "playback", type: "playback.playing", severity: .info, title: "Playback playing", message: trimmed(line), source: source, time: time, zone: zone))
        }
        if lower.contains("[stopped @") || lower.contains("onplayfeedback stopped") {
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
        if lower.contains("disconnect") || lower.contains("transport lost") || lower.contains("device lost") {
            return [event(domain: "raat", type: "raat.disconnected", severity: .info, title: "RAAT disconnect observed", message: trimmed(line), source: source, time: time, zone: zone)]
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
            || lower.contains("query")
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
        let patterns: [(String, String)] = [
            ("Virtual Memory", #"(\d+(?:\.\d+)?)\s*(kb|kib|mb|mib|gb|gib)\s+Virtual\b"#),
            ("Physical Memory", #"(\d+(?:\.\d+)?)\s*(kb|kib|mb|mib|gb|gib)\s+Physical\b"#),
            ("Managed Memory", #"(\d+(?:\.\d+)?)\s*(kb|kib|mb|mib|gb|gib)\s+Managed\b"#),
            ("Unmanaged Memory", #"(\d+(?:\.\d+)?)\s*(kb|kib|mb|mib|gb|gib)\s+(?:estimated\s+)?Unmanaged\b"#)
        ]
        var samples: [(String, Double)] = []
        for (metric, pattern) in patterns {
            guard let match = firstMatch(pattern: pattern, in: line) else { continue }
            guard let value = Double(match[1]) else { continue }
            samples.append((metric, toMB(value, unit: match[2])))
        }
        return samples
    }

    private func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let swiftRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func extractZone(from line: String) -> String? {
        if let match = firstMatch(pattern: #"\[zone\s+([^\]]+)\]"#, in: line), match.count > 1 {
            return match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = firstMatch(pattern: #"\[([^\]]+)\]\s+\[(?:PLAYING|LOADING|STOPPED)\s+@"#, in: line), match.count > 1 {
            return match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func extractTimestamp(from line: String) -> Date? {
        guard let match = firstMatch(pattern: #"(\d{2})/(\d{2})\s+(\d{2}):(\d{2}):(\d{2})"#, in: line), match.count == 6 else {
            return nil
        }
        var components = Calendar.current.dateComponents([.year], from: Date())
        components.month = Int(match[1])
        components.day = Int(match[2])
        components.hour = Int(match[3])
        components.minute = Int(match[4])
        components.second = Int(match[5])
        return Calendar.current.date(from: components)
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
        zone: String? = nil
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
            zone: zone
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

    private func trimmed(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
    }

    private func isFatalServerProblem(_ lower: String) -> Bool {
        containsAny(lower, [
            "fatal",
            "crash",
            "panic",
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
            "scx: in onbeforeentry"
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
