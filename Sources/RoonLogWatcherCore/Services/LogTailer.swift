import Foundation

public final class LogTailer {
    private let discoverer: RoonLogDiscoverer
    private let configStore: AppConfigStore?
    private let onLine: (String, String) -> Void
    private let queue = DispatchQueue(label: "RoonLogWatcher.LogTailer")
    private var timer: DispatchSourceTimer?
    private var positions: [String: UInt64] = [:]
    private var files: [String] = []
    private let rediscoveryInterval: TimeInterval = 15
    private var nextRediscoveryAt = Date.distantPast

    public init(discoverer: RoonLogDiscoverer, configStore: AppConfigStore? = nil, onLine: @escaping (String, String) -> Void) {
        self.discoverer = discoverer
        self.configStore = configStore
        self.onLine = onLine
    }

    public var currentFiles: [String] {
        queue.sync { files }
    }

    @discardableResult
    public func start() -> Bool {
        let discovered = discoverer.discoverLogFiles()
        guard !discovered.isEmpty else { return false }

        queue.sync {
            files = discovered
            nextRediscoveryAt = Date().addingTimeInterval(rediscoveryInterval)
            for file in discovered where positions[file] == nil {
                positions[file] = initialPosition(for: file)
            }
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(pollIntervalMilliseconds()))
        source.setEventHandler { [weak self] in
            self?.poll()
        }
        timer = source
        source.resume()
        return true
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            files = []
            positions = [:]
            nextRediscoveryAt = .distantPast
        }
    }

    private func poll() {
        refreshDiscoveredFilesIfNeeded()

        for file in files {
            readNewLines(file: file)
        }
    }

    private func refreshDiscoveredFilesIfNeeded() {
        let now = Date()
        guard now >= nextRediscoveryAt else { return }
        nextRediscoveryAt = now.addingTimeInterval(rediscoveryInterval)

        let latest = discoverer.discoverLogFiles()
        let latestSet = Set(latest)
        files.removeAll { file in
            !latestSet.contains(file) && !FileManager.default.fileExists(atPath: file)
        }
        for file in latest where !files.contains(file) {
            files.append(file)
            positions[file] = initialPosition(for: file)
        }
    }

    private func readNewLines(file: String) {
        let end = fileSize(file)
        let start = positions[file] ?? end
        if end < start {
            positions[file] = 0
        }
        let effectiveStart = min(start, end)
        guard end > effectiveStart else { return }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: file)) else { return }
        do {
            try handle.seek(toOffset: effectiveStart)
            let data = try handle.read(upToCount: Int(end - effectiveStart)) ?? Data()
            try handle.close()
            positions[file] = end
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onLine(file, line)
            }
        } catch {
            try? handle.close()
        }
    }

    private func fileSize(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func initialPosition(for file: String) -> UInt64 {
        if configStore?.configuration.watchExistingLogsFromEnd == false {
            return 0
        }
        return fileSize(file)
    }

    private func pollIntervalMilliseconds() -> Int {
        let seconds = configStore?.configuration.pollIntervalSeconds ?? discoverer.configuration.pollIntervalSeconds
        return max(250, Int(seconds * 1000))
    }
}
