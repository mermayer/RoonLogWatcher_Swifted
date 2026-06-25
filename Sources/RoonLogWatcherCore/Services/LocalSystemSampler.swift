import Darwin
import Foundation

public struct LocalSystemSampler {
    private let fileManager: FileManager
    private let processNames: Set<String>
    private let processListingProvider: () -> String
    private let openFileCountProvider: (Int) -> Int?

    public init(
        fileManager: FileManager = .default,
        processNames: Set<String> = ["RoonServer", "RAATServer", "RoonAppliance", "Roon", "RoonBridge"],
        processListingProvider: (() -> String)? = nil,
        openFileCountProvider: ((Int) -> Int?)? = nil
    ) {
        self.fileManager = fileManager
        self.processNames = processNames
        self.processListingProvider = processListingProvider ?? {
            Self.roonProcessListing(processNames: processNames)
        }
        self.openFileCountProvider = openFileCountProvider ?? { pid in
            Self.openFileCount(pid: pid)
        }
    }

    public func sample(discoverer: RoonLogDiscoverer, includeOpenFiles: Bool = false) -> LocalSystemStatus {
        let now = Date()
        let processes = roonProcesses(includeOpenFiles: includeOpenFiles)
        let host = detectHost(discoverer: discoverer, processes: processes, now: now)
        let disk = diskStatus(discoverer: discoverer)
        let openFileSamples = processes.compactMap(\.openFiles)

        return LocalSystemStatus(
            sampledAt: now,
            host: host,
            processes: processes,
            totalCPUPercent: processes.reduce(0) { $0 + $1.cpuPercent },
            totalMemoryMB: processes.reduce(0) { $0 + $1.memoryMB },
            openFileCount: openFileSamples.isEmpty ? nil : openFileSamples.reduce(0, +),
            logVolumePath: disk?.path,
            logVolumeFreeMB: disk?.freeMB,
            logVolumeFreeRatio: disk?.freeRatio
        )
    }

    public func detectHost(discoverer: RoonLogDiscoverer) -> RoonHostStatus {
        detectHost(discoverer: discoverer, processes: roonProcesses(includeOpenFiles: false), now: Date())
    }

    private func detectHost(discoverer: RoonLogDiscoverer, processes: [RoonProcessStatus], now: Date) -> RoonHostStatus {
        let directories = discoverer.discoverDirectories()
        let processNames = Array(Set(processes.map(\.name))).sorted()
        let reason: String
        if !processes.isEmpty {
            reason = "Roon process detected"
        } else if !directories.isEmpty {
            reason = "Roon log directory detected"
        } else {
            reason = "No local Roon Server indicators found"
        }

        return RoonHostStatus(
            isRoonServerLikely: !processes.isEmpty || !directories.isEmpty,
            reason: reason,
            detectedProcesses: processNames,
            detectedLogDirectories: directories,
            checkedAt: now
        )
    }

    private func roonProcesses(includeOpenFiles: Bool) -> [RoonProcessStatus] {
        let output = processListingProvider()
        return output
            .split(separator: "\n")
            .compactMap(parseProcessLine)
            .map { process in
                var copy = process
                if includeOpenFiles {
                    copy.openFiles = openFileCountProvider(process.pid)
                }
                return copy
            }
    }

    private func parseProcessLine(_ line: Substring) -> RoonProcessStatus? {
        let parts = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 4,
              let pid = Int(parts[0]),
              let cpu = Double(parts[1]),
              let rssKB = Double(parts[2])
        else { return nil }

        let command = String(parts[3])
        guard let name = processName(in: command) else { return nil }
        return RoonProcessStatus(
            pid: pid,
            name: name,
            path: executablePath(in: command),
            cpuPercent: cpu,
            memoryMB: rssKB / 1024,
            openFiles: nil
        )
    }

    private func processName(in command: String) -> String? {
        let executableName = URL(fileURLWithPath: executablePath(in: command)).lastPathComponent
        return processNames.contains(executableName) ? executableName : nil
    }

    private func executablePath(in command: String) -> String {
        String(command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? Substring(command))
    }

    private static func openFileCount(pid: Int) -> Int? {
        if let count = procOpenFileCount(pid: pid) {
            return count
        }

        let output = run(
            "/bin/sh",
            arguments: ["-c", "/usr/sbin/lsof -n -p \(pid) 2>/dev/null | /usr/bin/wc -l"],
            timeout: 6
        )
        let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)).map { max(0, $0 - 1) } ?? 0
        return count > 0 ? count : nil
    }

    private static func procOpenFileCount(pid: Int) -> Int? {
        let processID = Int32(pid)
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        var lastCount: Int?

        for capacity in [256, 512, 1_024, 2_048, 4_096, 8_192] {
            let bufferSize = capacity * entrySize
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: bufferSize,
                alignment: MemoryLayout<proc_fdinfo>.alignment
            )
            defer { buffer.deallocate() }

            let returnedBytes = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, buffer, Int32(bufferSize))
            guard returnedBytes > 0 else { continue }

            let count = Int(returnedBytes) / entrySize
            lastCount = count
            if Int(returnedBytes) < bufferSize {
                return count
            }
        }

        return lastCount
    }

    private static func roonProcessListing(processNames: Set<String>) -> String {
        let pattern = processNames.sorted().joined(separator: "|")
        let pidOutput = run("/usr/bin/pgrep", arguments: ["-x", pattern], timeout: 2)
        let pids = pidOutput
            .split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
            .compactMap { Int($0) }
            .map(String.init)

        guard !pids.isEmpty else { return "" }
        return run(
            "/bin/ps",
            arguments: ["-p", pids.joined(separator: ","), "-o", "pid=,pcpu=,rss=,command="],
            timeout: 2
        )
    }

    private func diskStatus(discoverer: RoonLogDiscoverer) -> (path: String, freeMB: Double, freeRatio: Double)? {
        let config = discoverer.configuration
        let candidates = discoverer.discoverDirectories()
            + [config.baseDirectory, NSHomeDirectory()]

        for candidate in candidates where !candidate.isEmpty {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory) else { continue }
            let path = isDirectory.boolValue ? candidate : URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            guard let attributes = try? fileManager.attributesOfFileSystem(forPath: path),
                  let free = attributes[.systemFreeSize] as? NSNumber,
                  let size = attributes[.systemSize] as? NSNumber,
                  size.doubleValue > 0
            else { continue }
            return (
                path: path,
                freeMB: free.doubleValue / 1_048_576,
                freeRatio: free.doubleValue / size.doubleValue
            )
        }
        return nil
    }

    private static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 4) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
            if completion.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                _ = completion.wait(timeout: .now() + 1)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
