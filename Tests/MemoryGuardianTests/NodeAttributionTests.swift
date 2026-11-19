import Testing
import Foundation
@testable import MemoryGuardian

struct NodeAttributionTests {
    let node = "/runtime/node"

    @Test func multiLevelParentsFoldIntoApplicationWithoutChangingPrimaryOrDoubleCounting() {
        let app = row(2000, 1, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", bytes: 100)
        let launcher = row(2001, 2000, "/Applications/ChatGPT.app/Contents/Resources/codex", bytes: 50)
        let npm = row(100, 2001, node, bytes: 10, service: package("wigolo"))
        let shell = row(101, 100, "/bin/sh", bytes: 2)
        let worker = row(10, 101, node, bytes: 30, service: package("wigolo"))
        let input = [app, launcher, npm, shell, worker]
        let groups = SystemSampler().aggregateApps(rows: input)
        let owner = groups.first { $0.name == "ChatGPT" }!
        #expect(owner.pid == app.pid)
        #expect(owner.command == app.command)
        #expect(owner.applicationURL?.path == "/Applications/ChatGPT.app")
        #expect(owner.memoryBytes == 190)
        #expect(owner.processCount == 4)
        #expect(owner.processes.first { $0.pid == 10 }?.parentChain.count == 3)
        #expect(groups.reduce(UInt64(0)) { $0 + $1.memoryBytes } == 192)
        let pids = groups.flatMap { $0.processes.map(\.pid) }
        #expect(pids.count == input.count)
        #expect(Set(pids).count == input.count)
        #expect(groups.first { $0.command == "/bin/sh" }?.processCount == 1)
    }

    @Test func packagePathAndNonNodeProcessesKeepTheirOriginalGroups() {
        let appB = row(100, 1, "/Applications/B.app/Contents/MacOS/B", bytes: 50)
        let bundled = row(101, 100, "/Applications/A.app/Contents/Resources/node", bytes: 10)
        let other = row(102, 100, "/tools/custom-worker", bytes: 5)
        let groups = SystemSampler().aggregateApps(rows: [appB, bundled, other])
        #expect(groups.count == 3)
        #expect(groups.first { $0.name == "A" }?.memoryBytes == 10)
        #expect(groups.first { $0.name == "B" }?.memoryBytes == 50)
        #expect(groups.first { $0.command == other.command }?.memoryBytes == 5)
    }

    @Test func independentScriptsGetDistinctGroupsAndHistoryKeys() {
        let first = NodeAttribution.service(arguments: [node, "/projects/first/src/server.mjs"])!
        let second = NodeAttribution.service(arguments: [node, "/projects/second/src/server.mjs"])!
        let groups = SystemSampler().aggregateApps(rows: [row(10, 1, node, bytes: 10, service: first), row(11, 1, node, bytes: 20, service: second)])
        #expect(Set(groups.map(\.name)) == ["first · Node", "second · Node"])
        #expect(Set(groups.map(\.historyKey)).count == 2)
        #expect(groups.allSatisfy { $0.applicationURL == nil })
        #expect(groups.reduce(UInt64(0)) { $0 + $1.memoryBytes } == 30)
    }

    @Test func missingParentsAndCyclesDoNotInventApplicationOwnership() {
        let unknown = row(10, 999, node, bytes: 5)
        let cycle = row(20, 21, node, bytes: 10)
        let parent = row(21, 20, "/bin/sh", bytes: 2)
        let unrelated = row(100, 1, "/Applications/Other.app/Contents/MacOS/Other", bytes: 50)
        let groups = SystemSampler().aggregateApps(rows: [unknown, cycle, parent, unrelated])
        let nodeGroup = groups.first { $0.name == "node · 来源未确认" }!
        #expect(nodeGroup.processCount == 2)
        #expect(nodeGroup.applicationURL == nil)
        #expect(nodeGroup.processes.first { $0.pid == 20 }?.parentChain.count == 1)
        #expect(groups.first { $0.name == "Other" }?.memoryBytes == 50)
    }

    @Test func scriptLocationDoesNotOverrideActualParentAndRestrictedGroupStaysRSS() {
        let service = NodeAttribution.service(arguments: [node, "/Applications/Dependency.app/Contents/Resources/server.js"])!
        var app = row(100, 1, "/Applications/Owner.app/Contents/MacOS/Owner", bytes: 50)
        app.footprintBytes = nil
        let child = row(101, 100, node, bytes: 10, service: service)
        let owner = SystemSampler().aggregateApps(rows: [app, child]).first!
        #expect(owner.name == "Owner")
        #expect(owner.pid == 100)
        #expect(!owner.usesFootprint)
        #expect(owner.memoryBytes == app.memoryBytes + child.memoryBytes)
    }

    @Test func nativeArgvParserPreservesSpacesAndEmptyArgumentsButExcludesEnvironment() {
        let expected = [node, "/Volumes/Workspace SSD/项目/src/server.mjs", "", "--flag", "value"]
        var argc = Int32(expected.count)
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data((node + "\0\0\0" + expected.joined(separator: "\0") + "\0SECRET=not-an-argument\0").utf8))
        #expect(NodeAttribution.arguments(from: data) == expected)
        #expect(NodeAttribution.arguments(from: Data([0, 1])) == [])
    }

