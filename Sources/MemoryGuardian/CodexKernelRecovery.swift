import Foundation

struct CodexKernelAssessment: Identifiable {
    let owner: ProcessDetail
    let host: ProcessDetail
    let trusted: ProcessDetail
    let kernel: ProcessDetail
    let applicationKey: String
    let workingDirectory: String
    let kernelScript: String
    let quietSeconds: TimeInterval
    let observedAt: Date
    let hasChildren: Bool

    var id: CodexProcessIdentity { .init(pid: trusted.pid, started: trusted.startTimeTicks ?? 0) }
    var members: [ProcessDetail] { [trusted, kernel] }
    var canReset: Bool {
        quietSeconds >= 60 && !hasChildren && members.allSatisfy { $0.startTimeTicks != nil && $0.cpuTimeTicks != nil }
    }
    var stateText: String {
        if hasChildren { return "有子任务 · 暂不重置" }
        if members.contains(where: { $0.cpuTimeTicks == nil }) { return "活动数据不足" }
        return canReset ? "疑似闲置 · 可手动重置" : "观察中 · 至少 60 秒"
    }
    func bytes(usesFootprint: Bool) -> UInt64 {
        members.reduce(0) { $0 + (usesFootprint ? $1.footprintBytes ?? 0 : $1.memoryBytes) }
    }
}

/// 只配对同一 REPL 宿主、同一脚本目录中的两个执行进程。
struct CodexKernelTracker {
    private var previous: [CodexProcessIdentity: CodexKernelAssessment] = [:]

    mutating func update(processes: [ProcessDetail], tools: [CodexToolAssessment], at now: Date,
                         arguments: (Int32) -> [String]? = { NodeAttribution.readArguments(pid: $0) }) -> [CodexKernelAssessment] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let parents = Set(processes.map(\.parentPid))
        var next: [CodexProcessIdentity: CodexKernelAssessment] = [:]
        for tool in tools {
            let trusted = tool.process
            guard let key = tool.applicationKey, let ownerID = tool.owner,
                  let owner = byPID[ownerID.pid], owner.startTimeTicks == ownerID.started, CodexToolKind.isOwner(owner),
                  CodexToolKind.resourcePath(trusted.command) == "cua_node/bin/node",
                  let entry = trusted.service?.entryPoint, URL(fileURLWithPath: entry).lastPathComponent == "trusted-worker.js",
                  let host = byPID[trusted.parentPid], CodexToolKind.identify(host) == .repl,
                  let hostStart = host.startTimeTicks, let trustedStart = trusted.startTimeTicks else { continue }
            let id = CodexProcessIdentity(pid: trusted.pid, started: trustedStart)
            let old = previous[id]
            let script = URL(fileURLWithPath: entry).deletingLastPathComponent().appendingPathComponent("kernel.js").path
            var pair: (ProcessDetail, String)?
            if let old, old.host.startTimeTicks == hostStart, old.host.pid == host.pid,
               let kernel = byPID[old.kernel.pid], kernel.startTimeTicks == old.kernel.startTimeTicks,
               kernel.parentPid == host.pid {
                pair = (kernel, old.workingDirectory)
            } else {
                for sibling in processes where sibling.parentPid == host.pid && sibling.command == trusted.command && sibling.pid != trusted.pid {
                    guard let args = arguments(sibling.pid), args.contains(script),
                          let index = args.firstIndex(of: "--working-dir"), index + 1 < args.count,
                          args[index + 1].hasPrefix("/"), sibling.startTimeTicks != nil else { continue }
                    pair = (sibling, args[index + 1]); break
                }
            }
            guard let (kernel, directory) = pair else { continue }
            let unchanged = old.map {
                $0.host.pid == host.pid && $0.host.startTimeTicks == hostStart && $0.kernel.pid == kernel.pid &&
                $0.kernel.startTimeTicks == kernel.startTimeTicks && trusted.cpuTimeTicks != nil && kernel.cpuTimeTicks != nil &&
                trusted.cpuTimeTicks == $0.trusted.cpuTimeTicks && kernel.cpuTimeTicks == $0.kernel.cpuTimeTicks && now >= $0.observedAt
            } ?? false
            // 同身份累计 CPU 完全不变可以跨暂停期观察；不推断未记录的工具调用状态。
            let quiet = unchanged ? old!.quietSeconds + now.timeIntervalSince(old!.observedAt) : 0
            next[id] = CodexKernelAssessment(owner: owner, host: host, trusted: trusted, kernel: kernel, applicationKey: key,
                workingDirectory: directory, kernelScript: script, quietSeconds: quiet, observedAt: now,
                hasChildren: parents.contains(trusted.pid) || parents.contains(kernel.pid))
        }
        previous = next
        return next.values.sorted {
            $0.members.reduce(UInt64(0)) { $0 + ($1.footprintBytes ?? $1.memoryBytes) } >
            $1.members.reduce(UInt64(0)) { $0 + ($1.footprintBytes ?? $1.memoryBytes) }
        }
    }
}

