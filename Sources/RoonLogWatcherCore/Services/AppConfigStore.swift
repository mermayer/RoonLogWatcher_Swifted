import Foundation

public final class AppConfigStore {
    private let lock = NSLock()
    public let configURL: URL
    private var current: AppConfiguration
    private var errorMessage: String?

    public init(configURL: URL? = nil) {
        self.configURL = configURL ?? Self.defaultConfigURL()
        self.current = .default
        loadOrCreate()
    }

    public var configuration: AppConfiguration {
        lock.withLock { current }
    }

    public var lastError: String? {
        lock.withLock { errorMessage }
    }

    public func document() -> ConfigDocument {
        lock.withLock {
            ConfigDocument(configPath: configURL.path, config: current, lastError: errorMessage)
        }
    }

    public func reload() {
        loadOrCreate()
    }

    public func save(_ config: AppConfiguration) throws {
        let normalized = config.normalized()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configURL, options: [.atomic])
        lock.withLock {
            current = normalized
            errorMessage = nil
        }
    }

    public func saveJSON(_ body: String) throws {
        let data = Data(body.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        try save(decoded)
    }

    public func jsonDocument() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document()) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func defaultConfigURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("RoonLogWatcher", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private func loadOrCreate() {
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: configURL.path) {
                try writeDefaultConfig()
            }

            let data = try Data(contentsOf: configURL)
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data).normalized()
            lock.withLock {
                current = decoded
                errorMessage = nil
            }
        } catch {
            lock.withLock {
                current = .default
                errorMessage = error.localizedDescription
            }
        }
    }

    private func writeDefaultConfig() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(AppConfiguration.default)
        try data.write(to: configURL, options: [.atomic])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
