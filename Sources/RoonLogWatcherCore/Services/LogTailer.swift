import Darwin
import Foundation

public final class LogTailer {
    private let discoverer: RoonLogDiscoverer
    private let configStore: AppConfigStore?
    private let onLine: (String, String) -> Void
    private let queue = DispatchQueue(label: "RoonLogWatcher.LogTailer")
    private var timer: DispatchSourceTimer?
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var positions: [String: UInt64] = [:]
    private var pendingData: [String: Data] = [:]
    private var truncatedPendingFiles: Set<String> = []
    private var scheduledBacklogReads: Set<String> = []
    private var fileIdentities: [String: FileIdentity] = [:]
    private var files: [String] = []
    private let maxReadBytesPerFilePerPoll: Int
    private let rediscoveryInterval: TimeInterval = 15
    private var nextRediscoveryAt = Date.distantPast

    public init(
        discoverer: RoonLogDiscoverer,
        configStore: AppConfigStore? = nil,
        maxReadBytesPerFilePerPoll: Int = 256 * 1_024,
        onLine: @escaping (String, String) -> Void
    ) {
        self.discoverer = discoverer
        self.configStore = configStore
        self.maxReadBytesPerFilePerPoll = max(1_024, maxReadBytesPerFilePerPoll)
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
                fileIdentities[file] = fileState(file)?.identity
                installFileSource(for: file)
            }
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(fallbackPollIntervalMilliseconds()))
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
            for source in fileSources.values {
                source.cancel()
            }
            fileSources = [:]
            files = []
            positions = [:]
            pendingData = [:]
            truncatedPendingFiles = []
            scheduledBacklogReads = []
            fileIdentities = [:]
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
            if latestSet.contains(file) {
                return false
            }
            positions[file] = nil
            pendingData[file] = nil
            truncatedPendingFiles.remove(file)
            scheduledBacklogReads.remove(file)
            fileIdentities[file] = nil
            removeFileSource(for: file)
            return true
        }
        for file in latest {
            if !files.contains(file) {
                files.append(file)
                positions[file] = initialPosition(for: file)
                fileIdentities[file] = fileState(file)?.identity
            }
            installFileSource(for: file)
        }
    }

    private func readNewLines(file: String) {
        guard let state = fileState(file) else { return }
        let end = state.size
        let identity = state.identity
        var start = positions[file] ?? end
        if let previousIdentity = fileIdentities[file],
           previousIdentity != identity {
            start = 0
            positions[file] = 0
            pendingData[file] = nil
            truncatedPendingFiles.remove(file)
        }
        fileIdentities[file] = identity

        if end < start {
            start = 0
            positions[file] = 0
            pendingData[file] = nil
            truncatedPendingFiles.remove(file)
        }
        guard end > start else { return }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: file)) else { return }
        do {
            try handle.seek(toOffset: start)
            let unreadBytes = end - start
            let readCount = min(UInt64(maxReadBytesPerFilePerPoll), unreadBytes)
            let data = try handle.read(upToCount: Int(readCount)) ?? Data()
            try handle.close()
            guard !data.isEmpty else { return }
            positions[file] = start + UInt64(data.count)
            consumeCompleteLines(file: file, newData: data)
            if start + UInt64(data.count) < end {
                scheduleBacklogRead(for: file)
            }
        } catch {
            try? handle.close()
        }
    }

    private func consumeCompleteLines(file: String, newData: Data) {
        if truncatedPendingFiles.contains(file) {
            guard let newline = newData.firstIndex(of: 0x0A) else { return }
            emitLine(file: file, data: pendingData[file] ?? Data(), wasTruncated: true)
            pendingData[file] = nil
            truncatedPendingFiles.remove(file)
            let remainderStart = newData.index(after: newline)
            if remainderStart < newData.endIndex {
                consumeCompleteLines(file: file, newData: Data(newData[remainderStart...]))
            }
            return
        }

        var buffer = pendingData[file] ?? Data()
        buffer.append(newData)

        guard let finalNewline = buffer.lastIndex(of: 0x0A) else {
            let maxPendingBytes = maximumPendingLineBytes()
            if buffer.count > maxPendingBytes {
                pendingData[file] = Data(buffer.prefix(maxPendingBytes))
                truncatedPendingFiles.insert(file)
            } else {
                pendingData[file] = buffer
            }
            return
        }

        let completeData = buffer[...finalNewline]
        pendingData[file] = Data(buffer[buffer.index(after: finalNewline)...])

        for rawLine in completeData.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var lineData = rawLine
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            emitLine(file: file, data: Data(lineData), wasTruncated: false)
        }
    }

    private func emitLine(file: String, data: Data, wasTruncated: Bool) {
        guard !data.isEmpty else { return }
        let maxBytes = maximumPendingLineBytes()
        let shouldTruncate = wasTruncated || data.count > maxBytes
        let renderedData = shouldTruncate ? Data(data.prefix(maxBytes)) : data
        var line = String(decoding: renderedData, as: UTF8.self)
        if shouldTruncate {
            line += " ... [tailer truncated oversized line]"
        }
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onLine(file, line)
    }

    private func maximumPendingLineBytes() -> Int {
        let maxCharacters = configStore?.configuration.maxLogLineCharacters
            ?? discoverer.configuration.maxLogLineCharacters
        return max(64 * 1_024, maxCharacters * 4)
    }

    private func initialPosition(for file: String) -> UInt64 {
        if configStore?.configuration.watchExistingLogsFromEnd == false {
            return 0
        }
        return fileState(file)?.size ?? 0
    }

    private func fileState(_ path: String) -> FileState? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return FileState(
            size: size.uint64Value,
            identity: FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
        )
    }

    private func fallbackPollIntervalMilliseconds() -> Int {
        let seconds = configStore?.configuration.pollIntervalSeconds ?? discoverer.configuration.pollIntervalSeconds
        return max(5_000, Int(seconds * 1000))
    }

    private func installFileSource(for file: String) {
        guard fileSources[file] == nil else { return }
        let descriptor = open(file, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleFileEvent(for: file)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        fileSources[file] = source
        source.resume()
    }

    private func removeFileSource(for file: String) {
        guard let source = fileSources.removeValue(forKey: file) else { return }
        source.cancel()
    }

    private func handleFileEvent(for file: String) {
        let events = fileSources[file]?.data ?? []
        readNewLines(file: file)
        if events.contains(.rename) || events.contains(.delete) || events.contains(.revoke) {
            removeFileSource(for: file)
            nextRediscoveryAt = .distantPast
            refreshDiscoveredFilesIfNeeded()
        }
    }

    private func scheduleBacklogRead(for file: String) {
        guard scheduledBacklogReads.insert(file).inserted else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            guard let self else { return }
            self.scheduledBacklogReads.remove(file)
            guard self.files.contains(file) else { return }
            self.readNewLines(file: file)
        }
    }

    func pollNowForTesting() {
        queue.sync {
            poll()
        }
    }
}

private struct FileIdentity: Equatable {
    var device: UInt64
    var inode: UInt64
}

private struct FileState {
    var size: UInt64
    var identity: FileIdentity
}
