import Testing
import Foundation
import Darwin
@testable import MemoryGuardian

struct CodexKernelRecoveryTests {
    let root = "/Applications/ChatGPT.app/Contents/Resources/"
    let directory = "/projects/旧任务"
    let scriptDirectory = "/tmp/guardian-kernel-fixture"
    let date = Date(timeIntervalSince1970: 1000)

    func rows(kernelParent: Int32 = 11) -> [ProcessDetail] {
        let commands = [root + "codex", root + "cua_node/bin/node_repl", root + "cua_node/bin/node", root + "cua_node/bin/node"]
        return commands.enumerated().map { index, command in
            ProcessDetail(pid: Int32(index + 10), parentPid: index == 0 ? 1 : index == 1 ? 10 : index == 2 ? kernelParent : 11,
                name: "fixture", memoryBytes: 200, compressedBytes: 0, command: command, parentChain: [], footprintBytes: 100,
                service: index == 3 ? ProcessService(identity: "script:trusted", name: "trusted-worker", entryPoint: scriptDirectory + "/trusted-worker.js") : nil,
                startTimeTicks: UInt64(index + 1), cpuTimeTicks: 100)
        }
    }
    func arguments(_ pid: Int32) -> [String]? {
        pid == 12 ? ["node", "--experimental-vm-modules", scriptDirectory + "/kernel.js", "--working-dir", directory] : nil
    }
    func ready() -> CodexKernelAssessment {
        let rows = rows()
        var tools = CodexToolTracker()
        let sources = tools.update(processes: rows, at: date)
        var tracker = CodexKernelTracker()
        _ = tracker.update(processes: rows, tools: sources, at: date, arguments: arguments)
        return tracker.update(processes: rows, tools: sources, at: date.addingTimeInterval(60), arguments: arguments)[0]
    }

    @Test func connectedKernelCanBeManuallyResetWithoutCallingItAnOrphan() {
        let item = ready()
        #expect(item.canReset)
        #expect(item.host.pid == 11 && item.trusted.pid == 13 && item.kernel.pid == 12)
        #expect(item.workingDirectory == directory)
        #expect(item.bytes(usesFootprint: true) == 200)
        #expect(item.bytes(usesFootprint: false) == 400)
        var tracker = CodexToolTracker()
        let sources = tracker.update(processes: rows(), at: date)
        #expect(sources.allSatisfy { !$0.canClean })
    }

    @Test func activityUnknownDataIdentityAndChildJobsPreventReset() {
        for variant in 0..<4 {
            var rows = rows()
            var toolTracker = CodexToolTracker()
            var sources = toolTracker.update(processes: rows, at: date)
            var tracker = CodexKernelTracker()
            _ = tracker.update(processes: rows, tools: sources, at: date, arguments: arguments)
            switch variant {
            case 0: rows[2].cpuTimeTicks = 101
            case 1: rows[2].cpuTimeTicks = nil
            case 2: rows[2].startTimeTicks = 999
            default:
                rows.append(ProcessDetail(pid: 99, parentPid: 12, name: "job", memoryBytes: 1, compressedBytes: 0, command: "/bin/sleep", parentChain: []))
            }
            sources = toolTracker.update(processes: rows, at: date.addingTimeInterval(65))
            let items = tracker.update(processes: rows, tools: sources, at: date.addingTimeInterval(65), arguments: arguments)
            #expect(items.count == 1)
            #expect(!items[0].canReset)
        }
    }

    @Test func emptyHostsUnpairedWorkersAndUnknownOwnerAreNotResetCandidates() {
        var tracker = CodexKernelTracker()
        var tools = CodexToolTracker()
        let rows = rows()
        let sources = tools.update(processes: rows, at: date)
        #expect(tracker.update(processes: rows, tools: sources, at: date, arguments: { _ in nil }).isEmpty)
        #expect(tracker.update(processes: Array(rows.prefix(2)), tools: sources, at: date, arguments: arguments).isEmpty)
        var unknownTools = CodexToolTracker()
        let unknownRows = Array(rows.dropFirst())
        let unknown = unknownTools.update(processes: unknownRows, at: date)
        #expect(tracker.update(processes: unknownRows, tools: unknown, at: date, arguments: arguments).isEmpty)
        let differentHost = self.rows(kernelParent: 10)
        #expect(tracker.update(processes: differentHost, tools: sources, at: date, arguments: arguments).isEmpty)
    }

    @Test func resetRevalidatesIdentityCPUChildrenDirectoryAndSameUser() {
        let item = ready()
        for variant in 0..<7 {
            let system = KernelSystemFixture(rows: rows(), arguments: arguments(12)!)
            switch variant {
            case 0: system.rows[12]?.cpuTimeTicks = 101
            case 1: system.rows[13]?.startTimeTicks = 999
            case 2: system.rows[11]?.startTimeTicks = 999
            case 3: system.currentUID = 999
            case 4: system.children = true
            case 5: system.kernelArgs = ["node", scriptDirectory + "/kernel.js", "--working-dir", "/other"]
            default: break
            }
            let outcomes = CodexKernelResetter().reset([item], system: system, at: item.observedAt.addingTimeInterval(variant == 6 ? 11 : 0))
            #expect(outcomes[0].status == .skipped)
            #expect(system.signalled.isEmpty)
        }
    }

    @Test func resetSignalsOnlyWorkerPairAndPreservesHost() {
        let item = ready()
        let system = KernelSystemFixture(rows: rows(), arguments: arguments(12)!)
        let outcome = CodexKernelResetter().reset([item], system: system, at: item.observedAt)
        #expect(outcome[0].status == .exited)
        #expect(Set(system.signalled) == [12, 13])
        #expect(system.rows[11] != nil && system.rows[10] != nil)
    }

    @Test func ignoredExitRequestDoesNotEscalateToForceKill() {
        let item = ready()
        let system = KernelSystemFixture(rows: rows(), arguments: arguments(12)!)
        system.exits = false
        let outcome = CodexKernelResetter().reset([item], system: system, at: item.observedAt)
        #expect(outcome[0].status == .requested)
        #expect(system.signalled.count == 2)
    }
}

private final class KernelSystemFixture: CodexKernelSystem {
    let userID: UInt32 = 501
    var currentUID: UInt32 = 501
    var rows: [Int32: ProcessDetail]
    var kernelArgs: [String]
    var children: Bool? = false
    var signalled: [Int32] = []
    var exits = true
    init(rows: [ProcessDetail], arguments: [String]) { self.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) }); kernelArgs = arguments }
    func inspect(_ pid: Int32) -> CodexToolLiveProcess? { rows[pid].map { .init(process: $0, userID: currentUID) } }
    func arguments(_ pid: Int32) -> [String]? { kernelArgs }
    func hasChildren(_ pid: Int32) -> Bool? { children }
    func isAlive(_ pid: Int32) -> Bool { rows[pid] != nil }
    func requestExit(_ pid: Int32) -> Int32? { signalled.append(pid); if exits { rows.removeValue(forKey: pid) }; return nil }
}
