import Foundation
import Darwin
import AppKit

struct SystemSample {
    let snapshot: MemorySnapshot
    let apps: [AppMemoryUsage]
    let load: MachineLoadSnapshot
    var telemetry: MachineHardwareTelemetry = MachineHardwareTelemetry()
}

final class SystemSampler: @unchecked Sendable {
    // MemoryMonitor 串行调用 sample，不并行读写差分基线。
    private let loadSampler = LoadSampler()
    private let telemetrySampler = MachineTelemetrySampler()
    private var cpuCounters: [Int32: ProcessCPUCounter] = [:]
    private var lastDetailedSampleAt: Date?
    private let compressedCacheLock = NSLock()
    private var compressedCache: [Int32: UInt64] = [:]
    private var lastCompressedSampleAt: Date = .distantPast
    private let compressedSampleInterval: TimeInterval = 60

    func sample() async throws -> SystemSample {
        if let previous = lastDetailedSampleAt, Date().timeIntervalSince(previous) > 10 {
            cpuCounters.removeAll(keepingCapacity: true)
            loadSampler.resetCPUBaseline()
            telemetrySampler.resetBaselines()
        }
        async let memory = readMemorySnapshot()
        async let processRows = readProcesses()
        var snapshot = try await memory
        let rows = try await processRows
        let apps = aggregateApps(rows: rows)
        let topAppBytes = apps.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        snapshot.topAppBytes = topAppBytes
        snapshot.otherAppBytes = snapshot.appBytes > topAppBytes ? snapshot.appBytes - topAppBytes : 0
        let load = loadSampler.sample()
        let telemetry = telemetrySampler.sample(at: load.timestamp)
        lastDetailedSampleAt = load.timestamp
        return SystemSample(snapshot: snapshot, apps: apps, load: load, telemetry: telemetry)
    }

    /// 不枚举进程、不采集 CPU/SMC；后台菜单栏仅需系统内存摘要。
    func sampleSummary() throws -> MemorySnapshot { try readMemorySnapshot() }

