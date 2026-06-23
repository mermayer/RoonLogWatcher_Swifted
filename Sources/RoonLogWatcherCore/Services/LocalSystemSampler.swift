import Foundation

public struct LocalSystemSampler {
    private let fileManager: FileManager
    private let processNames: Set<String>

    public init(
        fileManager: FileManager = .default,
        processNames: Set<String> = ["RoonServer", "RAATServer", "RoonAppliance", "Roon", "RoonBridge"]
    ) {
        self.fileManager = fileManager
        self.processNames = processNames
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
        let output = run("/bin/ps", arguments: ["-axo", "pid=,comm=,pcpu=,rss="])
        return output
            .split(separator: "\n")
            .compactMap(parseProcessLine)
            .filter { processNames.contains($0.name) || processNames.contains(URL(fileURLWithPath: $0.path).lastPathComponent) }
            .map { process in
                var copy = process
                if includeOpenFiles {
                    copy.openFiles = openFileCount(pid: process.pid)
                }
                return copy
            }
    }

    private func parseProcessLine(_ line: Substring) -> RoonProcessStatus? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 4,
              let pid = Int(parts[0]),
              let cpu = Double(parts[2]),
              let rssKB = Double(parts[3])
        else { return nil }

        let path = String(parts[1])
        let name = URL(fileURLWithPath: path).lastPathComponent
        return RoonProcessStatus(
            pid: pid,
            name: name,
            path: path,
            cpuPercent: cpu,
            memoryMB: rssKB / 1024,
            openFiles: nil
        )
    }

    private func openFileCount(pid: Int) -> Int? {
        let output = run("/usr/sbin/lsof", arguments: ["-n", "-p", String(pid)])
        let count = output.split(separator: "\n").dropFirst().count
        return count > 0 ? count : nil
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

    private func run(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
