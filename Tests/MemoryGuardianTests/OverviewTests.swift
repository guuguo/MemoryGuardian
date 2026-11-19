import Foundation
import Darwin
import Testing
@testable import MemoryGuardian

struct OverviewTests {
    @Test func equalTotalCanHaveDifferentCoreDistributions() {
        let before = Array(repeating: CPUTicks(user: 100, system: 100, idle: 800, nice: 0), count: 15)
        let concentrated = [100, 92, 68, 10, 6, 5, 4, 4, 3, 2, 2, 1, 1, 1, 1]
        func usage(_ percentages: [Int]) -> (user: Double?, system: Double?, cores: [CoreCPUReading]) {
            LoadSampler.cpuUsage(ticks: percentages.map {
                CPUTicks(user: UInt32(100 + $0), system: 100, idle: UInt32(900 - $0), nice: 0)
            }, previous: before)
        }
        let spike = usage(concentrated), uniform = usage(Array(repeating: 20, count: 15))
        #expect(spike.user == 20)
        #expect(uniform.user == 20)
        #expect(spike.system == 0)
        #expect(spike.cores.map(\.percent) == concentrated.map { Double($0) })
        #expect(uniform.cores.allSatisfy { $0.percent == 20 })
        #expect(spike.cores.map(\.id) == Array(0..<15))
    }

    @Test func coreTotalsUseTickWeightsAndSurviveCounterWrap() {
        let zero = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let weighted = LoadSampler.cpuUsage(ticks: [CPUTicks(user: 10, system: 0, idle: 0, nice: 0),
                                                    CPUTicks(user: 0, system: 0, idle: 90, nice: 0)], previous: [zero, zero])
        #expect(weighted.cores.map(\.percent) == [100, 0])
        #expect(weighted.user == 10)
        let old = CPUTicks(user: UInt32.max - 4, system: 10, idle: 20, nice: 1)
        let new = CPUTicks(user: 5, system: 20, idle: 100, nice: 1)
        let wrap = LoadSampler.cpuUsage(ticks: [new, new], previous: [old, old])
        #expect(wrap.user == 10)
        #expect(wrap.system == 10)
        #expect(wrap.cores.allSatisfy { $0.percent == 20 })
        // 聚合计数先发生溢出、而单核尚未回绕时，总差分仍正确。
        let summedBefore = CPUTicks(user: UInt32.max / 2, system: 0, idle: 100, nice: 0)
        let summedAfter = CPUTicks(user: UInt32.max / 2 + 10, system: 0, idle: 190, nice: 0)
        #expect(LoadSampler.cpuUsage(ticks: [summedAfter, summedAfter], previous: [summedBefore, summedBefore]).user == 10)
    }

    @Test func firstUnchangedAndTopologyChangeWaitForAdjacentSamples() {
        let tick = CPUTicks(user: 1, system: 2, idle: 3, nice: 0)
        for value in [LoadSampler.cpuUsage(ticks: [tick], previous: nil),
                      LoadSampler.cpuUsage(ticks: [tick], previous: [tick]),
                      LoadSampler.cpuUsage(ticks: [tick, tick], previous: [tick]),
                      LoadSampler.cpuUsage(ticks: [], previous: [])] {
            #expect(value.user == nil)
            #expect(value.system == nil)
            #expect(value.cores.allSatisfy { $0.percent == nil })
        }
    }

    @Test func physicalMemoryPartsExcludeSwapAndHandleUnavailableComposition() {
        var snapshot = MemorySnapshot.empty
        snapshot.totalBytes = 48
        snapshot.appBytes = 19; snapshot.wiredBytes = 6; snapshot.compressedBytes = 12
        snapshot.cachedBytes = 9; snapshot.freeBytes = 1; snapshot.usedBytes = 37
        let first = PhysicalMemoryComposition(snapshot)
        #expect(first.isComplete)
        #expect(first.parts.map(\.bytes) == [19, 6, 12, 9, 1, 1])
        #expect(first.range(at: 0).start == 0)
        #expect(first.range(at: 5).end == 1)
        snapshot.swapUsedBytes = 8; snapshot.swapTotalBytes = 10
        #expect(PhysicalMemoryComposition(snapshot).parts.map(\.bytes) == first.parts.map(\.bytes))
        snapshot.appBytes = 60
        #expect(!PhysicalMemoryComposition(snapshot).isComplete)
        #expect(!PhysicalMemoryComposition(.empty).isComplete)
        #expect(PhysicalMemoryComposition(.empty).fraction(0) == 0)
    }

    @Test func liveCoresAgreeWithIndependentHostAggregate() async throws {
        func hostTicks() throws -> CPUTicks {
            var info = host_cpu_load_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            #expect(result == KERN_SUCCESS)
            return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        }
        let sampler = LoadSampler()
        // 首次 SMC 读取较慢；先预热传感器，让两组 CPU 计数窗口对齐。
        _ = sampler.sample()
        sampler.resetCPUBaseline()
        let oracleBefore = try hostTicks()
        let before = sampler.sample()
        #expect(before.cores.count == ProcessInfo.processInfo.activeProcessorCount)
        #expect(before.cores.allSatisfy { $0.percent == nil })
        try await Task.sleep(for: .seconds(1))
        let current = sampler.sample()
        let oracle = try #require(try hostTicks().utilization(since: oracleBefore))
        let actual = try #require(current.cpuPercent)
        #expect(current.cores.count == before.cores.count)
        #expect(current.cores.allSatisfy { $0.percent.map { (0...100).contains($0) } == true })
        #expect(abs(actual - oracle.user - oracle.system) < 3)
        print("逐核交叉核对：\(current.cores.count) 核，逐核汇总=\(actual)% 独立HOST=\(oracle.user + oracle.system)%，各核=\(current.cores)")
        sampler.resetCPUBaseline()
        #expect(sampler.sample().cores.allSatisfy { $0.percent == nil })
    }
}
