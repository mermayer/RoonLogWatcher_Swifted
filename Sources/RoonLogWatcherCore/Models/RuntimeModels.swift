import Foundation

public enum Severity: String, Codable, CaseIterable {
    case info
    case warning
    case critical
}

public enum RuntimeMode: String, Codable {
    case idle
    case live
    case demo

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .live: return "Live logs"
        case .demo: return "Demo feed"
        }
    }
}

public enum RoonHealthState: String, Codable {
    case healthy
    case degraded
    case critical
    case unknown
}

public struct RoonHealth: Codable {
    public var state: RoonHealthState
    public var score: Int
    public var title: String
    public var summary: String
    public var evaluatedAt: Date
    public var lastLogAt: Date?
    public var lastLogAgeSeconds: Double?
    public var signals: [RoonHealthSignal]
}

public struct RoonHealthSignal: Codable, Identifiable {
    public var id: String
    public var domain: String
    public var severity: Severity
    public var title: String
    public var message: String
    public var impact: Int
    public var observedAt: Date?
    public var count: Int?
    public var ageSeconds: Double?
    public var valueMB: Double?
    public var thresholdMB: Double?
    public var deltaMB: Double?
    public var windowMinutes: Double?
    public var source: String?
    public var zone: String?
}

public struct RuntimeSnapshot: Codable {
    public var ok: Bool
    public var appName: String
    public var mode: RuntimeMode
    public var generatedAt: Date
    public var runStartedAt: Date
    public var dashboardURL: String?
    public var healthScore: Int
    public var health: RoonHealth
    public var healthTrend: [RoonHealthTrendPoint]
    public var memoryTrend24h: [MemoryTrendPoint]
    public var system: LocalSystemStatus?
    public var watchedSources: [WatchedSource]
    public var memory: [MemoryMetric]
    public var recentLogs: [LogLine]
    public var volumeBuckets: [LogVolumeBucket]
    public var timeline: [RuntimeEvent]
    public var alerts: [RuntimeEvent]
    public var playback: [RuntimeEvent]
    public var counters: RuntimeCounters
}

public struct LogVolumeBucket: Codable {
    public var startAt: Date
    public var endAt: Date
    public var total: Int
    public var warning: Int
    public var critical: Int
}

public struct RuntimeStatusSummary {
    public var mode: RuntimeMode
    public var healthScore: Int
    public var health: RoonHealth
    public var alerts: [RuntimeEvent]
    public var counters: RuntimeCounters
}

public struct RuntimeCounters: Codable {
    public var processedLines: Int
    public var warningCount: Int
    public var criticalCount: Int
    public var memoryPointCount: Int
    public var watchedFileCount: Int
}

public struct WatchedSource: Codable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var lineCount: Int
    public var lastSeenAt: Date?
    public var status: String
    public var lastModifiedAt: Date? = nil
    public var fileSizeBytes: UInt64? = nil
    public var isReadable: Bool? = nil
}

public struct LogLine: Codable, Identifiable {
    public var id: Int
    public var receivedAt: Date
    public var source: String
    public var text: String
    public var severity: Severity
}

public struct RuntimeEvent: Codable, Identifiable {
    public var id: String
    public var time: Date
    public var domain: String
    public var type: String
    public var severity: Severity
    public var title: String
    public var message: String
    public var source: String
    public var valueMB: Double?
    public var zone: String?
}

public struct MemoryMetric: Codable, Identifiable {
    public var id: String { metric }
    public var metric: String
    public var valueMB: Double
    public var updatedAt: Date
    public var source: String
}

public struct RoonHealthTrendPoint: Codable, Identifiable {
    public var id: String { "\(time.timeIntervalSince1970)-\(score)-\(state.rawValue)" }
    public var time: Date
    public var score: Int
    public var state: RoonHealthState
}

public struct MemoryTrendPoint: Codable, Identifiable {
    public var id: String { "\(metric)-\(time.timeIntervalSince1970)" }
    public var time: Date
    public var metric: String
    public var valueMB: Double
    public var source: String
}

public struct LocalSystemStatus: Codable {
    public var sampledAt: Date
    public var host: RoonHostStatus
    public var processes: [RoonProcessStatus]
    public var totalCPUPercent: Double
    public var totalMemoryMB: Double
    public var openFileCount: Int?
    public var logVolumePath: String?
    public var logVolumeFreeMB: Double?
    public var logVolumeFreeRatio: Double?
}

public struct RoonHostStatus: Codable {
    public var isRoonServerLikely: Bool
    public var reason: String
    public var detectedProcesses: [String]
    public var detectedLogDirectories: [String]
    public var checkedAt: Date
}

public struct RoonProcessStatus: Codable, Identifiable {
    public var id: Int { pid }
    public var pid: Int
    public var name: String
    public var path: String
    public var cpuPercent: Double
    public var memoryMB: Double
    public var openFiles: Int?
}
