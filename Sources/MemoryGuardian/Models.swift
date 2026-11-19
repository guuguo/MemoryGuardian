import Foundation

struct MemorySnapshot: Equatable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var freeBytes: UInt64
    var appBytes: UInt64
    var topAppBytes: UInt64
    var otherAppBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var swapUsedBytes: UInt64
    var pressure: MemoryPressure
    var timestamp: Date
    var cachedBytes: UInt64 = 0
    var swapTotalBytes: UInt64? = nil
    var startupDiskAvailableBytes: UInt64? = nil
    var swapInBytes: UInt64 = 0
    var swapOutBytes: UInt64 = 0
    var swapInBytesPerSecond: Double? = nil
    var swapOutBytesPerSecond: Double? = nil

    var unclassifiedBytes: UInt64 {
        let classified = appBytes + wiredBytes + compressedBytes + cachedBytes + freeBytes
        return totalBytes > classified ? totalBytes - classified : 0
    }

    mutating func updateSwapRates(from previous: MemorySnapshot?) {
        guard let previous else { return }
        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0, swapInBytes >= previous.swapInBytes, swapOutBytes >= previous.swapOutBytes else { return }
        swapInBytesPerSecond = Double(swapInBytes - previous.swapInBytes) / elapsed
        swapOutBytesPerSecond = Double(swapOutBytes - previous.swapOutBytes) / elapsed
    }

    static let empty = MemorySnapshot(
        totalBytes: 0,
        usedBytes: 0,
        freeBytes: 0,
        appBytes: 0,
        topAppBytes: 0,
        otherAppBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        swapUsedBytes: 0,
        pressure: .unknown,
        timestamp: Date()
    )
}

enum MemoryPressure: String {
    case unknown = "未知"
    case normal = "正常"
    case medium = "中等"
    case high = "偏高"
}

struct AppMemoryUsage: Identifiable, Equatable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let command: String
    let memoryBytes: UInt64
    let compressedBytes: UInt64
    let processCount: Int
    let status: AppMemoryStatus
    let processes: [ProcessDetail]
    var usesFootprint: Bool = false
    var groupKey: String? = nil

    var applicationURL: URL? {
        guard let range = command.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(command[..<range.upperBound].dropLast()))
    }

    var historyKey: String { (groupKey ?? applicationURL?.path ?? command) + (usesFootprint ? "|footprint" : "|rss") }
}

enum AppMemoryStatus: String {
    case normal = "正常"
    case watch = "关注"
    case high = "偏高"
    case critical = "过高"
}

struct ProcessDetail: Identifiable, Equatable {
    var id: Int32 { pid }
    let pid: Int32
    let parentPid: Int32
    let name: String
    let memoryBytes: UInt64
    var compressedBytes: UInt64
    let command: String
    var arguments: String?
    var currentDirectory: String?
    var parentChain: [String]
    var footprintBytes: UInt64? = nil
    var service: ProcessService? = nil
    var cpuPercent: Double? = nil
    var startTimeTicks: UInt64? = nil
    var cpuTimeTicks: UInt64? = nil
}

struct ProcessService: Equatable {
    let identity: String
    let name: String
    let entryPoint: String?
}

struct MemoryHistoryPoint {
    let timestamp: Date
    let appBytes: [String: UInt64]
}

struct QuitObservation {
    let key: String
    let name: String
    let beforeBytes: UInt64
}

extension UInt64 {
    var binaryBytesText: String {
        let units: [(Double, String)] = [(1_099_511_627_776, "TiB"), (1_073_741_824, "GiB"), (1_048_576, "MiB"), (1024, "KiB")]
        for (divisor, unit) in units where Double(self) >= divisor {
            return String(format: "%.1f %@", Double(self) / divisor, unit)
        }
        return "\(self) B"
    }
}