protocol CodexKernelSystem: CodexToolSystem {
    func arguments(_ pid: Int32) -> [String]?
}

extension NativeCodexToolSystem: CodexKernelSystem {
    func arguments(_ pid: Int32) -> [String]? { NodeAttribution.readArguments(pid: pid) }
}

/// 此操作必须由用户明确确认会清空临时状态；CPU 安静不是无在途调用的证明。
struct CodexKernelResetter {
    func reset(_ candidates: [CodexKernelAssessment], system: any CodexKernelSystem = NativeCodexToolSystem(),
               at now: Date = Date()) -> [CodexCleanupOutcome] {
        var results: [CodexCleanupOutcome] = []
        for item in candidates {
            let pid = item.trusted.pid
            guard item.canReset, now.timeIntervalSince(item.observedAt) >= 0, now.timeIntervalSince(item.observedAt) <= 10,
                  let owner = system.inspect(item.owner.pid), owner.userID == system.userID,
                  owner.process.startTimeTicks == item.owner.startTimeTicks, CodexToolKind.isOwner(owner.process),
                  let host = system.inspect(item.host.pid), host.userID == system.userID,
                  host.process.startTimeTicks == item.host.startTimeTicks, host.process.command == item.host.command,
                  host.process.parentPid == item.host.parentPid,
                  CodexToolKind.identify(host.process) == .repl,
                  item.members.allSatisfy({ row in
                      guard let current = system.inspect(row.pid) else { return false }
                      return current.userID == system.userID && current.process.startTimeTicks == row.startTimeTicks &&
                          current.process.command == row.command && current.process.parentPid == row.parentPid &&
                          current.process.cpuTimeTicks == row.cpuTimeTicks && system.hasChildren(row.pid) == false
                  }),
                  system.inspect(pid)?.process.service?.entryPoint == item.trusted.service?.entryPoint,
                  let args = system.arguments(item.kernel.pid), args.contains(item.kernelScript),
                  let index = args.firstIndex(of: "--working-dir"), index + 1 < args.count,
                  args[index + 1] == item.workingDirectory else {
                results.append(.init(pid: pid, status: .skipped, detail: "内核身份、活动或子任务发生变化，已跳过")); continue
            }
            var errors: [Int32] = []
            for row in item.members {
                // 第一只进程退出后宿主可能自行收起配对进程；不对复用的 PID 发送信号。
                guard let current = system.inspect(row.pid), current.process.startTimeTicks == row.startTimeTicks else { continue }
                if let error = system.requestExit(row.pid) { errors.append(error) }
            }
            results.append(.init(pid: pid, status: errors.isEmpty ? .requested : .failed,
                                 detail: errors.isEmpty ? "已请求重置，等待内核退出" : "部分退出请求失败：\(errors)"))
        }
        if results.contains(where: { $0.status == .requested }) { Thread.sleep(forTimeInterval: 0.3) }
        return results.map { result in
            guard result.status == .requested, let item = candidates.first(where: { $0.trusted.pid == result.pid }) else { return result }
            let exited = item.members.allSatisfy { row in
                !system.isAlive(row.pid) || system.inspect(row.pid).map { $0.process.startTimeTicks != row.startTimeTicks } == true
            }
            guard let host = system.inspect(item.host.pid), host.process.startTimeTicks == item.host.startTimeTicks else {
                return .init(pid: result.pid, status: .failed, detail: "无法确认工具宿主仍在，请在 Codex 中刷新工具连接")
            }
            return .init(pid: result.pid, status: exited ? .exited : .requested,
                         detail: exited ? "执行内核已退出，工具宿主保留；下次调用将重新初始化" : "部分执行内核仍在运行")
        }
    }
}
