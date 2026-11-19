import Testing
import Foundation
import Darwin
@testable import MemoryGuardian

struct CodexToolCleanupTests {
    let date = Date(timeIntervalSince1970: 1000)
    let resources = "/Applications/ChatGPT.app/Contents/Resources/"

    func process(_ pid: Int32 = 20, parent: Int32 = 10, cpu: UInt64? = 100, started: UInt64? = 2,
                 command: String? = nil) -> ProcessDetail {
        ProcessDetail(pid: pid, parentPid: parent, name: "node_repl", memoryBytes: 50, compressedBytes: 0,
                      command: command ?? resources + "cua_node/bin/node_repl", parentChain: [],
                      footprintBytes: 60, startTimeTicks: started, cpuTimeTicks: cpu)
    }
    var owner: ProcessDetail { process(10, parent: 1, started: 1, command: resources + "codex-cli/CodexCLI.app/Contents/MacOS/codex") }

    func ready() -> CodexToolAssessment {
        var tracker = CodexToolTracker()
        _ = tracker.update(processes: [owner, process()], at: date)
        var rows: [CodexToolAssessment] = []
        for seconds in stride(from: 5, through: 65, by: 5) {
            rows = tracker.update(processes: [process(parent: 1)], at: date.addingTimeInterval(Double(seconds)))
        }
        return rows[0]
    }

    @Test func connectedQuietToolsStayProtectedEvenAfterManyMinutes() {
        var tracker = CodexToolTracker()
        var result: [CodexToolAssessment] = []
        for seconds in stride(from: 0, through: 600, by: 5) {
            result = tracker.update(processes: [owner, process()], at: date.addingTimeInterval(Double(seconds)))
        }
        #expect(result.count == 1)
        #expect(result[0].quietSeconds == 600)
        #expect(!result[0].canClean)
        #expect(result[0].stateText.contains("宿主仍在"))
    }

    @Test func onlyObservedOwnerExitAndContinuousQuietBecomeCandidate() {
        #expect(ready().canClean)
        var tracker = CodexToolTracker()
        var result: [CodexToolAssessment] = []
        for seconds in stride(from: 0, through: 120, by: 5) {
            result = tracker.update(processes: [process(parent: 1)], at: date.addingTimeInterval(Double(seconds)))
        }
        #expect(!result[0].canClean)
        #expect(result[0].stateText.contains("未验证原宿主"))
    }

    @Test func gapActivityPIDReuseAndUnknownCountersResetEligibility() {
        var tracker = CodexToolTracker()
        _ = tracker.update(processes: [owner, process()], at: date)
        for seconds in stride(from: 5, through: 65, by: 5) {
            _ = tracker.update(processes: [process(parent: 1)], at: date.addingTimeInterval(Double(seconds)))
        }
        let afterGap = tracker.update(processes: [process(parent: 1)], at: date.addingTimeInterval(100))[0]
        #expect(!afterGap.canClean && afterGap.quietSeconds == 0)
        let afterActivity = tracker.update(processes: [process(parent: 1, cpu: 101)], at: date.addingTimeInterval(105))[0]
        #expect(!afterActivity.canClean && afterActivity.quietSeconds == 0)
        let reused = tracker.update(processes: [process(parent: 1, started: 3)], at: date.addingTimeInterval(110))[0]
        #expect(!reused.canClean && reused.owner == nil)
        let unknown = tracker.update(processes: [process(parent: 1, cpu: nil, started: nil)], at: date.addingTimeInterval(115))[0]
        #expect(!unknown.canClean)
    }

    @Test func liveOwnerChildrenAndWorkersRemainProtected() {
        for variant in 0..<3 {
            var tracker = CodexToolTracker()
            let childCommand = variant == 2 ? resources + "cua_node/bin/node" : nil
            _ = tracker.update(processes: [owner, process(command: childCommand)], at: date)
            var rows: [CodexToolAssessment] = []
            for seconds in stride(from: 5, through: 120, by: 5) {
                var processes = [process(parent: 1, command: childCommand)]
                if variant == 0 { processes.append(owner) }
                if variant == 1 { processes.append(process(30, parent: 20, command: "/bin/sleep")) }
                rows = tracker.update(processes: processes, at: date.addingTimeInterval(Double(seconds)))
            }
            #expect(!rows[0].canClean)
        }
    }

