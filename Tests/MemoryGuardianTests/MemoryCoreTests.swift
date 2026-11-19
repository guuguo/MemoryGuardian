import Testing
import Foundation
import Darwin
import AppKit
@testable import MemoryGuardian

struct MemoryCoreTests {
    let page: UInt64 = 16_384

    @Test func cachedPagesAreNotApplicationMemory() {
        var stats = vm_statistics64()
        stats.internal_page_count = 600
        stats.purgeable_count = 20
        stats.external_page_count = 200
        stats.wire_count = 100
        stats.compressor_page_count = 50
        stats.free_count = 50
        let sample = SystemSampler.memorySnapshot(stats: stats, pageSize: page, totalBytes: 1000 * page, swap: nil, pressure: .normal)
        #expect(sample.appBytes == 580 * page)
        #expect(sample.cachedBytes == 220 * page)
        #expect(sample.usedBytes == 730 * page)
        #expect(sample.freeBytes == 50 * page)
        #expect(sample.unclassifiedBytes == 0)
        #expect(sample.pressure == .normal)
        #expect(sample.swapTotalBytes == nil)
    }

    @Test func pressureUsesSystemLevelsAndUnknownDoesNotBecomeNormal() {
        #expect(SystemSampler.pressure(level: 1) == .normal)
        #expect(SystemSampler.pressure(level: 2) == .medium)
        #expect(SystemSampler.pressure(level: 4) == .high)
        #expect(SystemSampler.pressure(level: 0) == .unknown)
        #expect(SystemSampler.pressure(level: 99) == .unknown)
        #expect(MemorySnapshot.empty.pressure == .unknown)
    }

    @Test func swapCapacityZeroAllocatedAndFailureRemainDistinct() {
        let stats = vm_statistics64()
        var swap = xsw_usage()
        var sample = SystemSampler.memorySnapshot(stats: stats, pageSize: page, totalBytes: 48 << 30, swap: swap, pressure: .normal)
        #expect(sample.totalBytes == 48 << 30)
        #expect(sample.swapTotalBytes == 0)
        swap.xsu_total = 4 << 30
        swap.xsu_used = 2 << 30
        sample = SystemSampler.memorySnapshot(stats: stats, pageSize: page, totalBytes: 48 << 30, swap: swap, pressure: .normal)
        #expect(sample.swapUsedBytes == 2 << 30)
        #expect(sample.swapTotalBytes == 4 << 30)
        #expect(sample.totalBytes == 48 << 30)
        let failed = SystemSampler.memorySnapshot(stats: stats, pageSize: page, totalBytes: 48 << 30, swap: nil, pressure: .normal)
        #expect(failed.swapTotalBytes == nil)
    }

    @Test func swapRatesNeedTwoRealSamplesAndMonotonicCounters() {
        var previous = MemorySnapshot.empty
        previous.timestamp = Date(timeIntervalSince1970: 100)
        previous.swapInBytes = 1024
        var current = previous
        current.timestamp = Date(timeIntervalSince1970: 105)
        current.swapInBytes = 11_264
        current.swapOutBytes = 5120
        current.updateSwapRates(from: nil)
        #expect(current.swapInBytesPerSecond == nil)
        current.updateSwapRates(from: previous)
        #expect(current.swapInBytesPerSecond == 2048)
        #expect(current.swapOutBytesPerSecond == 1024)
        var reset = MemorySnapshot.empty
        reset.timestamp = current.timestamp.addingTimeInterval(5)
        reset.updateSwapRates(from: current)
        #expect(reset.swapInBytesPerSecond == nil)
    }

    @Test func aggregationIncludesSmallChildrenAndMoreThanTwelveGroups() {
        let root = process(100, parent: 1, command: "/Applications/测试.app/Contents/MacOS/App", rss: 12, footprint: 9)
        let child = process(101, parent: 100, command: "/Applications/测试.app/Contents/Helpers/Child.app/Contents/MacOS/Child", rss: 2, footprint: 1)
        let services = (200..<216).map { process(Int32($0), parent: 1, command: "/tools/service\($0)", rss: 1, footprint: 1) }
        let apps = SystemSampler().aggregateApps(rows: [root, child] + services)
        #expect(apps.count == 17)
        let app = apps.first { $0.name == "测试" }!
        #expect(app.processCount == 2)
        #expect(app.memoryBytes == 10 * 1_048_576)
        #expect(app.pid == 100)
        #expect(app.applicationURL?.path == "/Applications/测试.app")
        #expect(app.usesFootprint)
    }