    @Test func absoluteAndRelativeEntryPathsAreResolvedWithoutSplittingSpaces() {
        let absolute = NodeAttribution.service(arguments: [node, "/Volumes/Workspace SSD/工作台/src/server.mjs"])!
        #expect(absolute.name == "工作台")
        #expect(absolute.entryPoint == "/Volumes/Workspace SSD/工作台/src/server.mjs")
        #expect(NodeAttribution.service(arguments: [node, "scripts/server.mjs"]) == nil)
        let relative = NodeAttribution.service(arguments: [node, "scripts/server.mjs"], currentDirectory: "/projects/项目 一")!
        #expect(relative.name == "项目 一")
        #expect(relative.entryPoint == "/projects/项目 一/scripts/server.mjs")
        #expect(relative.identity != absolute.identity)
        #expect(NodeAttribution.service(arguments: [node, "-e", "console.log('server.js')"]) == nil)
    }

    @Test func rewrittenNpmTitlesAndScopedPackageEntriesShareServiceIdentity() {
        let npm = NodeAttribution.service(arguments: ["npm exec @agentmemory/mcp@1.2.3", "", ""])!
        let child = NodeAttribution.service(arguments: [node, "/cache/node_modules/@agentmemory/mcp/dist/cli.mjs"])!
        #expect(npm.identity == child.identity)
        #expect(npm.name == "@agentmemory/mcp")
        #expect(NodeAttribution.service(arguments: ["npm exec shadcn@latest mcp"])?.name == "shadcn")
    }

    @Test func npmBinSymlinkUsesPackageNameInsteadOfCommandAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guardian-bin-\(UUID())")
        let bin = root.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = bin.appendingPathComponent("agentmemory-mcp")
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "../@agentmemory/mcp/dist/cli.mjs")
        let service = try #require(NodeAttribution.service(arguments: [node, path.path]))
        #expect(service.identity == "package:@agentmemory/mcp")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMORY_GUARDIAN_NODE_FIXTURE"] != nil))
    func realNodeUsesNativeArgvAndCwdForRelativeScript() throws {
        let executable = try #require(ProcessInfo.processInfo.environment["MEMORY_GUARDIAN_NODE_FIXTURE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guardian Node 测试-\(UUID())")
        let script = root.appendingPathComponent("scripts/server.mjs")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "setInterval(() => {}, 1000);".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = root
        process.arguments = ["scripts/server.mjs"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let service = try #require(NodeAttribution.readService(pid: process.processIdentifier))
        #expect(service.entryPoint == script.resolvingSymlinksInPath().path)
        #expect(service.name == root.lastPathComponent)
    }

    private func package(_ name: String) -> ProcessService {
        ProcessService(identity: "package:\(name)", name: name, entryPoint: nil)
    }

    private func row(_ pid: Int32, _ parent: Int32, _ command: String, bytes: UInt64, service: ProcessService? = nil) -> ProcessDetail {
        ProcessDetail(pid: pid, parentPid: parent, name: URL(fileURLWithPath: command).lastPathComponent,
                      memoryBytes: bytes * 2, compressedBytes: 0, command: command, parentChain: [],
                      footprintBytes: bytes, service: service)
    }
}
