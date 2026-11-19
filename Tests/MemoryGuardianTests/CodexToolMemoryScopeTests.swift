import Testing
import Foundation
@testable import MemoryGuardian

struct CodexToolMemoryScopeTests {
    let root = "/Applications/ChatGPT.app"
    let date = Date(timeIntervalSince1970: 1000)

    func row(_ pid: Int32, parent: Int32, command: String, footprint: UInt64) -> ProcessDetail {
        ProcessDetail(pid: pid, parentPid: parent, name: URL(fileURLWithPath: command).lastPathComponent,
            memoryBytes: footprint * 2, compressedBytes: 0, command: command, parentChain: [], footprintBytes: footprint,
            startTimeTicks: UInt64(pid), cpuTimeTicks: 100)
    }

    func rows(root: String = "/Applications/ChatGPT.app", offset: Int32 = 0) -> [ProcessDetail] {
        [
            row(1000 + offset, parent: 1, command: root + "/Contents/MacOS/ChatGPT", footprint: 100),
            row(1001 + offset, parent: 1000 + offset, command: root + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", footprint: 50),
            row(1002 + offset, parent: 1001 + offset, command: root + "/Contents/Resources/cua_node/bin/node_repl", footprint: 100),
            row(1003 + offset, parent: 1001 + offset, command: root + "/Contents/Resources/cua_node/bin/node", footprint: 20),
            row(1004 + offset, parent: 1000 + offset, command: root + "/Contents/Frameworks/Codex Framework.framework/Codex (Renderer)", footprint: 300)
        ]
    }

    @Test func applicationTotalPartitionsIntoToolsAndRemainingProcesses() throws {
        let rows = rows()
        var tracker = CodexToolTracker()
        let tools = tracker.update(processes: rows, at: date)
        let app = try #require(SystemSampler().aggregateApps(rows: rows).first)
        let scope = CodexToolMemoryScope(application: app, applicationKey: root, assessments: tools)
        #expect(scope.application?.memoryBytes == app.memoryBytes)
        #expect(app.memoryBytes == 570)
        #expect(scope.toolBytes == 120)
        #expect(scope.otherBytes == 450)
        #expect(scope.toolBytes + (scope.otherBytes ?? 0) == app.memoryBytes)
        #expect(scope.included.count == 2)
        #expect(scope.detached.isEmpty)
    }

    @Test func unreadableApplicationForcesToolsToUseSameRSSBasis() throws {
        var rows = rows()
        rows[0].footprintBytes = nil
        var tracker = CodexToolTracker()
        let tools = tracker.update(processes: rows, at: date)
        let app = try #require(SystemSampler().aggregateApps(rows: rows).first)
        let scope = CodexToolMemoryScope(application: app, applicationKey: root, assessments: tools)
        #expect(!scope.usesFootprint)
        #expect(scope.toolBytes == 240)
        #expect(scope.otherBytes == 900)
        #expect(scope.toolBytes + (scope.otherBytes ?? 0) == app.memoryBytes)
        #expect(scope.bytes(for: tools.first { $0.process.pid == 1002 }!) == 200)
    }

    @Test func otherApplicationToolsAreExcluded() throws {
        let rows = rows() + rows(root: "/Applications/Codex.app", offset: 2000)
        var tracker = CodexToolTracker()
        let tools = tracker.update(processes: rows, at: date)
        let app = try #require(SystemSampler().aggregateApps(rows: rows).first { $0.name == "ChatGPT" })
        let scope = CodexToolMemoryScope(application: app, applicationKey: root, assessments: tools)
        #expect(tools.count == 4)
        #expect(scope.tools.count == 2)
        #expect(scope.tools.allSatisfy { $0.applicationKey == root })
        #expect(scope.toolBytes == 120)
    }

    @Test func stalePIDIdentityDoesNotEnterApplicationSubtotalOrBecomeDetached() throws {
        var rows = rows()
        var tracker = CodexToolTracker()
        let tools = tracker.update(processes: rows, at: date)
        rows[2].startTimeTicks = 9999
        let app = try #require(SystemSampler().aggregateApps(rows: rows).first)
        let scope = CodexToolMemoryScope(application: app, applicationKey: root, assessments: tools)
        #expect(scope.toolBytes == 20)
        #expect(scope.included.count == 1)
        #expect(scope.detached.isEmpty)
        #expect(scope.toolBytes + (scope.otherBytes ?? 0) == app.memoryBytes)
    }

    @Test func externalOrphanKeepsOriginalApplicationButIsCountedSeparately() throws {
        let base = Array(rows().prefix(2))
        var external = row(2000, parent: 1001, command: "/opt/homebrew/bin/node", footprint: 40)
        external.service = ProcessService(identity: "script:app-tools", name: "codex-app-tools", entryPoint: "/cache/codex-app-tools/1/server.mjs")
        var tracker = CodexToolTracker()
        _ = tracker.update(processes: base + [external], at: date)
        let orphan = ProcessDetail(pid: external.pid, parentPid: 1, name: external.name, memoryBytes: external.memoryBytes,
            compressedBytes: 0, command: external.command, parentChain: [], footprintBytes: external.footprintBytes,
            service: external.service, startTimeTicks: external.startTimeTicks, cpuTimeTicks: external.cpuTimeTicks)
        let live = [base[0], orphan]
        let tools = tracker.update(processes: live, at: date.addingTimeInterval(5))
        let app = try #require(SystemSampler().aggregateApps(rows: live).first { $0.name == "ChatGPT" })
        let scope = CodexToolMemoryScope(application: app, applicationKey: root, assessments: tools)
        #expect(scope.application?.memoryBytes == 100)
        #expect(scope.toolBytes == 0)
        #expect(scope.otherBytes == 100)
        #expect(scope.detached.count == 1)
        #expect(scope.detachedBytes == 40)
        #expect(scope.detached[0].applicationKey == root)
        let gone = CodexToolMemoryScope(application: nil, applicationKey: root, assessments: tools)
        #expect(gone.application == nil)
        #expect(gone.otherBytes == nil)
        #expect(gone.toolBytes == 0)
        #expect(gone.detachedBytes == 40)
    }

    @Test func applicationEntryIsLimitedToSupportedDesktopApplications() throws {
        let app = try #require(SystemSampler().aggregateApps(rows: rows()).first)
        #expect(CodexToolMemoryScope.supports(app))
        #expect(CodexToolMemoryScope.key(for: app) == root)
        let chrome = try #require(SystemSampler().aggregateApps(rows: rows(root: "/Applications/Google Chrome.app")).first)
        #expect(!CodexToolMemoryScope.supports(chrome))
    }
}
