import Foundation

public enum DiagnosticIncidentState: String, Codable, Sendable {
    case active
    case monitoring
    case resolved
}

public struct DiagnosticEvidence: Codable, Identifiable, Sendable {
    public var id: String
    public var time: Date
    public var title: String
    public var message: String
    public var source: String
    public var domain: String
}

public struct DiagnosticIncident: Codable, Identifiable, Sendable {
    public var id: String
    public var correlationKey: String
    public var kind: String
    public var state: DiagnosticIncidentState
    public var severity: Severity
    public var title: String
    public var summary: String
    public var startedAt: Date
    public var updatedAt: Date
    public var resolvedAt: Date?
    public var recoveryMessage: String?
    public var affectedDomains: [String]
    public var source: String?
    public var zone: String?
    public var eventCount: Int
    public var healthImpact: Int
    public var evidence: [DiagnosticEvidence]
    public var durationSeconds: Double? = nil
    public var dataBytes: Int? = nil
    public var currentValue: Double? = nil
    public var baselineValue: Double? = nil
    public var unit: String? = nil
    public var details: [String]? = nil
}

public struct DiagnosticPrediction: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var severity: Severity
    public var title: String
    public var message: String
    public var confidence: Double
    public var observedAt: Date
    public var horizonMinutes: Double?
    public var currentValue: Double?
    public var baselineValue: Double?
    public var changePerHour: Double?
    public var unit: String?
    public var evidence: [String]
}

public struct DiagnosticMetricSummary: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var entity: String
    public var severity: Severity
    public var title: String
    public var summary: String
    public var observedAt: Date
    public var windowMinutes: Double
    public var sampleCount: Int
    public var failureCount: Int
    public var totalBytes: Int?
    public var averageValue: Double?
    public var maximumValue: Double?
    public var latestValue: Double?
    public var baselineValue: Double?
    public var changeValue: Double?
    public var unit: String?
    public var details: [String]
}

public struct AdaptiveResourceBaseline: Codable, Sendable {
    public var sampleCount: Int
    public var updatedAt: Date?
    public var physicalMemoryMB: Double?
    public var processMemoryMB: Double?
    public var cpuPercent: Double?
    public var openFiles: Double?
    public var diskIOMBps: Double?
    public var gcPauseWindowPercent: Double?
}

public struct RoonRuntimeTelemetry: Codable, Sendable {
    public var updatedAt: Date? = nil
    public var virtualMemoryMB: Double? = nil
    public var physicalMemoryMB: Double? = nil
    public var gcCommittedMB: Double? = nil
    public var managedLiveMB: Double? = nil
    public var nativeMemoryMB: Double? = nil
    public var managedUtilizationPercent: Double? = nil
    public var gcPauseRuntimePercent: Double? = nil
    public var gcPauseWindowMilliseconds: Double? = nil
    public var gcPauseWindowPercent: Double? = nil
}

public struct DiagnosticAnalysisSnapshot: Codable, Sendable {
    public var telemetry: RoonRuntimeTelemetry
    public var baseline: AdaptiveResourceBaseline
    public var metrics: [DiagnosticMetricSummary]
    public var metricTotalCount: Int
    public var incidents: [DiagnosticIncident]
    public var incidentTotalCount: Int
    public var activeIncidentCount: Int
    public var predictions: [DiagnosticPrediction]
}
