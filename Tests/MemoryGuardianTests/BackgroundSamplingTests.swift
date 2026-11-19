import Foundation
import Testing
import Combine
import AppKit
@testable import MemoryGuardian

@Suite(.serialized)
struct BackgroundSamplingTests {
    @Test @MainActor func backgroundSamplingDoesNotPublishDetailedDashboard() async throws {
        let monitor = MemoryMonitor()
        var detailedCount = 0
        var summaryCount = 0
        let subscriptions = [
            monitor.$snapshot.dropFirst().sink { if $0.totalBytes > 0 { detailedCount += 1 } },
            monitor.menuBarStatus.$snapshot.dropFirst().sink { if $0.totalBytes > 0 { summaryCount += 1 } }
        ]
        monitor.start()
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(600))
        #expect(monitor.samplingMode == .summary)
        #expect(monitor.menuBarStatus.snapshot.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(monitor.apps.count == 0)
        #expect(monitor.snapshot.totalBytes == 0)
        #expect(monitor.loadHistory.count == 0)
        // 重复 start 不能新建循环或立即重复摘要；正常只在 30 秒后更新。
        let timestamp = monitor.menuBarStatus.snapshot.timestamp
        monitor.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.menuBarStatus.snapshot.timestamp == timestamp)
        #expect(detailedCount == 0)
        #expect(summaryCount == 1)
        print("连续后台 0.7 秒：完整采样发布 \(detailedCount) 次，系统摘要 \(summaryCount) 次；重复 start 未新增采样。")
        withExtendedLifetime(subscriptions) {}
    }

    @Test func samplingPolicyStopsDetailedWorkOutsideVisibleForeground() {
        #expect(SamplingMode.resolve(isActive: true, hasVisibleWindow: true, isSleeping: false) == .detailed)
        #expect(SamplingMode.resolve(isActive: false, hasVisibleWindow: true, isSleeping: false) == .summary)
        #expect(SamplingMode.resolve(isActive: true, hasVisibleWindow: false, isSleeping: false) == .summary)
        #expect(SamplingMode.resolve(isActive: true, hasVisibleWindow: true, isSleeping: true) == .sleeping)
        #expect(SamplingMode.detailed.interval(pressure: .normal) == .seconds(5))
        #expect(SamplingMode.detailed.interval(pressure: .high) == .seconds(3))
        #expect(SamplingMode.summary.interval(pressure: .high) == .seconds(30))
        #expect(SamplingMode.sleeping.interval(pressure: .normal) == nil)
    }

    @Test @MainActor func sleepNotificationStopsAndWakeRestartsOnlySummaryWithoutAWindow() async throws {
        let monitor = MemoryMonitor()
        monitor.start()
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(100))
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.samplingMode == .sleeping)
        let sleepingTimestamp = monitor.menuBarStatus.snapshot.timestamp
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.menuBarStatus.snapshot.timestamp == sleepingTimestamp)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(monitor.samplingMode == .summary)
        #expect(monitor.menuBarStatus.snapshot.timestamp > sleepingTimestamp)
        #expect(monitor.apps.count == 0)
    }

    @Test @MainActor func manualRefreshStillWorksAndDoesNotOverlap() async {
        let monitor = MemoryMonitor()
        async let first: Void = monitor.refresh()
        async let duplicate: Void = monitor.refresh()
        _ = await (first, duplicate)
        #expect(monitor.apps.count > 0)
        #expect(monitor.history.count == 1)
        #expect(monitor.loadHistory.count == 1)
        #expect(!monitor.isRefreshing)
    }

    @Test @MainActor func summaryUpdatesDoNotInvalidateDashboardObservation() {
        let monitor = MemoryMonitor()
        var dashboardChanges = 0
        let subscription = monitor.objectWillChange.sink { dashboardChanges += 1 }
        monitor.menuBarStatus.snapshot = MemorySnapshot.empty
        monitor.menuBarStatus.lastError = "摘要读取失败"
        #expect(dashboardChanges == 0)
        #expect(monitor.menuBarStatus.icon == "questionmark.circle")
        withExtendedLifetime(subscription) {}
    }

    @Test func fanLimitsKeepUnknownAndStoppedValuesDistinct() {
        #expect(ReadOnlySMC.validRPM(nil, maximum: true) == nil)
        #expect(ReadOnlySMC.validRPM(0, maximum: true) == nil)
        #expect(ReadOnlySMC.validRPM(.nan, maximum: true) == nil)
        #expect(ReadOnlySMC.validRPM(30_000, maximum: true) == nil)
        #expect(ReadOnlySMC.validRPM(-1) == nil)
        #expect(ReadOnlySMC.validRPM(0) == 0)
        #expect(ReadOnlySMC.validRPM(7826, maximum: true) == 7826)
        #expect(FanReading(id: 0, rpm: 3913, maximumRPM: 7826).speedFraction == 0.5)
        #expect(FanReading(id: 0, rpm: 0, maximumRPM: 7826).speedFraction == 0)
        #expect(FanReading(id: 0, rpm: 1000).speedFraction == nil)
        #expect(FanReading(id: 0, rpm: nil, maximumRPM: 7826).speedFraction == nil)
    }

    @Test func longSamplingPauseRequiresNewCPUDifferences() async throws {
        let sampler = SystemSampler()
        _ = try await sampler.sample()
        try await Task.sleep(for: .seconds(1))
        let active = try await sampler.sample()
        #expect(active.load.cpuPercent != nil)
        try await Task.sleep(for: .seconds(11))
        let resumed = try await sampler.sample()
        #expect(resumed.load.cpuPercent == nil)
        #expect(!resumed.load.cores.isEmpty)
        #expect(resumed.load.cores.allSatisfy { $0.percent == nil })
        #expect(resumed.apps.flatMap(\.processes).compactMap(\.cpuPercent).count == 0)
    }
}
