import Foundation
import Observation
import AppKit

enum SamplingMode: Equatable {
    case detailed, summary, sleeping

    static func resolve(isActive: Bool, hasVisibleWindow: Bool, isSleeping: Bool) -> Self {
        if isSleeping { return .sleeping }
        return isActive && hasVisibleWindow ? .detailed : .summary
    }

    func interval(pressure: MemoryPressure) -> Duration? {
        switch self {
        case .detailed: pressure == .high ? .seconds(3) : .seconds(5)
        case .summary: .seconds(30)
        case .sleeping: nil
        }
    }
}

/// 后台只发布菜单栏摘要，不让主面板跟着失效、重新布局。
@MainActor
final class MenuBarStatus: ObservableObject {
    @Published var snapshot: MemorySnapshot = .empty
    @Published var lastError: String?
    var icon: String {
        guard lastError == nil else { return "questionmark.circle" }
        return switch snapshot.pressure {
        case .unknown: "questionmark.circle"
        case .normal: "memorychip"
        case .medium: "memorychip.fill"
        case .high: "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot = .empty
    @Published private(set) var apps: [AppMemoryUsage] = []
    @Published private(set) var lastActionMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isWorking = false
    @Published private(set) var inspectedProcesses: [ProcessDetail] = []
    @Published var isInspectingProcesses = false
    @Published var selectedAppID: Int32? {
        didSet {
            guard oldValue != selectedAppID else { return }
            inspectedProcesses = selectedApp?.processes ?? []
            isInspectingProcesses = false
        }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var history: [MemoryHistoryPoint] = []
    @Published private(set) var load = MachineLoadSnapshot()
    @Published private(set) var loadHistory: [LoadHistoryPoint] = []
    @Published private(set) var telemetry = MachineHardwareTelemetry()
    @Published private(set) var overviewHistory: [MachineOverviewHistoryPoint] = []
    @Published private(set) var quitObservation: QuitObservation?
    @Published private(set) var samplingMode: SamplingMode = .summary
    @Published private(set) var codexTools: [CodexToolAssessment] = []
    @Published private(set) var codexCleanupOutcomes: [CodexCleanupOutcome] = []
    @Published private(set) var codexKernels: [CodexKernelAssessment] = []
    @Published private(set) var codexKernelResetOutcomes: [CodexCleanupOutcome] = []
    let menuBarStatus = MenuBarStatus()

    private let sampler = SystemSampler()
    private var codexToolTracker = CodexToolTracker()
    private var codexKernelTracker = CodexKernelTracker()
    private var started = false
    private var refreshInFlight = false
    private var samplingTask: Task<Void, Never>?
    private var isSleeping = false
    private var samplingObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {}

    var selectedApp: AppMemoryUsage? {
        apps.first { $0.pid == selectedAppID } ?? apps.first
    }

    var selectedProcesses: [ProcessDetail] {
        inspectedProcesses.isEmpty ? (selectedApp?.processes ?? []) : inspectedProcesses
    }

    var samplingDescription: String {
        samplingMode == .detailed ? (snapshot.pressure == .high ? "每 3 秒采样" : "每 5 秒采样") : "后台节能 · 每 30 秒仅更新系统摘要"
    }

    /// 由 App 持有一个循环；关窗后不再依赖窗口的 task 生命周期。
    func start() {
        guard !started else { return }
        started = true
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            observeSampling(name, center: .default)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observeSampling(NSWorkspace.willSleepNotification, center: workspace, sleeping: true)
        observeSampling(NSWorkspace.didWakeNotification, center: workspace, sleeping: false)
        updateSamplingMode()
    }

    func stop() {
        started = false
        samplingTask?.cancel()
        samplingTask = nil
        samplingObservers.forEach { $0.0.removeObserver($0.1) }
        samplingObservers.removeAll()
    }

    private func observeSampling(_ name: Notification.Name, center: NotificationCenter, sleeping: Bool? = nil) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // willClose/miniaturize 通知发出时窗口属性可能尚未完成变化，下一轮主线程读取实际状态。
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                if let sleeping { self.isSleeping = sleeping }
                self.updateSamplingMode()
            }
        }
        samplingObservers.append((center, token))
    }

