import Foundation
import Testing
@testable import MemoryGuardian

struct MachineOverviewTests {
    @Test func byteRateTrackerComputesRatesAndRejectsInvalidDeltas() {
        var tracker = ByteRateTracker(maxGapSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 1000)

        // 首次采样无基线返回 nil
        #expect(tracker.update(rxBytes: 1000, txBytes: 500, at: t0) == nil)

        // 2 秒后正常增长
        let r1 = tracker.update(rxBytes: 3048, txBytes: 1524, at: t0.addingTimeInterval(2))
        #expect(r1?.rxPerSecond == 1024)
        #expect(r1?.txPerSecond == 512)

        // 超过 10 秒长暂停，重置基线并返回 nil
        #expect(tracker.update(rxBytes: 100_000, txBytes: 50_000, at: t0.addingTimeInterval(15)) == nil)

        // 计数回绕/减小，返回 nil 并更新基线
        #expect(tracker.update(rxBytes: 100, txBytes: 50_000, at: t0.addingTimeInterval(18)) == nil)
        let r2 = tracker.update(rxBytes: 600, txBytes: 50_500, at: t0.addingTimeInterval(20))
        #expect(r2?.rxPerSecond == 250)
        #expect(r2?.txPerSecond == 250)
    }

    @Test func telemetryFormattingMatchesExpectedUnits() {
        #expect(TelemetryFormat.uptime(nil) == "运行时间未知")
        #expect(TelemetryFormat.uptime(5 * 86400 + 3600 + 120) == "已运行 5天 1小时")
        #expect(TelemetryFormat.uptime(3 * 3600 + 25 * 60) == "已运行 3小时 25分钟")
        #expect(TelemetryFormat.uptime(45) == "已运行 1分钟")

        #expect(TelemetryFormat.rate(0) == ("0", "KB/s"))
        #expect(TelemetryFormat.rate(500) == ("<1", "KB/s"))
        #expect(TelemetryFormat.rate(10 * 1024) == ("10", "KB/s"))
        #expect(TelemetryFormat.rate(5.5 * 1024 * 1024) == ("5.5", "MB/s"))
        #expect(TelemetryFormat.rate(nil) == ("—", ""))

        #expect(TelemetryFormat.decimalGigabytes(995_000_000_000) == "995 GB")
        #expect(TelemetryFormat.decimalGigabytesParts(410_000_000_000) == ("410", "GB"))
        #expect(TelemetryFormat.binaryGigabytesTwoDecimals(37_108_517_437).hasPrefix("34.56 GiB"))
    }

    @Test func healthEvaluationReflectsRealPressuresAndStaleState() {
        let now = Date()
        var memory = MemorySnapshot.empty
        memory.totalBytes = 48 * 1_073_741_824
        memory.usedBytes = 32 * 1_073_741_824
        memory.pressure = .normal

        let load = MachineLoadSnapshot(timestamp: now, cpuUser: 10, cpuSystem: 4, thermalState: .nominal)
        let telemetry = MachineHardwareTelemetry(
            timestamp: now,
            chipName: "Apple M5 Pro",
            uptimeSeconds: 5 * 86400,
            loadAverage1m: 2.1,
            storage: StorageTelemetrySnapshot(totalBytes: 1_000_000_000_000, availableBytes: 400_000_000_000)
        )
        let assessment = LoadAssessment.evaluate(load: load, memory: memory, apps: [], history: [], stale: false)

        let healthy = MachineHealthEvaluation.evaluate(load: load, memory: memory, telemetry: telemetry, assessment: assessment, stale: false)
        #expect(healthy.score == 100)
        #expect(healthy.grade == .excellent)
        #expect(healthy.factors.isEmpty)

        // 样本过期返回未知
        let staleEval = MachineHealthEvaluation.evaluate(load: load, memory: memory, telemetry: telemetry, assessment: assessment, stale: true)
        #expect(staleEval.score == nil)
        #expect(staleEval.grade == .unknown)

        // 内存压力高与严重散热会降低评分并给出明确原因
        var pressuredMemory = memory
        pressuredMemory.pressure = .high
        var hotLoad = load
        hotLoad.thermalState = .serious
        let strained = MachineHealthEvaluation.evaluate(load: hotLoad, memory: pressuredMemory, telemetry: telemetry, assessment: assessment, stale: false)
        #expect((strained.score ?? 100) <= 50)
        #expect(strained.factors.contains { $0.id == "mem-pressure" })
        #expect(strained.factors.contains { $0.id == "thermal" })
    }

    @Test func liveTelemetrySamplerReadsRealHostMetrics() async throws {
        let sampler = SystemSampler()
        let first = try await sampler.sample()
        #expect(!first.telemetry.chipName.isEmpty)
        #expect((first.telemetry.uptimeSeconds ?? 0) > 0)
        #expect(first.telemetry.loadAverage1m != nil)
        #expect((first.telemetry.storage.totalBytes ?? 0) > 0)
        // 首次差分应为 nil
        #expect(first.telemetry.storage.readBytesPerSecond == nil)
        #expect(first.telemetry.network.downloadBytesPerSecond == nil)

        try await Task.sleep(for: .seconds(1))
        let second = try await sampler.sample()
        // 第二次应产出非负真实速率
        #expect(second.telemetry.storage.readBytesPerSecond != nil)
        #expect((second.telemetry.storage.readBytesPerSecond ?? -1) >= 0)
        #expect((second.telemetry.storage.writeBytesPerSecond ?? -1) >= 0)
        print("实采遥测：芯片=\(second.telemetry.chipBadge) 运行=\(TelemetryFormat.uptime(second.telemetry.uptimeSeconds)) GPU=\(second.telemetry.gpu.utilizationPercent.map { "\(Int($0))%" } ?? "—") 电池=\(second.telemetry.battery?.percent.map { "\($0)%" } ?? "无电池") 可用盘=\(TelemetryFormat.decimalGigabytes(second.telemetry.storage.availableBytes)) 读=\(TelemetryFormat.rateInline(second.telemetry.storage.readBytesPerSecond)) 写=\(TelemetryFormat.rateInline(second.telemetry.storage.writeBytesPerSecond)) 网络=\(second.telemetry.network.interfaceKind.label) ↓\(TelemetryFormat.rateInline(second.telemetry.network.downloadBytesPerSecond)) ↑\(TelemetryFormat.rateInline(second.telemetry.network.uploadBytesPerSecond))")
    }
}
