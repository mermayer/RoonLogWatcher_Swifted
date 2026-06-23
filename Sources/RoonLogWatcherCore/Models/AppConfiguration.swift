import Foundation

public enum AppLanguage: String, Codable, Equatable {
    case english = "en"
    case german = "de"

    public static func preferred() -> AppLanguage {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("de") == true ? .german : .english
    }
}

public struct AppConfiguration: Codable, Equatable {
    public var language: AppLanguage
    public var baseDirectory: String
    public var autoDiscoverRoonLogDirectories: Bool
    public var logDirectories: [String]
    public var pollIntervalSeconds: Double
    public var dashboardPort: UInt16
    public var enableDemoModeWhenNoLogs: Bool
    public var watchExistingLogsFromEnd: Bool
    public var fileNameIncludes: [String]
    public var maxFilesPerDirectory: Int
    public var recentLogMaxLines: Int
    public var logHistoryMaxLines: Int
    public var maxLogLineCharacters: Int
    public var alertDedupeSeconds: Double
    public var logVolumeWindowMinutes: Int
    public var sendMacNotifications: Bool
    public var showAllLogLines: Bool
    public var memoryAlerts: MemoryAlertConfiguration
    public var healthRules: HealthRuleConfiguration

    public init(
        language: AppLanguage = AppLanguage.preferred(),
        baseDirectory: String = "/Volumes/Data",
        autoDiscoverRoonLogDirectories: Bool = true,
        logDirectories: [String] = [],
        pollIntervalSeconds: Double = 0.75,
        dashboardPort: UInt16 = 17666,
        enableDemoModeWhenNoLogs: Bool = true,
        watchExistingLogsFromEnd: Bool = true,
        fileNameIncludes: [String] = ["log", "txt"],
        maxFilesPerDirectory: Int = 50,
        recentLogMaxLines: Int = 500,
        logHistoryMaxLines: Int = 5_000,
        maxLogLineCharacters: Int = 2_000,
        alertDedupeSeconds: Double = 45,
        logVolumeWindowMinutes: Int = 60,
        sendMacNotifications: Bool = true,
        showAllLogLines: Bool = true,
        memoryAlerts: MemoryAlertConfiguration = MemoryAlertConfiguration(),
        healthRules: HealthRuleConfiguration = HealthRuleConfiguration()
    ) {
        self.language = language
        self.baseDirectory = baseDirectory
        self.autoDiscoverRoonLogDirectories = autoDiscoverRoonLogDirectories
        self.logDirectories = logDirectories
        self.pollIntervalSeconds = pollIntervalSeconds
        self.dashboardPort = dashboardPort
        self.enableDemoModeWhenNoLogs = enableDemoModeWhenNoLogs
        self.watchExistingLogsFromEnd = watchExistingLogsFromEnd
        self.fileNameIncludes = fileNameIncludes
        self.maxFilesPerDirectory = maxFilesPerDirectory
        self.recentLogMaxLines = recentLogMaxLines
        self.logHistoryMaxLines = logHistoryMaxLines
        self.maxLogLineCharacters = maxLogLineCharacters
        self.alertDedupeSeconds = alertDedupeSeconds
        self.logVolumeWindowMinutes = logVolumeWindowMinutes
        self.sendMacNotifications = sendMacNotifications
        self.showAllLogLines = showAllLogLines
        self.memoryAlerts = memoryAlerts
        self.healthRules = healthRules
    }

    public static let `default` = AppConfiguration()

    private enum CodingKeys: String, CodingKey {
        case language
        case baseDirectory
        case autoDiscoverRoonLogDirectories
        case logDirectories
        case pollIntervalSeconds
        case dashboardPort
        case enableDemoModeWhenNoLogs
        case watchExistingLogsFromEnd
        case fileNameIncludes
        case maxFilesPerDirectory
        case recentLogMaxLines
        case logHistoryMaxLines
        case maxLogLineCharacters
        case alertDedupeSeconds
        case logVolumeWindowMinutes
        case sendMacNotifications
        case showAllLogLines
        case memoryAlerts
        case healthRules
    }

