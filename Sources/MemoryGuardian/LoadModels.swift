import Foundation

struct CPUTicks: Equatable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func utilization(since previous: CPUTicks?) -> (user: Double, system: Double)? {
        guard let previous else { return nil }
        let u = Double(user &- previous.user) + Double(nice &- previous.nice)
        let s = Double(system &- previous.system)
        let total = u + s + Double(idle &- previous.idle)
        guard total > 0 else { return nil }
        return (100 * u / total, 100 * s / total)
    }
}

struct CoreCPUReading: Equatable, Identifiable {
    let id: Int
    let percent: Double?
}

struct ProcessCPUCounter {
    let started: UInt64
    let machTicks: UInt64
    let wallTicks: UInt64

    func percent(since previous: ProcessCPUCounter?, cores: Int) -> Double? {
        guard let previous, started == previous.started, machTicks >= previous.machTicks,
              wallTicks > previous.wallTicks, cores > 0 else { return nil }
        // rusage CPU 与 mach_absolute_time 同属 Mach ticks；直接相除消去时基，兼容 ARM 与 Intel。
        let value = Double(machTicks - previous.machTicks) / Double(wallTicks - previous.wallTicks) / Double(cores) * 100
        return min(100, max(0, value))
    }
}

enum MachineThermalState: String, Equatable {
    case nominal = "正常"
    case fair = "轻度升温"
    case serious = "散热压力较高"
    case critical = "散热正在影响性能"
    case unknown = "未知"

