import Darwin
import Foundation

public final class LocalSystemSampler {
    private let fileManager: FileManager
    private let processNames: Set<String>
    private let processListingProvider: (() -> String)?
    private let openFileCountProvider: (Int) -> Int?
    private let diskIOProvider: (Int) -> (readBytes: UInt64, writeBytes: UInt64)?
    private let swapUsageProvider: () -> (totalMB: Double, usedMB: Double, freeMB: Double)?
    private let swapActivityProvider: () -> (pageSize: UInt64, swapIns: UInt64, swapOuts: UInt64)?
    private let nowProvider: () -> Date
    private var previousDiskCounters: [Int: (readBytes: UInt64, writeBytes: UInt64)] = [:]
    private var previousDiskSampleAt: Date?
    private var previousSwapCounters: (swapIns: UInt64, swapOuts: UInt64)?
    private var previousSwapSampleAt: Date?
    private var previousProcessCPUNanoseconds: [Int: UInt64] = [:]
    private var previousProcessSampleAt: Date?

    public init(
        fileManager: FileManager = .default,
        processNames: Set<String> = ["RoonServer", "RAATServer", "RoonAppliance", "Roon", "RoonBridge"],
        processListingProvider: (() -> String)? = nil,
        openFileCountProvider: ((Int) -> Int?)? = nil,
        diskIOProvider: ((Int) -> (readBytes: UInt64, writeBytes: UInt64)?)? = nil,
        swapUsageProvider: (() -> (totalMB: Double, usedMB: Double, freeMB: Double)?)? = nil,
        swapActivityProvider: (() -> (pageSize: UInt64, swapIns: UInt64, swapOuts: UInt64)?)? = nil,
        nowProvider: (() -> Date)? = nil
    ) {
        self.fileManager = fileManager
        self.processNames = processNames
        self.processListingProvider = processListingProvider
        self.openFileCountProvider = openFileCountProvider ?? { pid in
            Self.openFileCount(pid: pid)
        }
        self.diskIOProvider = diskIOProvider ?? { pid in
            Self.diskIOCounters(pid: pid)
        }
        self.swapUsageProvider = swapUsageProvider ?? Self.swapUsage
        self.swapActivityProvider = swapActivityProvider ?? Self.vmSwapCounters
        self.nowProvider = nowProvider ?? Date.init
    }

    public func sample(discoverer: RoonLogDiscoverer, includeOpenFiles: Bool = false) -> LocalSystemStatus {
        let now = nowProvider()
        let processes = roonProcesses(includeOpenFiles: includeOpenFiles, includeDiskIO: true, now: now)
        let host = detectHost(discoverer: discoverer, processes: processes, now: now)
        let disk = diskStatus(discoverer: discoverer)
        let openFileSamples = processes.compactMap(\.openFiles)
        let readRateSamples = processes.compactMap(\.diskReadRateMBps)
        let writeRateSamples = processes.compactMap(\.diskWriteRateMBps)
        let swap = swapUsageProvider()
        let swapRatio = swap.flatMap { $0.totalMB > 0 ? $0.usedMB / $0.totalMB : nil }
        let swapRates = swapActivityRates(now: now)

        return LocalSystemStatus(
            sampledAt: now,
            host: host,
            processes: processes,
            totalCPUPercent: processes.reduce(0) { $0 + $1.cpuPercent },
            totalMemoryMB: processes.reduce(0) { $0 + $1.memoryMB },
            totalPhysicalMemoryMB: Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576,
            openFileCount: openFileSamples.isEmpty ? nil : openFileSamples.reduce(0, +),
            totalDiskReadRateMBps: readRateSamples.isEmpty ? nil : readRateSamples.reduce(0, +),
            totalDiskWriteRateMBps: writeRateSamples.isEmpty ? nil : writeRateSamples.reduce(0, +),
            swapTotalMB: swap?.totalMB,
            swapUsedMB: swap?.usedMB,
            swapFreeMB: swap?.freeMB,
            swapUsedRatio: swapRatio,
            swapInRateMBps: swapRates?.inRateMBps,
            swapOutRateMBps: swapRates?.outRateMBps,
            logVolumePath: disk?.path,
            logVolumeFreeMB: disk?.freeMB,
            logVolumeFreeRatio: disk?.freeRatio
        )
    }