    private func updateSamplingMode() {
        let visible = NSApp?.windows.contains { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        let mode = SamplingMode.resolve(isActive: NSApp?.isActive ?? false, hasVisibleWindow: visible, isSleeping: isSleeping)
        guard mode != samplingMode || samplingTask == nil else { return }
        samplingMode = mode
        samplingTask?.cancel()
        samplingTask = nil
        guard mode != .sleeping else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.refreshAutomatically(), !Task.isCancelled else { return }
                do { try await Task.sleep(for: interval, tolerance: .seconds(1)) }
                catch { return }
            }
        }
    }

    private func refreshAutomatically() async -> Duration? {
        switch samplingMode {
        case .detailed: await refresh(showActivity: false)
        case .summary: await refreshSummary()
        case .sleeping: break
        }
        return samplingMode.interval(pressure: snapshot.pressure)
    }

    private func refreshSummary() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        do {
            let sampler = sampler
            var current = try await Task.detached(priority: .utility) { try sampler.sampleSummary() }.value
            current.updateSwapRates(from: menuBarStatus.snapshot.totalBytes > 0 ? menuBarStatus.snapshot : nil)
            menuBarStatus.snapshot = current
            menuBarStatus.lastError = nil
        } catch { menuBarStatus.lastError = error.localizedDescription }
    }

    func refresh(showActivity: Bool = true) async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        if showActivity { isRefreshing = true }
        defer {
            refreshInFlight = false
            if showActivity { isRefreshing = false }
        }
        do {
            let sampler = sampler
            let sample = try await Task.detached(priority: .utility) {
                try await sampler.sample()
            }.value
            var current = sample.snapshot
            let recent = snapshot.totalBytes > 0 && current.timestamp.timeIntervalSince(snapshot.timestamp) <= 10
            current.updateSwapRates(from: recent ? snapshot : nil)
            menuBarStatus.snapshot = current
            menuBarStatus.lastError = nil
            // 切入后台时可能尚有一次已开始的采样；不让其重绘已收起的面板。
            guard showActivity || samplingMode == .detailed else { return }
            snapshot = current
            let selectedKey = selectedApp?.historyKey
            apps = sample.apps
            codexTools = codexToolTracker.update(processes: apps.flatMap(\.processes), at: current.timestamp)
            codexKernels = codexKernelTracker.update(processes: apps.flatMap(\.processes), tools: codexTools, at: current.timestamp)
            load = sample.load
            telemetry = sample.telemetry
            let memUsedPercent: Double? = current.totalBytes > 0 ? Double(current.usedBytes) / Double(current.totalBytes) * 100 : nil
            overviewHistory.append(MachineOverviewHistoryPoint(
                timestamp: load.timestamp,
                cpuPercent: load.cpuPercent,
                gpuPercent: sample.telemetry.gpu.utilizationPercent,
                memoryUsedPercent: memUsedPercent,
                networkDownloadBps: sample.telemetry.network.downloadBytesPerSecond,
                networkUploadBps: sample.telemetry.network.uploadBytesPerSecond
            ))
            overviewHistory.removeAll { $0.timestamp < load.timestamp.addingTimeInterval(-300) }
            loadHistory.append(LoadHistoryPoint(timestamp: load.timestamp, cpuPercent: load.cpuPercent,
                appCPU: Dictionary(uniqueKeysWithValues: apps.compactMap { app in
                    // 部分可读组不连成完整用量趋势，避免权限变化制造虚假下降。
                    guard !app.cpuIsPartial, let value = app.cpuPercent else { return nil }
                    return (app.cpuHistoryKey, value)
                })))
            loadHistory.removeAll { $0.timestamp < load.timestamp.addingTimeInterval(-300) }
            history.append(MemoryHistoryPoint(timestamp: current.timestamp, appBytes: Dictionary(uniqueKeysWithValues: apps.map { ($0.historyKey, $0.memoryBytes) })))
            history.removeAll { $0.timestamp < current.timestamp.addingTimeInterval(-300) }
            if !apps.contains(where: { $0.pid == selectedAppID }) {
                selectedAppID = sample.apps.first(where: { $0.historyKey == selectedKey })?.pid ?? sample.apps.first?.pid
            } else {
                inspectedProcesses = selectedApp?.processes ?? []
            }
            lastError = nil
        } catch {
            menuBarStatus.lastError = error.localizedDescription
            if showActivity || samplingMode == .detailed { lastError = error.localizedDescription }
        }
    }

    func runningApplication(for app: AppMemoryUsage) -> NSRunningApplication? {
        guard let url = app.applicationURL else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
    }

    func requestQuitSelectedApp() {
        guard let app = selectedApp, let running = runningApplication(for: app) else { return }
        if running.terminate() {
            quitObservation = QuitObservation(key: app.historyKey, name: app.name, beforeBytes: app.memoryBytes)
            lastActionMessage = "已请求 \(app.name) 正常退出；如有保存提示，请先保存工作。"
            lastError = nil
        } else {
            quitObservation = nil
            lastActionMessage = "\(app.name) 未接受退出请求，请在应用中保存工作后退出。"
        }
    }

    func cleanCodexTools(_ selection: Set<CodexProcessIdentity>) async {
        guard !isWorking else { return }
        let candidates = codexTools.filter { selection.contains($0.id) }
        isWorking = true
        defer { isWorking = false }
        codexCleanupOutcomes = await Task.detached(priority: .userInitiated) {
            CodexToolCleaner().clean(candidates)
        }.value
        await refresh()
    }

    func resetCodexKernels(_ selection: Set<CodexProcessIdentity>) async {
        guard !isWorking else { return }
        let candidates = codexKernels.filter { selection.contains($0.id) }
        isWorking = true
        defer { isWorking = false }
        codexKernelResetOutcomes = await Task.detached(priority: .userInitiated) {
            CodexKernelResetter().reset(candidates)
        }.value
        await refresh()
    }

}