    @Test func restrictedGroupUsesWholeGroupRSSWithoutMixingMetrics() {
        let first = process(300, parent: 1, command: "/tools/node", rss: 10, footprint: 1)
        let restricted = process(301, parent: 1, command: "/tools/node", rss: 20, footprint: nil)
        let app = SystemSampler().aggregateApps(rows: [first, restricted]).first!
        #expect(!app.usesFootprint)
        #expect(app.memoryBytes == 30 * 1_048_576)
        #expect(app.applicationURL == nil)
        let otherPath = process(302, parent: 1, command: "/other/node", rss: 1, footprint: 1)
        #expect(SystemSampler().aggregateApps(rows: [first, otherPath]).count == 2)
        let footprintApp = SystemSampler().aggregateApps(rows: [first]).first!
        #expect(footprintApp.historyKey != app.historyKey)
    }

    @Test func unclassifiedPhysicalPagesAreExplicitRatherThanApplicationMemory() {
        var sample = MemorySnapshot.empty
        sample.totalBytes = 100
        sample.appBytes = 30
        sample.wiredBytes = 10
        sample.compressedBytes = 10
        sample.cachedBytes = 20
        sample.freeBytes = 10
        #expect(sample.unclassifiedBytes == 20)
        #expect(sample.appBytes == 30)
    }

    @Test func liveSamplingReadsRealCapacityAndFullList() async throws {
        let sample = try await SystemSampler().sample()
        #expect(sample.snapshot.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(sample.snapshot.usedBytes <= sample.snapshot.totalBytes)
        #expect(sample.snapshot.timestamp.timeIntervalSinceNow > -10)
        #expect(sample.apps.count > 12)
        #expect(sample.apps.contains { $0.processes.contains { $0.pid == getpid() && $0.footprintBytes != nil } })
        print("实采：RAM=\(sample.snapshot.totalBytes.binaryBytesText) 已用=\(sample.snapshot.usedBytes.binaryBytesText) 缓存=\(sample.snapshot.cachedBytes.binaryBytesText) 未归类=\(sample.snapshot.unclassifiedBytes.binaryBytesText) 压力=\(sample.snapshot.pressure.rawValue) Swap总量=\(sample.snapshot.swapTotalBytes?.binaryBytesText ?? "未知") 应用组=\(sample.apps.count)")
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMORY_GUARDIAN_QUIT_FIXTURE"] != nil))
    func nativeQuitRequestsOnlyTheSelectedTestApplication() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MEMORY_GUARDIAN_QUIT_FIXTURE"])
        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let running = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        defer { if !running.isTerminated { running.forceTerminate() } }
        let monitor = MemoryMonitor()
        #expect(monitor.history.isEmpty)
        await monitor.refresh()
        #expect(monitor.history.count == 1)
        let target = try #require(monitor.apps.first { $0.applicationURL?.path == url.path })
        monitor.selectedAppID = target.pid
        #expect(monitor.runningApplication(for: target)?.processIdentifier == running.processIdentifier)
        monitor.requestQuitSelectedApp()
        for _ in 0..<30 where !running.isTerminated {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(running.isTerminated)
        #expect(monitor.quitObservation?.key == target.historyKey)
        await monitor.refresh()
        #expect(!monitor.apps.contains { $0.historyKey == target.historyKey })
    }

    private func process(_ pid: Int32, parent: Int32, command: String, rss: UInt64, footprint: UInt64?) -> ProcessDetail {
        ProcessDetail(pid: pid, parentPid: parent, name: URL(fileURLWithPath: command).lastPathComponent,
                      memoryBytes: rss * 1_048_576, compressedBytes: 0, command: command, parentChain: [],
                      footprintBytes: footprint.map { $0 * 1_048_576 })
    }
}