    init(_ value: ProcessInfo.ThermalState) {
        switch value {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

struct TemperatureReading: Equatable, Identifiable {
    let id: String
    let celsius: Double
}

struct FanReading: Equatable, Identifiable {
    let id: Int
    let rpm: Double?
    var maximumRPM: Double? = nil

    var speedFraction: Double? {
        guard let rpm, rpm.isFinite, rpm >= 0, let maximumRPM, maximumRPM.isFinite, maximumRPM > 0 else { return nil }
        return rpm / maximumRPM
    }
}

struct SensorSnapshot: Equatable {
    var timestamp: Date? = nil
    var temperatures: [TemperatureReading] = []
    var fans: [FanReading] = []
    var fanCount: Int? = nil
    var temperatureIssue: String? = "等待传感器采样"
    var fanIssue: String? = "等待传感器采样"

    var hottest: Double? { temperatures.map(\.celsius).max() }
    var coolest: Double? { temperatures.map(\.celsius).min() }
    var fanSummary: String {
        if fanCount == 0 { return "此设备无风扇" }
        guard !fans.isEmpty else { return fanIssue ?? "转速未知" }
        if fans.allSatisfy({ $0.rpm == 0 }) { return "风扇已停转" }
        if fans.contains(where: { $0.rpm == nil }) { return "部分转速未读取" }
        return "风扇正在运转"
    }
}

struct MachineLoadSnapshot: Equatable {
    var timestamp = Date()
    var cpuUser: Double? = nil
    var cpuSystem: Double? = nil
    var cores: [CoreCPUReading] = []
    var thermalState: MachineThermalState = .unknown
    var sensors = SensorSnapshot()
    var cpuPercent: Double? {
        guard let cpuUser, let cpuSystem else { return nil }
        return min(100, max(0, cpuUser + cpuSystem))
    }
}

struct LoadHistoryPoint {
    let timestamp: Date
    let cpuPercent: Double?
    let appCPU: [String: Double]
}

struct LoadAssessment {
    enum Level { case normal, watch, high, unknown }
    let title: String
    let detail: String
    let advice: String
    let level: Level

    static func evaluate(load: MachineLoadSnapshot, memory: MemorySnapshot, apps: [AppMemoryUsage],
                         history: [LoadHistoryPoint], stale: Bool) -> LoadAssessment {
        guard !stale, memory.totalBytes > 0 else {
            return LoadAssessment(title: stale ? "采样暂未更新" : "正在了解这台电脑", detail: "等待有效的整机与内存采样。",
                                  advice: "数据不足时不判断机器是否正常。", level: .unknown)
        }
        var facts: [String] = []
        if let cpu = load.cpuPercent { facts.append(String(format: "CPU 使用 %.0f%%", cpu)) }
        else { facts.append("CPU 等待相邻采样") }
        facts.append("内存压力\(memory.pressure.rawValue)")
        facts.append("系统热状态：\(load.thermalState.rawValue)")
        if let temperature = load.sensors.hottest { facts.append(String(format: "CPU 温区最高 %.1f°C", temperature)) }
        facts.append(load.sensors.fanSummary)
        let top = apps.filter { ($0.cpuPercent ?? 0) > 0 }.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
        if let top { facts.append("可读取应用中，\(top.name) 的 CPU 占用最高") }
        let detail = facts.joined(separator: "；") + "。"
        if load.thermalState == .critical || load.thermalState == .serious {
            return LoadAssessment(title: load.thermalState.rawValue, detail: detail,
                                  advice: "可暂停不急的计算任务，保持通风；风扇由系统自动调节。", level: .high)
        }
        if memory.pressure == .high || memory.pressure == .medium {
            return LoadAssessment(title: memory.pressure == .high ? "内存紧张，先检查闲置应用" : "内存开始承压", detail: detail,
                                  advice: "先保存工作，再关闭不再使用的窗口；缓存由系统按需回收。", level: memory.pressure == .high ? .high : .watch)
        }
        guard let cpu = load.cpuPercent else {
            return LoadAssessment(title: "正在积累 CPU 采样", detail: detail, advice: "稍后显示整机负载与主要占用者。", level: .unknown)
        }
        if cpu >= 80 {
            let recent = history.filter { $0.timestamp >= load.timestamp.addingTimeInterval(-40) && $0.timestamp <= load.timestamp }
            let covered = recent.first.map { load.timestamp.timeIntervalSince($0.timestamp) >= 30 } ?? false
            let continuous = zip(recent, recent.dropFirst()).allSatisfy { $1.timestamp.timeIntervalSince($0.timestamp) <= 10 }
            let sustained = covered && continuous && recent.allSatisfy { ($0.cpuPercent ?? -1) >= 80 }
            return LoadAssessment(title: sustained ? "CPU 持续繁忙" : "CPU 当前较忙", detail: detail,
                                  advice: sustained ? "主要计算任务持续占用 CPU；若影响操作，可在原应用中暂停不急的任务。" : "先观察走势；短时峰值常见于编译、索引或页面加载，不必立即处理。", level: .watch)
        }
        if load.thermalState == .fair {
            return LoadAssessment(title: "机器正在散热，仍有计算余量", detail: detail,
                                  advice: "系统处于轻度升温；风扇运转本身不是异常，继续观察负载与热状态即可。", level: .watch)
        }
        guard memory.pressure != .unknown, load.thermalState != .unknown else {
            return LoadAssessment(title: "部分系统状态未知", detail: detail, advice: "结合已读取的指标判断，不据缺失数据认定正常。", level: .unknown)
        }
        return LoadAssessment(title: cpu >= 50 ? "机器较忙，仍有余量" : "负载平稳，暂时无需处理", detail: detail,
                              advice: "当前没有观察到内存或系统散热压力；可继续工作。", level: .normal)
    }
}

extension AppMemoryUsage {
    /// 同一组所有可读取进程的 CPU 占整机容量比例；不能读取的部分不计成零。
    var cpuPercent: Double? {
        let values = processes.compactMap(\.cpuPercent)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var cpuIsPartial: Bool { processes.contains { $0.cpuPercent == nil } }
    var cpuHistoryKey: String { groupKey ?? applicationURL?.path ?? command }
}

func cpuText(_ percent: Double?) -> String {
    percent.map { String(format: "%.1f%%", $0) } ?? "—"
}