    public init(from decoder: Decoder) throws {
        let defaults = AppConfiguration.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = (try? container.decode(AppLanguage.self, forKey: .language)) ?? defaults.language
        baseDirectory = try container.decodeIfPresent(String.self, forKey: .baseDirectory) ?? defaults.baseDirectory
        autoDiscoverRoonLogDirectories = try container.decodeIfPresent(Bool.self, forKey: .autoDiscoverRoonLogDirectories) ?? defaults.autoDiscoverRoonLogDirectories
        logDirectories = try container.decodeIfPresent([String].self, forKey: .logDirectories) ?? defaults.logDirectories
        pollIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? defaults.pollIntervalSeconds
        dashboardPort = try container.decodeIfPresent(UInt16.self, forKey: .dashboardPort) ?? defaults.dashboardPort
        enableDemoModeWhenNoLogs = try container.decodeIfPresent(Bool.self, forKey: .enableDemoModeWhenNoLogs) ?? defaults.enableDemoModeWhenNoLogs
        watchExistingLogsFromEnd = try container.decodeIfPresent(Bool.self, forKey: .watchExistingLogsFromEnd) ?? defaults.watchExistingLogsFromEnd
        fileNameIncludes = try container.decodeIfPresent([String].self, forKey: .fileNameIncludes) ?? defaults.fileNameIncludes
        maxFilesPerDirectory = try container.decodeIfPresent(Int.self, forKey: .maxFilesPerDirectory) ?? defaults.maxFilesPerDirectory
        recentLogMaxLines = try container.decodeIfPresent(Int.self, forKey: .recentLogMaxLines) ?? defaults.recentLogMaxLines
        logHistoryMaxLines = try container.decodeIfPresent(Int.self, forKey: .logHistoryMaxLines) ?? defaults.logHistoryMaxLines
        maxLogLineCharacters = try container.decodeIfPresent(Int.self, forKey: .maxLogLineCharacters) ?? defaults.maxLogLineCharacters
        alertDedupeSeconds = try container.decodeIfPresent(Double.self, forKey: .alertDedupeSeconds) ?? defaults.alertDedupeSeconds
        logVolumeWindowMinutes = try container.decodeIfPresent(Int.self, forKey: .logVolumeWindowMinutes) ?? defaults.logVolumeWindowMinutes
        sendMacNotifications = try container.decodeIfPresent(Bool.self, forKey: .sendMacNotifications) ?? defaults.sendMacNotifications
        showAllLogLines = try container.decodeIfPresent(Bool.self, forKey: .showAllLogLines) ?? defaults.showAllLogLines
        memoryAlerts = try container.decodeIfPresent(MemoryAlertConfiguration.self, forKey: .memoryAlerts) ?? defaults.memoryAlerts
        healthRules = try container.decodeIfPresent(HealthRuleConfiguration.self, forKey: .healthRules) ?? defaults.healthRules
    }

    public func normalized() -> AppConfiguration {
        var copy = self
        copy.baseDirectory = copy.baseDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.pollIntervalSeconds = min(30, max(0.25, copy.pollIntervalSeconds))
        copy.dashboardPort = UInt16(min(65535, max(1024, Int(copy.dashboardPort))))
        copy.fileNameIncludes = copy.fileNameIncludes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if copy.fileNameIncludes.isEmpty {
            copy.fileNameIncludes = ["log", "txt"]
        }
        copy.maxFilesPerDirectory = min(500, max(1, copy.maxFilesPerDirectory))
        copy.recentLogMaxLines = min(10_000, max(100, copy.recentLogMaxLines))
        copy.logHistoryMaxLines = min(50_000, max(copy.recentLogMaxLines, copy.logHistoryMaxLines))
        copy.maxLogLineCharacters = min(20_000, max(200, copy.maxLogLineCharacters))
        copy.alertDedupeSeconds = min(600, max(5, copy.alertDedupeSeconds))
        let allowedWindows = [15, 60, 180, 360]
        if !allowedWindows.contains(copy.logVolumeWindowMinutes) {
            copy.logVolumeWindowMinutes = 60
        }
        copy.logDirectories = copy.logDirectories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        copy.memoryAlerts = copy.memoryAlerts.normalized()
        copy.healthRules = copy.healthRules.normalized()
        return copy
    }
}

public struct MemoryAlertConfiguration: Codable, Equatable {
    public var enabled: Bool
    public var physicalMemoryMB: Double
    public var unmanagedMemoryMB: Double
    public var managedMemoryMB: Double
    public var growthWindowMinutes: Double
    public var growthThresholdMB: Double
    public var minSamplesForGrowth: Int

    public init(
        enabled: Bool = true,
        physicalMemoryMB: Double = 2500,
        unmanagedMemoryMB: Double = 1800,
        managedMemoryMB: Double = 1200,
        growthWindowMinutes: Double = 30,
        growthThresholdMB: Double = 200,
        minSamplesForGrowth: Int = 5
    ) {
        self.enabled = enabled
        self.physicalMemoryMB = physicalMemoryMB
        self.unmanagedMemoryMB = unmanagedMemoryMB
        self.managedMemoryMB = managedMemoryMB
        self.growthWindowMinutes = growthWindowMinutes
        self.growthThresholdMB = growthThresholdMB
        self.minSamplesForGrowth = minSamplesForGrowth
    }

    func normalized() -> MemoryAlertConfiguration {
        var copy = self
        copy.physicalMemoryMB = max(1, copy.physicalMemoryMB)
        copy.unmanagedMemoryMB = max(1, copy.unmanagedMemoryMB)
        copy.managedMemoryMB = max(1, copy.managedMemoryMB)
        copy.growthWindowMinutes = min(24 * 60, max(1, copy.growthWindowMinutes))
        copy.growthThresholdMB = max(1, copy.growthThresholdMB)
        copy.minSamplesForGrowth = min(200, max(2, copy.minSamplesForGrowth))
        return copy
    }
}

