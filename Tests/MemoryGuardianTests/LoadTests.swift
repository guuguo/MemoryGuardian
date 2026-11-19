import Testing
import Foundation
import Darwin
@testable import MemoryGuardian

struct LoadTests {
    @Test func ticksNeedBaselineAndHandleWrap() {
        let before = CPUTicks(user: UInt32.max - 4, system: 10, idle: 20, nice: 1)
        let current = CPUTicks(user: 5, system: 20, idle: 100, nice: 1)
        #expect(current.utilization(since: nil) == nil)
        #expect(current.utilization(since: current) == nil)
        let value = current.utilization(since: before)!
        #expect(value.user == 10)
        #expect(value.system == 10)
    }

    @Test func processCPUUsesMachineCapacityAndRejectsReusedPIDs() {
        let before = ProcessCPUCounter(started: 1, machTicks: 1_000_000_000, wallTicks: 10_000_000_000)
        let current = ProcessCPUCounter(started: 1, machTicks: 3_000_000_000, wallTicks: 12_000_000_000)
        #expect(current.percent(since: before, cores: 10) == 10)
        #expect(current.percent(since: nil, cores: 10) == nil)
        #expect(ProcessCPUCounter(started: 2, machTicks: 3_000_000_000, wallTicks: 12_000_000_000).percent(since: before, cores: 10) == nil)
        #expect(ProcessCPUCounter(started: 1, machTicks: 0, wallTicks: 12_000_000_000).percent(since: before, cores: 10) == nil)
        #expect(current.percent(since: current, cores: 10) == nil)
    }

    @Test func groupedNodeCPUIsIncludedWithoutChangingMemory() {
        let app = row(100, parent: 1, path: "/Applications/Example.app/Contents/MacOS/Example", cpu: 10)
        var node = row(101, parent: 100, path: "/bin/node", cpu: 5)
        node.service = ProcessService(identity: "test-service", name: "test", entryPoint: "/tmp/test/index.js")
        let groups = SystemSampler().aggregateApps(rows: [app, node])
        #expect(groups.count == 1)
        #expect(groups[0].cpuPercent == 15)
        #expect(groups[0].memoryBytes == 200)
        #expect(!groups[0].cpuIsPartial)
        var restricted = node; restricted.cpuPercent = nil
        let partial = SystemSampler().aggregateApps(rows: [app, restricted])[0]
        #expect(partial.cpuPercent == 10)
        #expect(partial.cpuIsPartial)
        #expect(SystemSampler().aggregateApps(rows: [restricted])[0].cpuPercent == nil)
    }

    @Test func sensorsDistinguishZeroUnknownAndNoFans() {
        #expect(ReadOnlySMC.decode(type: "flt ", bytes: [0, 0, 0, 0]) == 0)
        #expect(ReadOnlySMC.decode(type: "fpe2", bytes: [0x1f, 0x40]) == 2000)
        #expect(ReadOnlySMC.decode(type: "sp78", bytes: [0x48, 0x80]) == 72.5)
        #expect(ReadOnlySMC.decode(type: "flt ", bytes: [0]) == nil)
        #expect(ReadOnlySMC.decode(type: "unknown", bytes: [0, 0, 0, 0]) == nil)
        #expect(ReadOnlySMC.keys(for: "Apple M6 Pro").isEmpty)
        #expect(ReadOnlySMC.keys(for: "Apple M5 Pro").contains("Tp00"))
        #expect(ReadOnlySMC.keys(for: "Apple M1 Pro").contains("Tp01"))
        #expect(SensorSnapshot(fanCount: 0).fanSummary == "此设备无风扇")
        #expect(SensorSnapshot(fans: [FanReading(id: 0, rpm: 0)], fanCount: 1).fanSummary == "风扇已停转")
        #expect(SensorSnapshot(fans: [FanReading(id: 0, rpm: nil)], fanCount: 1).fanSummary == "部分转速未读取")
        #expect(SensorSnapshot().hottest == nil)
    }

    @Test func assessmentDoesNotConfuseFullMemoryOrSpinningFansWithPressure() {
        let now = Date()
        var memory = MemorySnapshot.empty
        memory.totalBytes = 100; memory.usedBytes = 99; memory.pressure = .normal
        var load = MachineLoadSnapshot(timestamp: now, cpuUser: 10, cpuSystem: 10, thermalState: .nominal)
        load.sensors = SensorSnapshot(fans: [FanReading(id: 0, rpm: 5000)], fanCount: 1)
        let normal = LoadAssessment.evaluate(load: load, memory: memory, apps: [], history: [], stale: false)
        #expect(normal.level == .normal)
        #expect(normal.title.contains("平稳"))
        memory.pressure = .high
        #expect(LoadAssessment.evaluate(load: load, memory: memory, apps: [], history: [], stale: false).title.contains("内存紧张"))
        memory.pressure = .normal; load.thermalState = .fair
        #expect(LoadAssessment.evaluate(load: load, memory: memory, apps: [], history: [], stale: false).title.contains("散热"))
        load.thermalState = .critical
        #expect(LoadAssessment.evaluate(load: load, memory: memory, apps: [], history: [], stale: false).level == .high)
        #expect(LoadAssessment.evaluate(load: load, memory: memory, apps: [], history: [], stale: true).level == .unknown)
        load.cpuUser = nil; load.cpuSystem = nil; load.thermalState = .nominal
        #expect(LoadAssessment.evaluate(load: load, memory: memory, apps: [], history: [], stale: false).level == .unknown)
        load.cpuUser = 10; load.cpuSystem = 10; memory.pressure = .unknown
        #expect(LoadAssessment.evaluate(load: load, memory: memory, apps: [], history: [], stale: false).level == .unknown)
    }

