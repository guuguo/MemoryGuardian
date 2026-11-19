import Foundation

struct GPUSnapshot: Equatable, Sendable {
    var utilizationPercent: Double? = nil
    var rendererPercent: Double? = nil
    var tilerPercent: Double? = nil
    var inUseMemoryBytes: UInt64? = nil
    var temperatureCelsius: Double? = nil
    var powerWatts: Double? = nil
}

struct BatterySnapshot: Equatable, Sendable {
    var percent: Int? = nil
    var cycleCount: Int? = nil
    var healthPercent: Int? = nil
    var isExternalConnected: Bool = false
    var isCharging: Bool = false
    var adapterWatts: Int? = nil
    var systemPowerWatts: Double? = nil
    var batteryDischargeWatts: Double? = nil
    var designCapacityMah: Int? = nil
    var maxCapacityMah: Int? = nil
    var timeRemainingMinutes: Int? = nil

    var statusText: String {
        if isExternalConnected {
            return isCharging ? "正在充电" : "已接电，未充电"
        }
        if let minutes = timeRemainingMinutes, minutes > 0, minutes < 24 * 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return hours > 0 ? "使用电池 · 约 \(hours)小时\(mins)分" : "使用电池 · 约 \(mins)分钟"
        }
        return "使用电池"
    }

    var headlineWattsText: String? {
        if isExternalConnected {
            if let adapterWatts, adapterWatts > 0 { return "\(adapterWatts)W" }
            if let systemPowerWatts, systemPowerWatts > 0 { return String(format: "%.0fW", systemPowerWatts) }
            return nil
        }
        if let batteryDischargeWatts, batteryDischargeWatts > 0.1 {
            return String(format: "%.1fW", batteryDischargeWatts)
        }
        if let systemPowerWatts, systemPowerWatts > 0.1 {
            return String(format: "%.1fW", systemPowerWatts)
        }
        return nil
    }
}

struct StorageTelemetrySnapshot: Equatable, Sendable {
    var totalBytes: UInt64? = nil
    var availableBytes: UInt64? = nil
    var readBytesPerSecond: Double? = nil
    var writeBytesPerSecond: Double? = nil

    var usedRatio: Double? {
        guard let totalBytes, let availableBytes, totalBytes > 0 else { return nil }
        let used = totalBytes >= availableBytes ? totalBytes - availableBytes : 0
        return min(1, max(0, Double(used) / Double(totalBytes)))
    }
}

enum NetworkInterfaceKind: Equatable, Sendable {
    case wifi
    case ethernet
    case disconnected
    case other(String)

    var label: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "以太网"
        case .disconnected: "未连接"
        case .other(let name): name
        }
    }
}

struct NetworkTelemetrySnapshot: Equatable, Sendable {
    var interfaceKind: NetworkInterfaceKind = .disconnected
    var interfaceName: String? = nil
    var downloadBytesPerSecond: Double? = nil
    var uploadBytesPerSecond: Double? = nil
    var isConstrained: Bool = false
    var isExpensive: Bool = false

    var statusLabel: String {
        if interfaceKind == .disconnected { return "未连接网络" }
        if isConstrained { return "低数据模式" }
        if isExpensive { return "热点网络" }
        if let interfaceName { return "链路正常 · \(interfaceName)" }
        return "链路正常"
    }
}

struct MachineHardwareTelemetry: Equatable, Sendable {
    var timestamp = Date()
    var chipName: String = ""
    var uptimeSeconds: TimeInterval? = nil
    var loadAverage1m: Double? = nil
    var gpu = GPUSnapshot()
    var battery: BatterySnapshot? = nil
    var storage = StorageTelemetrySnapshot()
    var network = NetworkTelemetrySnapshot()

    var chipBadge: String {
        let trimmed = chipName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Mac" }
        return trimmed.hasPrefix("Apple ") ? String(trimmed.dropFirst("Apple ".count)) : trimmed
    }
}

struct MachineOverviewHistoryPoint: Equatable, Sendable {
    let timestamp: Date
    let cpuPercent: Double?
    let gpuPercent: Double?
    let memoryUsedPercent: Double?
    let networkDownloadBps: Double?
    let networkUploadBps: Double?
}

struct MachineHealthFactor: Identifiable, Equatable {
    let id: String
    let label: String
    let deduction: Int
    let note: String
}

/// 基于真实系统指标计算透明可解释的整机健康度，不凭空构造波动。
struct MachineHealthEvaluation: Equatable {
    enum Grade: String {
        case excellent = "很好"
        case good = "良好"
        case watch = "注意"
        case strained = "承压"
        case unknown = "采样中"
    }

    let score: Int?
    let grade: Grade
    let headline: String
    let factors: [MachineHealthFactor]