public struct HealthRuleConfiguration: Codable, Equatable {
    public var logStaleWarningSeconds: Double
    public var logStaleCriticalSeconds: Double
    public var eventWindowMinutes: Double
    public var warningBurstCount: Int
    public var raatWindowMinutes: Double
    public var raatWarningDisconnects: Int
    public var raatCriticalDisconnects: Int
    public var databaseWindowMinutes: Double
    public var playbackWindowMinutes: Double
    public var playbackCriticalCount: Int
    public var diskWarningFreeMB: Double
    public var diskCriticalFreeMB: Double
    public var diskWarningFreeRatio: Double
    public var diskCriticalFreeRatio: Double
    public var processCPUWarningPercent: Double
    public var processMemoryWarningMB: Double
    public var trendSampleSeconds: Double

    public init(
        logStaleWarningSeconds: Double = 180,
        logStaleCriticalSeconds: Double = 600,
        eventWindowMinutes: Double = 15,
        warningBurstCount: Int = 5,
        raatWindowMinutes: Double = 15,
        raatWarningDisconnects: Int = 2,
        raatCriticalDisconnects: Int = 5,
        databaseWindowMinutes: Double = 30,
        playbackWindowMinutes: Double = 15,
        playbackCriticalCount: Int = 5,
        diskWarningFreeMB: Double = 10_240,
        diskCriticalFreeMB: Double = 2_048,
        diskWarningFreeRatio: Double = 0.05,
        diskCriticalFreeRatio: Double = 0.02,
        processCPUWarningPercent: Double = 80,
        processMemoryWarningMB: Double = 4_096,
        trendSampleSeconds: Double = 30
    ) {
        self.logStaleWarningSeconds = logStaleWarningSeconds
        self.logStaleCriticalSeconds = logStaleCriticalSeconds
        self.eventWindowMinutes = eventWindowMinutes
        self.warningBurstCount = warningBurstCount
        self.raatWindowMinutes = raatWindowMinutes
        self.raatWarningDisconnects = raatWarningDisconnects
        self.raatCriticalDisconnects = raatCriticalDisconnects
        self.databaseWindowMinutes = databaseWindowMinutes
        self.playbackWindowMinutes = playbackWindowMinutes
        self.playbackCriticalCount = playbackCriticalCount
        self.diskWarningFreeMB = diskWarningFreeMB
        self.diskCriticalFreeMB = diskCriticalFreeMB
        self.diskWarningFreeRatio = diskWarningFreeRatio
        self.diskCriticalFreeRatio = diskCriticalFreeRatio
        self.processCPUWarningPercent = processCPUWarningPercent
        self.processMemoryWarningMB = processMemoryWarningMB
        self.trendSampleSeconds = trendSampleSeconds
    }

    func normalized() -> HealthRuleConfiguration {
        var copy = self
        copy.logStaleWarningSeconds = min(86_400, max(15, copy.logStaleWarningSeconds))
        copy.logStaleCriticalSeconds = min(172_800, max(copy.logStaleWarningSeconds + 30, copy.logStaleCriticalSeconds))
        copy.eventWindowMinutes = min(24 * 60, max(1, copy.eventWindowMinutes))
        copy.warningBurstCount = min(500, max(1, copy.warningBurstCount))
        copy.raatWindowMinutes = min(24 * 60, max(1, copy.raatWindowMinutes))
        copy.raatWarningDisconnects = min(500, max(1, copy.raatWarningDisconnects))
        copy.raatCriticalDisconnects = min(500, max(copy.raatWarningDisconnects, copy.raatCriticalDisconnects))
        copy.databaseWindowMinutes = min(24 * 60, max(1, copy.databaseWindowMinutes))
        copy.playbackWindowMinutes = min(24 * 60, max(1, copy.playbackWindowMinutes))
        copy.playbackCriticalCount = min(500, max(1, copy.playbackCriticalCount))
        copy.diskWarningFreeMB = min(10_485_760, max(256, copy.diskWarningFreeMB))
        copy.diskCriticalFreeMB = min(copy.diskWarningFreeMB, max(128, copy.diskCriticalFreeMB))
        copy.diskWarningFreeRatio = min(0.9, max(0.001, copy.diskWarningFreeRatio))
        copy.diskCriticalFreeRatio = min(copy.diskWarningFreeRatio, max(0.001, copy.diskCriticalFreeRatio))
        copy.processCPUWarningPercent = min(1_000, max(1, copy.processCPUWarningPercent))
        copy.processMemoryWarningMB = min(1_048_576, max(64, copy.processMemoryWarningMB))
        copy.trendSampleSeconds = min(3_600, max(5, copy.trendSampleSeconds))
        return copy
    }
}

public struct ConfigDocument: Codable, Equatable {
    public var configPath: String
    public var config: AppConfiguration
    public var lastError: String?
}