    private func readMemorySnapshot() throws -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SamplerError.systemMemoryUnavailable
        }

        var rawPageSize = vm_size_t(0)
        host_page_size(mach_host_self(), &rawPageSize)
        let pageSize = UInt64(rawPageSize)
        var snapshot = Self.memorySnapshot(
            stats: stats, pageSize: pageSize,
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            swap: readSwapUsage(), pressure: readPressure()
        )
        let disk = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        snapshot.startupDiskAvailableBytes = disk?.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
        return snapshot
    }

    static func memorySnapshot(stats: vm_statistics64, pageSize: UInt64, totalBytes: UInt64,
                               swap: xsw_usage?, pressure: MemoryPressure) -> MemorySnapshot {
        // internal/external 是匿名页/文件后备页；active/inactive 不是应用/缓存分类。
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = min(internalPages, UInt64(stats.purgeable_count))
        let app = (internalPages - purgeable) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        var snapshot = MemorySnapshot(
            totalBytes: totalBytes, usedBytes: min(totalBytes, app + wired + compressed),
            freeBytes: UInt64(stats.free_count) * pageSize,
            appBytes: app, topAppBytes: 0, otherAppBytes: 0,
            wiredBytes: wired, compressedBytes: compressed,
            swapUsedBytes: swap.map { UInt64($0.xsu_used) } ?? 0,
            pressure: pressure, timestamp: Date()
        )
        snapshot.cachedBytes = (UInt64(stats.external_page_count) + purgeable) * pageSize
        snapshot.swapTotalBytes = swap.map { UInt64($0.xsu_total) }
        snapshot.swapInBytes = UInt64(stats.swapins) * pageSize
        snapshot.swapOutBytes = UInt64(stats.swapouts) * pageSize
        return snapshot
    }

    private func readPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        return Self.pressure(level: level)
    }

    static func pressure(level: Int32) -> MemoryPressure {
        switch level {
        case 1: .normal
        case 2: .medium
        case 4: .high
        default: .unknown
        }
    }

    private func readSwapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let status = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard status == 0 else {
            return nil
        }
        return usage
    }

    private func readProcesses() async throws -> [ProcessDetail] {
        let result = try ProcessRunner.run(executable: "/bin/ps", arguments: ["-axo", "pid=,ppid=,rss=,comm="], timeout: 3)
        guard result.status == 0, let output = String(data: result.stdout, encoding: .utf8) else {
            throw SamplerError.processesUnavailable
        }
        let rows = output.split(separator: "\n").compactMap { line in
            parseProcessLine(line, compressedByPID: [:])
        }
        let livePIDs = Set(rows.map(\.pid))
        cpuCounters = cpuCounters.filter { livePIDs.contains($0.key) }
        return rows
    }

    private func parseProcessLine(_ line: Substring, compressedByPID: [Int32: UInt64]) -> ProcessDetail? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let fields = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard fields.count >= 4,
              let pid = Int32(fields[0]),
              let parentPid = Int32(fields[1]),
              let rssKB = UInt64(fields[2]) else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE 的 C 表达式未导入 Swift；SDK 定义为 4 * MAXPATHLEN。
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let rawCommandPath = pathLength > 0 ? String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : String(fields[3])
        let metadata = shouldUseAppMetadata(for: rawCommandPath) ? appMetadata(for: pid) : (name: nil, command: nil)
        let command = metadata.command ?? rawCommandPath
        let name = metadata.name ?? URL(fileURLWithPath: command).lastPathComponent
        var usage = rusage_info_v0()
        let readable = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) == 0
            }
        }
        // ps 枚举后已退出的短命进程不应把整个应用误标成权限受限的 RSS。
        if !readable && errno == ESRCH { return nil }
        var cpuPercent: Double?
        if readable {
            let counter = ProcessCPUCounter(started: usage.ri_proc_start_abstime,
                                            machTicks: usage.ri_user_time + usage.ri_system_time,
                                            wallTicks: mach_absolute_time())
            cpuPercent = counter.percent(since: cpuCounters[pid], cores: ProcessInfo.processInfo.activeProcessorCount)
            cpuCounters[pid] = counter
        } else { cpuCounters.removeValue(forKey: pid) }
        return ProcessDetail(
            pid: pid,
            parentPid: parentPid,
            name: name,
            memoryBytes: rssKB * 1024,
            compressedBytes: compressedByPID[pid] ?? 0,
            command: command,
            arguments: nil,
            currentDirectory: nil,
            parentChain: [],
            footprintBytes: readable ? usage.ri_phys_footprint : nil,
            service: NodeAttribution.isNode(command) ? NodeAttribution.readService(pid: pid) : nil,
            cpuPercent: cpuPercent,
            startTimeTicks: readable ? usage.ri_proc_start_abstime : nil,
            cpuTimeTicks: readable ? usage.ri_user_time + usage.ri_system_time : nil
        )
    }

    private func appMetadata(for pid: Int32) -> (name: String?, command: String?) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return (nil, nil)
        }

        let executablePath = app.executableURL?.path
        let appName = app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? app.executableURL?.deletingPathExtension().lastPathComponent

        return (appName, executablePath)
    }

    private func shouldUseAppMetadata(for command: String) -> Bool {
        command.contains(".app/") || command.contains("M-") || command.contains("<M")
    }

    func aggregateApps(rows: [ProcessDetail]) -> [AppMemoryUsage] {
        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        var owners: [Int32: String] = [:]
        let attributed = rows.map { row -> ProcessDetail in
            var row = row
            guard NodeAttribution.isNode(row.command), appGroupName(for: row) == row.command else { return row }
            var parentPID = row.parentPid
            var visited: Set<Int32> = [row.pid]
            while parentPID > 1, let parent = byPID[parentPID], visited.insert(parentPID).inserted {
                row.parentChain.append("\(parent.name) (PID \(parent.pid))")
                let key = appGroupName(for: parent)
                if key.hasSuffix(".app") { owners[row.pid] = key; break }
                parentPID = parent.parentPid
            }
            if owners[row.pid] == nil, let service = row.service { owners[row.pid] = service.identity }
            return row
        }
        let grouped = Dictionary(grouping: attributed) { owners[$0.pid] ?? appGroupName(for: $0) }
        return grouped.compactMap { key, processes in
            let pids = Set(processes.map(\.pid))
            // 归入应用的外部服务不能取代主应用，否则图标、历史和正常退出目标会变成 node。
            let direct = processes.filter { appGroupName(for: $0) == key }
            let candidates = direct.isEmpty ? processes : direct
            let roots = candidates.filter { !pids.contains($0.parentPid) }
            guard let primary = (roots.isEmpty ? candidates : roots).min(by: { $0.pid < $1.pid }) else { return nil }
            let name: String
            if key.hasSuffix(".app") { name = URL(fileURLWithPath: key).deletingPathExtension().lastPathComponent }
            else if let service = primary.service { name = "\(service.name) · Node" }
            else { name = NodeAttribution.isNode(primary.command) ? "node · 来源未确认" : primary.name }
            let usesFootprint = processes.allSatisfy { $0.footprintBytes != nil }
            let total = processes.reduce(UInt64(0)) { $0 + (usesFootprint ? ($1.footprintBytes ?? 0) : $1.memoryBytes) }
            let compressedTotal = processes.reduce(UInt64(0)) { $0 + $1.compressedBytes }
            return AppMemoryUsage(
                pid: primary.pid,
                name: name,
                command: primary.command,
                memoryBytes: total,
                compressedBytes: compressedTotal,
                processCount: processes.count,
                status: status(for: total),
                processes: processes.sorted { ($0.footprintBytes ?? $0.memoryBytes) > ($1.footprintBytes ?? $1.memoryBytes) },
                usesFootprint: usesFootprint,
                groupKey: key
            )
        }
        .sorted { $0.memoryBytes > $1.memoryBytes }
    }

    private func appGroupName(for process: ProcessDetail) -> String {
        if let appRange = process.command.range(of: ".app/") {
            return String(process.command[..<appRange.upperBound].dropLast())
        }
        return process.command
    }

    private func readCompressedByPIDThrottled() -> [Int32: UInt64] {
        compressedCacheLock.lock()
        let cached = compressedCache
        let shouldRefresh = Date().timeIntervalSince(lastCompressedSampleAt) >= compressedSampleInterval || cached.isEmpty
        compressedCacheLock.unlock()

        guard shouldRefresh else {
            return cached
        }

        let fresh = readCompressedByPID()
        compressedCacheLock.lock()
        if !fresh.isEmpty {
            compressedCache = fresh
        }
        lastCompressedSampleAt = Date()
        let result = compressedCache
        compressedCacheLock.unlock()
        return result
    }

    private func readCompressedByPID() -> [Int32: UInt64] {
        guard let result = try? ProcessRunner.run(
            executable: "/usr/bin/top",
            arguments: ["-l", "1", "-n", "120", "-o", "cmprs", "-stats", "pid,cmprs"],
            timeout: 4
        ), let output = String(data: result.stdout, encoding: .utf8) else {
            return [:]
        }

        var values: [Int32: UInt64] = [:]
        var hasSeenHeader = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("PID") {
                hasSeenHeader = true
                continue
            }
            guard hasSeenHeader else { continue }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]) else { continue }
            values[pid] = parseTopMemoryToken(String(fields[1]))
        }
        return values
    }

    private func parseTopMemoryToken(_ token: String) -> UInt64 {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let unit = trimmed.last else { return 0 }
        let numberPart = trimmed.dropLast()
        guard let value = Double(numberPart) else {
            return UInt64(Double(trimmed) ?? 0)
        }
        switch unit {
        case "G": return UInt64(value * 1_073_741_824)
        case "M": return UInt64(value * 1_048_576)
        case "K": return UInt64(value * 1024)
        case "B": return UInt64(value)
        default: return UInt64(Double(trimmed) ?? 0)
        }
    }

    private func status(for bytes: UInt64) -> AppMemoryStatus {
        if bytes >= 10 * 1_073_741_824 { return .critical }
        if bytes >= 6 * 1_073_741_824 { return .high }
        if bytes >= 3 * 1_073_741_824 { return .watch }
        return .normal
    }
}

enum SamplerError: LocalizedError {
    case systemMemoryUnavailable
    case processesUnavailable

    var errorDescription: String? {
        switch self {
        case .systemMemoryUnavailable: "无法读取系统内存状态"
        case .processesUnavailable: "无法读取进程列表"
        }
    }
}
