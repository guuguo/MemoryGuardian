import Foundation
import Darwin

struct CodexProcessIdentity: Hashable {
    let pid: Int32
    let started: UInt64
}

enum CodexToolKind: String {
    case repl = "REPL 宿主"
    case browser = "浏览器工具"
    case appTools = "Codex 应用工具"
    case worker = "工具执行进程"

    static func resourcePath(_ path: String) -> String? {
        let parts = path.components(separatedBy: ".app/Contents/Resources/")
        guard parts.count == 2, ["ChatGPT", "Codex"].contains(URL(fileURLWithPath: parts[0]).lastPathComponent) else { return nil }
        return parts[1]
    }

    static func isOwner(_ process: ProcessDetail) -> Bool {
        guard let resource = resourcePath(process.command) else { return false }
        return ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex"].contains(resource)
    }

    static func identify(_ process: ProcessDetail) -> Self? {
        let resource = resourcePath(process.command)
        if resource == "cua_node/bin/node_repl" { return .repl }
        if NodeAttribution.isNode(process.command), let entry = process.service?.entryPoint,
           entry.contains("/codex-app-tools/"), entry.hasSuffix("/server.mjs") { return .appTools }
        if resource == "cua_node/bin/node" {
            if process.service?.name == "@oai/cua-repl",
               process.service?.entryPoint?.contains("/node_modules/@oai/cua-repl/") == true { return .browser }
            return .worker
        }
        return nil
    }
}

struct CodexToolAssessment: Identifiable {
    let process: ProcessDetail
    let kind: CodexToolKind
    let owner: CodexProcessIdentity?
    let applicationKey: String?
    let quietSeconds: TimeInterval
    let observedAt: Date
    /// nil 只表示通过本工具的保守候选检查，发送信号前仍需读取内核复核。
    let protectionReason: String?

    var id: CodexProcessIdentity { .init(pid: process.pid, started: process.startTimeTicks ?? 0) }
    var canClean: Bool { protectionReason == nil }
    var stateText: String { canClean ? "可清理残留" : protectionReason! }
}

/// 仅消费现有详细采样。观察中断重置计时，身份或进程消失即丢弃相应记录。
struct CodexToolTracker {
    static let quietInterval: TimeInterval = 60
    private struct Observation {
        var owner: CodexProcessIdentity?
        let applicationKey: String?
        let cpu: UInt64?
        let sampledAt: Date
        let quietSince: Date
        let detachedSince: Date?
    }
    private var observations: [CodexProcessIdentity: Observation] = [:]

    mutating func update(processes: [ProcessDetail], at now: Date) -> [CodexToolAssessment] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let parents = Set(processes.map(\.parentPid))
        var next: [CodexProcessIdentity: Observation] = [:]
        var result: [CodexToolAssessment] = []
        for process in processes {
            guard let kind = CodexToolKind.identify(process) else { continue }
            let id = CodexProcessIdentity(pid: process.pid, started: process.startTimeTicks ?? 0)
            let previous = observations[id]
            var ancestor = process.parentPid
            var visited: Set<Int32> = [process.pid]
            var currentOwner: CodexProcessIdentity?
            var currentApplicationKey: String?
            while let row = byPID[ancestor], visited.insert(ancestor).inserted {
                if CodexToolKind.isOwner(row), let started = row.startTimeTicks {
                    currentOwner = .init(pid: row.pid, started: started)
                    if let range = row.command.range(of: ".app/") {
                        currentApplicationKey = String(row.command[..<range.upperBound].dropLast())
                    }
                    break
                }
                ancestor = row.parentPid
            }
            let owner = currentOwner ?? previous?.owner
            let applicationKey = currentApplicationKey ?? previous?.applicationKey
            let contiguous = previous.map { now.timeIntervalSince($0.sampledAt) > 0 && now.timeIntervalSince($0.sampledAt) <= 10 } ?? false
            let unchanged = process.cpuTimeTicks != nil && process.cpuTimeTicks == previous?.cpu
            let quietSince = contiguous && unchanged ? previous!.quietSince : now
            let quiet = max(0, now.timeIntervalSince(quietSince))
            // 原宿主 PID 仍存在（包括已复用或读不到身份）时也保留，避免以缺失元数据冒充退出。
            let ownerPresent = owner.map { byPID[$0.pid] != nil } ?? false
            let detached = owner != nil && !ownerPresent && process.parentPid == 1
            let detachedSince: Date? = detached ? (contiguous ? previous?.detachedSince ?? now : now) : nil
            let reason: String?
            if currentOwner != nil || ownerPresent { reason = "宿主仍在 · 使用状态未确认" }
            else if owner == nil { reason = "未验证原宿主 · 受保护" }
            else if process.parentPid != 1 { reason = "父进程仍在或来源不明" }
            else if kind == .worker { reason = "执行进程 · 受保护" }
            else if parents.contains(process.pid) { reason = "仍有子进程 · 受保护" }
            else if process.startTimeTicks == nil || process.cpuTimeTicks == nil { reason = "身份或活动数据不足" }
            else if quiet < Self.quietInterval || now.timeIntervalSince(detachedSince ?? now) < Self.quietInterval { reason = "残留观察中 · 至少 60 秒" }
            else { reason = nil }
            next[id] = Observation(owner: owner, applicationKey: applicationKey, cpu: process.cpuTimeTicks, sampledAt: now, quietSince: quietSince, detachedSince: detachedSince)
            result.append(CodexToolAssessment(process: process, kind: kind, owner: owner, applicationKey: applicationKey, quietSeconds: quiet, observedAt: now, protectionReason: reason))
        }
        observations = next
        return result.sorted {
            if $0.canClean != $1.canClean { return $0.canClean }
            return ($0.process.footprintBytes ?? $0.process.memoryBytes) > ($1.process.footprintBytes ?? $1.process.memoryBytes)
        }
    }
}