    static func evaluate(
        load: MachineLoadSnapshot,
        memory: MemorySnapshot,
        telemetry: MachineHardwareTelemetry,
        assessment: LoadAssessment,
        stale: Bool
    ) -> MachineHealthEvaluation {
        guard !stale, memory.totalBytes > 0 else {
            return MachineHealthEvaluation(score: nil, grade: .unknown, headline: assessment.title, factors: [])
        }

        var score = 100
        var factors: [MachineHealthFactor] = []

        switch memory.pressure {
        case .normal: break
        case .medium:
            score -= 18
            factors.append(.init(id: "mem-pressure", label: "内存压力中等", deduction: 18, note: "系统开始压缩或回收缓存页"))
        case .high:
            score -= 35
            factors.append(.init(id: "mem-pressure", label: "内存压力偏高", deduction: 35, note: "建议关闭闲置应用释放内存"))
        case .unknown:
            score -= 5
            factors.append(.init(id: "mem-unknown", label: "内存压力未知", deduction: 5, note: "系统压力读数暂不可用"))
        }

        switch load.thermalState {
        case .nominal: break
        case .fair:
            score -= 6
            factors.append(.init(id: "thermal", label: "轻度升温", deduction: 6, note: "系统主动散热中，仍有计算余量"))
        case .serious:
            score -= 22
            factors.append(.init(id: "thermal", label: "散热压力较高", deduction: 22, note: "建议保持通风并减轻重计算任务"))
        case .critical:
            score -= 36
            factors.append(.init(id: "thermal", label: "散热影响性能", deduction: 36, note: "已触发降频保护"))
        case .unknown:
            score -= 4
            factors.append(.init(id: "thermal-unknown", label: "热状态未知", deduction: 4, note: "系统热状态未报告"))
        }

        if let cpu = load.cpuPercent {
            if cpu >= 90 {
                score -= 14
                factors.append(.init(id: "cpu", label: "CPU 高负载", deduction: 14, note: String(format: "整机占用 %.0f%%", cpu)))
            } else if cpu >= 75 {
                score -= 7
                factors.append(.init(id: "cpu", label: "CPU 较忙", deduction: 7, note: String(format: "整机占用 %.0f%%", cpu)))
            }
        }

        if memory.swapUsedBytes >= 8 * 1_073_741_824 {
            score -= 10
            factors.append(.init(id: "swap", label: "交换空间较多", deduction: 10, note: "Swap 已用 \(memory.swapUsedBytes.binaryBytesText)"))
        } else if memory.swapUsedBytes >= 2 * 1_073_741_824 {
            score -= 4
            factors.append(.init(id: "swap", label: "存在交换空间占用", deduction: 4, note: "Swap 已用 \(memory.swapUsedBytes.binaryBytesText)"))
        }

        if let total = telemetry.storage.totalBytes, let available = telemetry.storage.availableBytes, total > 0 {
            let freeRatio = Double(available) / Double(total)
            if freeRatio < 0.05 {
                score -= 15
                factors.append(.init(id: "disk", label: "磁盘可用空间极低", deduction: 15, note: "仅剩 \(TelemetryFormat.decimalGigabytes(available))"))
            } else if freeRatio < 0.10 {
                score -= 6
                factors.append(.init(id: "disk", label: "磁盘空间偏紧", deduction: 6, note: "可用 \(TelemetryFormat.decimalGigabytes(available))"))
            }
        }

        if let health = telemetry.battery?.healthPercent, health < 80 {
            score -= 8
            factors.append(.init(id: "battery", label: "电池健康度下降", deduction: 8, note: "最大容量 \(health)%"))
        }

        let clamped = max(0, min(100, score))
        let grade: Grade
        switch clamped {
        case 90...100: grade = .excellent
        case 75..<90: grade = .good
        case 50..<75: grade = .watch
        default: grade = .strained
        }

        let headline = factors.isEmpty ? "当前指标正常" : (factors.first?.label ?? assessment.title)
        return MachineHealthEvaluation(score: clamped, grade: grade, headline: headline, factors: factors)
    }
}

enum TelemetryFormat {
    static func uptime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "运行时间未知" }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "已运行 \(days)天 \(hours)小时" }
        if hours > 0 { return "已运行 \(hours)小时 \(minutes)分钟" }
        return "已运行 \(max(1, minutes))分钟"
    }

    static func rate(_ bytesPerSecond: Double?) -> (value: String, unit: String) {
        guard let bps = bytesPerSecond, bps.isFinite, bps >= 0 else { return ("—", "") }
        if bps < 1024 {
            return bps < 1 ? ("0", "KB/s") : ("<1", "KB/s")
        }
        let kb = bps / 1024
        if kb < 1024 {
            return (kb < 10 ? String(format: "%.0f", kb) : String(format: "%.0f", kb), "KB/s")
        }
        let mb = kb / 1024
        if mb < 1024 {
            return (mb < 100 ? String(format: "%.1f", mb) : String(format: "%.0f", mb), "MB/s")
        }
        let gb = mb / 1024
        return (String(format: "%.2f", gb), "GB/s")
    }

    static func rateInline(_ bytesPerSecond: Double?) -> String {
        let parts = rate(bytesPerSecond)
        return parts.unit.isEmpty ? parts.value : "\(parts.value) \(parts.unit)"
    }

    /// 磁盘容量沿用 macOS 访达与存储面板的十进制 GB 口径（1 GB = 10^9 B）。
    static func decimalGigabytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let tb = Double(bytes) / 1_000_000_000_000
        if tb >= 10 { return String(format: "%.1f TB", tb) }
        let gb = Double(bytes) / 1_000_000_000
        return String(format: "%.0f GB", gb.rounded())
    }

    static func decimalGigabytesParts(_ bytes: UInt64?) -> (value: String, unit: String) {
        guard let bytes else { return ("—", "") }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 10_000 {
            return (String(format: "%.1f", gb / 1000), "TB")
        }
        return (String(format: "%.0f", gb.rounded()), "GB")
    }

    static func binaryGigabytesTwoDecimals(_ bytes: UInt64) -> String {
        String(format: "%.2f GiB", Double(bytes) / 1_073_741_824)
    }

    static func loadLevel(_ cpuPercent: Double?) -> String {
        guard let cpuPercent else { return "等待采样" }
        if cpuPercent < 40 { return "低负载" }
        if cpuPercent < 75 { return "中等负载" }
        return "高负载"
    }

    static func gpuLoadLevel(_ gpuPercent: Double?) -> String {
        guard let gpuPercent else { return "等待采样" }
        if gpuPercent < 35 { return "低负载" }
        if gpuPercent < 75 { return "中等负载" }
        return "高负载"
    }
}