    @Test func ordinaryNodeAndMainProcessesAreExcluded() {
        let node = process(command: "/opt/homebrew/bin/node")
        let main = process(command: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
        #expect(CodexToolKind.identify(node) == nil)
        #expect(CodexToolKind.identify(main) == nil)
        #expect(CodexToolKind.identify(owner) == nil)
        #expect(CodexToolKind.resourcePath("/Applications/Other.app/Contents/Resources/cua_node/bin/node_repl") == nil)
    }

    @Test func namedServicesTakePrecedenceOverBundledNodeWorkerFallback() {
        var row = process(command: resources + "cua_node/bin/node")
        row.service = ProcessService(identity: "script:app-tools", name: "26.1021.31345",
            entryPoint: "/cache/codex-app-tools/26.1021.31345/server.mjs")
        #expect(CodexToolKind.identify(row) == .appTools)
        row.service = ProcessService(identity: "package:@oai/cua-repl", name: "@oai/cua-repl",
            entryPoint: resources + "cua_node/lib/node_modules/@oai/cua-repl/dist/index.js")
        #expect(CodexToolKind.identify(row) == .browser)
        row.service = nil
        #expect(CodexToolKind.identify(row) == .worker)
    }

    @Test func actionRechecksEveryMutableConditionBeforeSendingSignal() {
        let candidate = ready()
        for variant in 0..<10 {
            let system = ToolSystemFixture(process: candidate.process)
            switch variant {
            case 0: system.ownerAlive = true
            case 1: system.current = process(parent: 1, started: 3)
            case 2: system.current = process(parent: 1, cpu: 101)
            case 3: system.current = process(parent: 99)
            case 4: system.currentUID = 999
            case 5: system.children = true
            case 6: system.children = nil
            case 7: system.current = nil
            case 8: system.current = process(parent: 1, command: "/bin/sleep")
            default: break
            }
            let at = candidate.observedAt.addingTimeInterval(variant == 9 ? 11 : 0)
            let result = CodexToolCleaner().clean([candidate], system: system, at: at)
            #expect(result[0].status == .skipped)
            #expect(system.requested.isEmpty)
        }
    }

    @Test func requestsAreVerifiedAndNeverEscalateToForceKill() {
        let candidate = ready()
        for status in [CodexCleanupOutcome.Status.exited, .requested, .failed] {
            let system = ToolSystemFixture(process: candidate.process)
            system.exitsOnRequest = status == .exited
            system.requestError = status == .failed ? EPERM : nil
            let result = CodexToolCleaner().clean([candidate], system: system, at: candidate.observedAt)
            #expect(system.requested == [candidate.process.pid])
            #expect(result[0].status == status)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMORY_GUARDIAN_CODEX_CLEANUP_FIXTURE"] != nil))
    func realOwnedProcessBecomesOrphanAndAcceptsGracefulExit() throws {
        let binary = try #require(ProcessInfo.processInfo.environment["MEMORY_GUARDIAN_CODEX_CLEANUP_FIXTURE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guardian-cleanup-\(UUID())/ChatGPT.app/Contents/Resources")
        let parentPath = root.appendingPathComponent("codex")
        let childPath = root.appendingPathComponent("cua_node/bin/node_repl")
        try FileManager.default.createDirectory(at: childPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: binary, toPath: parentPath.path)
        try FileManager.default.copyItem(atPath: binary, toPath: childPath.path)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let parent = Process(), input = Pipe(), output = Pipe()
        parent.executableURL = parentPath
        parent.arguments = ["--owner", childPath.path]
        parent.standardInput = input
        parent.standardOutput = output
        try parent.run()
        defer { if parent.isRunning { parent.terminate(); parent.waitUntilExit() } }
        let data = output.fileHandleForReading.availableData
        let pid = try #require(Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGTERM) } }
        let native = NativeCodexToolSystem()
        Thread.sleep(forTimeInterval: 0.1)
        var tracker = CodexToolTracker()
        let child = try #require(native.inspect(pid)?.process)
        let owner = try #require(native.inspect(parent.processIdentifier)?.process)
        let connected = tracker.update(processes: [owner, child], at: date)
        #expect(!connected[0].canClean)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        parent.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.1)
        let orphan = try #require(native.inspect(pid)?.process)
        #expect(orphan.parentPid == 1)
        #expect(native.hasChildren(pid) == false)
        var ready: [CodexToolAssessment] = []
        // 虚拟推进观察时钟；原生读取、归属与真实退出使用自建进程，业务会话不参与。
        for seconds in stride(from: 5, through: 65, by: 5) {
            ready = tracker.update(processes: [orphan], at: date.addingTimeInterval(Double(seconds)))
        }
        #expect(ready[0].canClean)
        let result = CodexToolCleaner().clean(ready, at: ready[0].observedAt)
        #expect(result[0].status == .exited)
        #expect(!native.isAlive(pid))
    }
}

private final class ToolSystemFixture: CodexToolSystem {
    let userID: UInt32 = 501
    var currentUID: UInt32 = 501
    var current: ProcessDetail?
    var children: Bool? = false
    var ownerAlive = false
    var exitsOnRequest = true
    var requestError: Int32?
    var requested: [Int32] = []

    init(process: ProcessDetail) { current = process }
    func inspect(_ pid: Int32) -> CodexToolLiveProcess? { current.map { .init(process: $0, userID: currentUID) } }
    func isAlive(_ pid: Int32) -> Bool { pid == 10 ? ownerAlive : current != nil }
    func hasChildren(_ pid: Int32) -> Bool? { children }
    func requestExit(_ pid: Int32) -> Int32? {
        requested.append(pid)
        if requestError == nil && exitsOnRequest { current = nil }
        return requestError
    }
}