    @Test func sustainedCPURequiresThirtySecondsOfContinuousHighSamples() {
        let now = Date()
        var memory = MemorySnapshot.empty; memory.totalBytes = 100; memory.pressure = .normal
        let load = MachineLoadSnapshot(timestamp: now, cpuUser: 80, cpuSystem: 10, thermalState: .nominal)
        let full = stride(from: -35, through: 0, by: 5).map {
            LoadHistoryPoint(timestamp: now.addingTimeInterval(Double($0)), cpuPercent: 90, appCPU: [:])
        }
        func title(_ history: [LoadHistoryPoint]) -> String {
            LoadAssessment.evaluate(load: load, memory: memory, apps: [], history: history, stale: false).title
        }
        #expect(title(full) == "CPU 持续繁忙")
        #expect(title(Array(full.suffix(3))) == "CPU 当前较忙")
        var missing = full; missing[3] = LoadHistoryPoint(timestamp: full[3].timestamp, cpuPercent: nil, appCPU: [:])
        #expect(title(missing) == "CPU 当前较忙")
        #expect(title([full[0], full[7]]) == "CPU 当前较忙")
    }

    @Test func liveLoadSamplingUsesRealCountersAndSensors() async throws {
        let sampler = SystemSampler()
        let started = Date()
        let first = try await sampler.sample()
        let firstDuration = Date().timeIntervalSince(started)
        #expect(first.load.cpuPercent == nil)
        #expect(first.apps.allSatisfy { $0.cpuPercent == nil })
        // host CPU ticks 可能在亚秒窗口内尚未刷新；生产采样间隔是 3–5 秒。
        try await Task.sleep(for: .seconds(1))
        let secondStarted = Date()
        let second = try await sampler.sample()
        print("采样耗时：首次=\(firstDuration)s 第二次=\(Date().timeIntervalSince(secondStarted))s")
        let cpu = try #require(second.load.cpuPercent)
        #expect((0...100).contains(cpu))
        #expect(second.apps.contains { $0.cpuPercent != nil })
        #expect(second.load.sensors.timestamp == first.load.sensors.timestamp)
        #expect(second.snapshot.totalBytes == ProcessInfo.processInfo.physicalMemory)
        print("实采 CPU=\(cpuText(cpu)) 热状态=\(second.load.thermalState.rawValue) 温区=\(second.load.sensors.temperatures) 风扇=\(second.load.sensors.fans) CPU可读组=\(second.apps.filter { $0.cpuPercent != nil }.count)")
    }

    @Test func liveProcessCPUAgreesWithIndependentPOSIXClock() throws {
        func read() throws -> ProcessCPUCounter {
            var usage = rusage_info_v0()
            let ok = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0) == 0 }
            }
            #expect(ok)
            return ProcessCPUCounter(started: usage.ri_proc_start_abstime, machTicks: usage.ri_user_time + usage.ri_system_time, wallTicks: mach_absolute_time())
        }
        func seconds(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        var beforePOSIX = rusage(); getrusage(RUSAGE_SELF, &beforePOSIX)
        let before = try read()
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.2 { _ = sqrt(ProcessInfo.processInfo.systemUptime) }
        let after = try read()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        var afterPOSIX = rusage(); getrusage(RUSAGE_SELF, &afterPOSIX)
        let actual = try #require(after.percent(since: before, cores: ProcessInfo.processInfo.activeProcessorCount))
        let oracle = (seconds(afterPOSIX) - seconds(beforePOSIX)) / elapsed / Double(ProcessInfo.processInfo.activeProcessorCount) * 100
        #expect(actual > 0)
        #expect(abs(actual - oracle) < max(0.5, oracle * 0.1))
        print("CPU 时钟交叉验证：Mach=\(cpuText(actual)) POSIX=\(cpuText(oracle))")
    }

    private func row(_ pid: Int32, parent: Int32, path: String, cpu: Double?) -> ProcessDetail {
        ProcessDetail(pid: pid, parentPid: parent, name: "example", memoryBytes: 100, compressedBytes: 0,
                      command: path, parentChain: [], footprintBytes: 100, cpuPercent: cpu)
    }
}
