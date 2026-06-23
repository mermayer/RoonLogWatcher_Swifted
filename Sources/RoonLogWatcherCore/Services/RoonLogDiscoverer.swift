import Foundation

public struct RoonLogDiscoverer {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let configStore: AppConfigStore?

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configStore: AppConfigStore? = nil
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.configStore = configStore
    }

    public var configuration: AppConfiguration {
        configStore?.configuration ?? .default
    }

    public func discoverDirectories() -> [String] {
        let config = configuration
        let home = NSHomeDirectory()
        var candidates: [String] = config.logDirectories

        if config.autoDiscoverRoonLogDirectories {
            let base = config.baseDirectory.isEmpty ? "/Volumes/Data" : config.baseDirectory
            candidates.append(contentsOf: [
                "\(home)/Library/Roon/Logs",
                "\(home)/Library/RoonServer/Logs",
                "\(home)/Library/RAATServer/Logs",
                "\(home)/Library/Application Support/Roon/Logs",
                "\(home)/Library/Application Support/RoonServer/Logs",
                "/Users/Shared/Roon/Logs",
                "/Users/Shared/RoonServer/Logs",
                "/Users/Shared/RAATServer/Logs",
                "/Users/Shared/Roon/Application Support/Roon/Logs",
                "/Users/Shared/RoonServer/Application Support/RoonServer/Logs",
                "/Library/RoonServer/Logs",
                "/Library/RAATServer/Logs",
                "\(base)/Logs",
                "\(base)/RoonServer/Logs",
                "\(base)/RAATServer/Logs",
                "\(base)/RoonAppliance/Logs",
                "\(base)/RoonBridge/Logs"
            ])
        }

        for key in ["ROON_LOG_DIR", "ROONSERVER_LOG_DIR", "ROONSERVER_DATAROOT"] {
            guard let value = environment[key], !value.isEmpty else { continue }
            candidates.append(value)
            candidates.append("\(value)/Logs")
            candidates.append("\(value)/RoonServer/Logs")
        }

        return Array(Set(candidates.map { NSString(string: $0).standardizingPath }))
            .filter(isDirectory)
            .sorted()
    }

    public func discoverLogFiles(maxFilesPerDirectory: Int? = nil) -> [String] {
        let limit = maxFilesPerDirectory ?? configuration.maxFilesPerDirectory
        return discoverDirectories().flatMap { directory in
            logFiles(in: directory, maxFiles: limit)
        }
    }

    public func logFiles(in directory: String, maxFiles: Int = 40) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            .map { "\(directory)/\($0)" }
            .filter { path in
                guard isFile(path) else { return false }
                let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
                guard !name.hasPrefix("._") else { return false }
                let includes = configuration.fileNameIncludes
                return includes.contains { name.contains($0.lowercased()) }
            }
            .sorted { left, right in
                modificationDate(left) > modificationDate(right)
            }
            .prefix(max(1, maxFiles))
            .map { $0 }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func modificationDate(_ path: String) -> Date {
        ((try? fileManager.attributesOfItem(atPath: path)[.modificationDate]) as? Date) ?? .distantPast
    }
}