    public func detectHost(discoverer: RoonLogDiscoverer) -> RoonHostStatus {
        detectHost(discoverer: discoverer, processes: roonProcesses(includeOpenFiles: false, includeDiskIO: false, now: nowProvider()), now: nowProvider())
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

    private func roonProcesses(includeOpenFiles: Bool, includeDiskIO: Bool, now: Date) -> [RoonProcessStatus] {
        guard let processListingProvider else {
            return directRoonProcesses(includeOpenFiles: includeOpenFiles, includeDiskIO: includeDiskIO, now: now)
        }

        let output = processListingProvider()
        let previousCounters = previousDiskCounters
        let previousSampleAt = previousDiskSampleAt
        var currentCounters: [Int: (readBytes: UInt64, writeBytes: UInt64)] = [:]
        let elapsed = previousSampleAt.map { now.timeIntervalSince($0) } ?? 0

        let processes = output
            .split(separator: "\n")
            .compactMap(parseProcessLine)
            .map { process in
                var copy = process
                if includeOpenFiles {
                    copy.openFiles = openFileCountProvider(process.pid)
                }
                if includeDiskIO, let counters = diskIOProvider(process.pid) {
                    currentCounters[process.pid] = counters
                    copy.diskReadBytes = counters.readBytes
                    copy.diskWriteBytes = counters.writeBytes
                    if elapsed > 0, let previous = previousCounters[process.pid] {
                        copy.diskReadRateMBps = Self.rateMBps(current: counters.readBytes, previous: previous.readBytes, elapsed: elapsed)
                        copy.diskWriteRateMBps = Self.rateMBps(current: counters.writeBytes, previous: previous.writeBytes, elapsed: elapsed)
                    }
                }
                return copy
            }

        if includeDiskIO {
            previousDiskCounters = currentCounters
            previousDiskSampleAt = now
        }

        return processes
    }

    private func directRoonProcesses(includeOpenFiles: Bool, includeDiskIO: Bool, now: Date) -> [RoonProcessStatus] {
        let previousDisk = previousDiskCounters
        let previousCPU = previousProcessCPUNanoseconds
        let diskElapsed = previousDiskSampleAt.map { now.timeIntervalSince($0) } ?? 0
        let cpuElapsed = previousProcessSampleAt.map { now.timeIntervalSince($0) } ?? 0
        var currentDisk: [Int: (readBytes: UInt64, writeBytes: UInt64)] = [:]
        var currentCPU: [Int: UInt64] = [:]

        let processes = Self.allProcessIDs().compactMap { pid -> RoonProcessStatus? in
            guard let path = Self.processPath(pid: pid) else { return nil }
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard processNames.contains(name), let counters = Self.processResourceCounters(pid: pid) else { return nil }

            let processID = Int(pid)
            let cpuNanoseconds = counters.userNanoseconds &+ counters.systemNanoseconds
            currentCPU[processID] = cpuNanoseconds
            if includeDiskIO {
                currentDisk[processID] = (counters.readBytes, counters.writeBytes)
            }

            let cpuPercent: Double
            if cpuElapsed > 0, let previous = previousCPU[processID], cpuNanoseconds >= previous {
                cpuPercent = Double(cpuNanoseconds - previous) / (cpuElapsed * 1_000_000_000) * 100
            } else {
                cpuPercent = 0
            }

            var process = RoonProcessStatus(
                pid: processID,
                name: name,
                path: path,
                cpuPercent: cpuPercent,
                memoryMB: Double(counters.residentBytes) / 1_048_576,
                openFiles: includeOpenFiles ? openFileCountProvider(processID) : nil,
                diskReadBytes: includeDiskIO ? counters.readBytes : nil,
                diskWriteBytes: includeDiskIO ? counters.writeBytes : nil
            )
            if includeDiskIO, diskElapsed > 0, let previous = previousDisk[processID] {
                process.diskReadRateMBps = Self.rateMBps(current: counters.readBytes, previous: previous.readBytes, elapsed: diskElapsed)
                process.diskWriteRateMBps = Self.rateMBps(current: counters.writeBytes, previous: previous.writeBytes, elapsed: diskElapsed)
            }
            return process
        }.sorted {
            if $0.name == $1.name { return $0.pid < $1.pid }
            return $0.name < $1.name
        }

        previousProcessCPUNanoseconds = currentCPU
        previousProcessSampleAt = now
        if includeDiskIO {
            previousDiskCounters = currentDisk
            previousDiskSampleAt = now
        }
        return processes
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

    private static func diskIOCounters(pid: Int) -> (readBytes: UInt64, writeBytes: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(Int32(pid), RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (
            readBytes: info.ri_diskio_bytesread,
            writeBytes: info.ri_diskio_byteswritten
        )
    }

    private static func rateMBps(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, current >= previous else { return 0 }
        return Double(current - previous) / elapsed / 1_048_576
    }

    private static func allProcessIDs() -> [pid_t] {
        let estimatedCount = max(1, Int(proc_listallpids(nil, 0)))
        var processIDs = [pid_t](repeating: 0, count: estimatedCount + 64)
        let returnedCount = processIDs.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedCount > 0 else { return [] }
        return Array(processIDs.prefix(Int(returnedCount))).filter { $0 > 0 }
    }

    private static func processPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processResourceCounters(pid: pid_t) -> ProcessResourceCounters? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return ProcessResourceCounters(
            residentBytes: info.ri_resident_size,
            userNanoseconds: info.ri_user_time,
            systemNanoseconds: info.ri_system_time,
            readBytes: info.ri_diskio_bytesread,
            writeBytes: info.ri_diskio_byteswritten
        )
    }

    private static func swapUsage() -> (totalMB: Double, usedMB: Double, freeMB: Double)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (
            totalMB: Double(usage.xsu_total) / 1_048_576,
            usedMB: Double(usage.xsu_used) / 1_048_576,
            freeMB: Double(usage.xsu_avail) / 1_048_576
        )
    }

    private func swapActivityRates(now: Date) -> (inRateMBps: Double, outRateMBps: Double)? {
        guard let current = swapActivityProvider() else { return nil }
        defer {
            previousSwapCounters = (current.swapIns, current.swapOuts)
            previousSwapSampleAt = now
        }
        guard let previous = previousSwapCounters,
              let previousAt = previousSwapSampleAt,
              current.swapIns >= previous.swapIns,
              current.swapOuts >= previous.swapOuts
        else { return nil }

        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed > 0 else { return nil }
        let pageSize = Double(current.pageSize)
        return (
            inRateMBps: Double(current.swapIns - previous.swapIns) * pageSize / elapsed / 1_048_576,
            outRateMBps: Double(current.swapOuts - previous.swapOuts) * pageSize / elapsed / 1_048_576
        )
    }

    private static func vmSwapCounters() -> (pageSize: UInt64, swapIns: UInt64, swapOuts: UInt64)? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (
            pageSize: UInt64(vm_kernel_page_size),
            swapIns: UInt64(statistics.swapins),
            swapOuts: UInt64(statistics.swapouts)
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

private struct ProcessResourceCounters {
    var residentBytes: UInt64
    var userNanoseconds: UInt64
    var systemNanoseconds: UInt64
    var readBytes: UInt64
    var writeBytes: UInt64
}