struct CodexToolLiveProcess {
    let process: ProcessDetail
    let userID: UInt32
}

protocol CodexToolSystem {
    var userID: UInt32 { get }
    func inspect(_ pid: Int32) -> CodexToolLiveProcess?
    func isAlive(_ pid: Int32) -> Bool
    func hasChildren(_ pid: Int32) -> Bool?
    /// nil 表示 SIGTERM 请求已接受；返回值为 errno。
    func requestExit(_ pid: Int32) -> Int32?
}

struct NativeCodexToolSystem: CodexToolSystem {
    var userID: UInt32 { getuid() }

    func inspect(_ pid: Int32) -> CodexToolLiveProcess? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        var usage = rusage_info_v0()
        let readable = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) == 0 }
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard readable, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let command = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return CodexToolLiveProcess(process: ProcessDetail(pid: pid, parentPid: Int32(bsd.pbi_ppid),
            name: URL(fileURLWithPath: command).lastPathComponent, memoryBytes: usage.ri_resident_size,
            compressedBytes: 0, command: command, parentChain: [], footprintBytes: usage.ri_phys_footprint,
            service: NodeAttribution.isNode(command) ? NodeAttribution.readService(pid: pid) : nil,
            startTimeTicks: usage.ri_proc_start_abstime, cpuTimeTicks: usage.ri_user_time + usage.ri_system_time), userID: bsd.pbi_uid)
    }

    func isAlive(_ pid: Int32) -> Bool {
        errno = 0
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    func hasChildren(_ pid: Int32) -> Bool? {
        var child: Int32 = 0
        errno = 0
        let count = proc_listchildpids(pid, &child, Int32(MemoryLayout<Int32>.size))
        guard count >= 0, count != 0 || errno == 0 else { return nil }
        return count > 0
    }

    func requestExit(_ pid: Int32) -> Int32? { kill(pid, SIGTERM) == 0 ? nil : errno }
}

struct CodexCleanupOutcome {
    enum Status: Equatable { case exited, requested, skipped, failed }
    let pid: Int32
    let status: Status
    let detail: String
}

struct CodexToolCleaner {
    func clean(_ candidates: [CodexToolAssessment], system: any CodexToolSystem = NativeCodexToolSystem(),
               at now: Date = Date()) -> [CodexCleanupOutcome] {
        var outcomes: [CodexCleanupOutcome] = []
        for candidate in candidates {
            let pid = candidate.process.pid
            guard candidate.canClean, now.timeIntervalSince(candidate.observedAt) >= 0,
                  now.timeIntervalSince(candidate.observedAt) <= 10,
                  let owner = candidate.owner, !system.isAlive(owner.pid),
                  let current = system.inspect(pid), current.userID == system.userID,
                  current.process.startTimeTicks == candidate.process.startTimeTicks,
                  current.process.command == candidate.process.command,
                  current.process.service == candidate.process.service,
                  current.process.parentPid == 1,
                  CodexToolKind.identify(current.process) == candidate.kind, candidate.kind != .worker,
                  current.process.cpuTimeTicks == candidate.process.cpuTimeTicks,
                  system.hasChildren(pid) == false else {
                outcomes.append(.init(pid: pid, status: .skipped, detail: "身份、活动或归属条件变化，已跳过"))
                continue
            }
            if let error = system.requestExit(pid) {
                outcomes.append(.init(pid: pid, status: .failed, detail: "退出请求失败（errno \(error)）"))
            } else { outcomes.append(.init(pid: pid, status: .requested, detail: "已请求退出，仍在运行")) }
        }
        if outcomes.contains(where: { $0.status == .requested }) { Thread.sleep(forTimeInterval: 0.3) }
        return outcomes.map { outcome in
            guard outcome.status == .requested,
                  let candidate = candidates.first(where: { $0.process.pid == outcome.pid }) else { return outcome }
            let current = system.inspect(outcome.pid)
            if !system.isAlive(outcome.pid) || current.map({ $0.process.startTimeTicks != candidate.process.startTimeTicks }) == true {
                return .init(pid: outcome.pid, status: .exited, detail: "已确认退出")
            }
            return outcome
        }
    }
}
