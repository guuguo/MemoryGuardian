import Foundation
import Darwin
import IOKit
import IOKit.ps
import Network

/// 无符号累计字节计数器速率差分器；首次、超时（>10s）或计数器回绕返回 nil，不造假值。
struct ByteRateTracker: Sendable {
    struct Sample: Equatable, Sendable {
        let timestamp: Date
        let rxBytes: UInt64
        let txBytes: UInt64
    }

    private(set) var previous: Sample?
    let maxGapSeconds: TimeInterval

    init(maxGapSeconds: TimeInterval = 10) {
        self.maxGapSeconds = maxGapSeconds
    }

    mutating func reset() {
        previous = nil
    }

    mutating func update(rxBytes: UInt64, txBytes: UInt64, at timestamp: Date) -> (rxPerSecond: Double, txPerSecond: Double)? {
        let current = Sample(timestamp: timestamp, rxBytes: rxBytes, txBytes: txBytes)
        defer { previous = current }
        guard let previous else { return nil }
        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0, elapsed <= maxGapSeconds,
              rxBytes >= previous.rxBytes, txBytes >= previous.txBytes else {
            return nil
        }
        return (
            Double(rxBytes - previous.rxBytes) / elapsed,
            Double(txBytes - previous.txBytes) / elapsed
        )
    }
}

final class MachineTelemetrySampler: @unchecked Sendable {
    private var storageRateTracker = ByteRateTracker()
    private var networkRateTracker = ByteRateTracker()
    private var lastNetworkInterfaceName: String?

    private let pathLock = NSLock()
    private var pathSnapshot = NetworkPathState()
    private let pathMonitor = NWPathMonitor()

    private struct NetworkPathState {
        var kind: NetworkInterfaceKind = .disconnected
        var interfaceName: String? = nil
        var isConstrained = false
        var isExpensive = false
    }

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let state = Self.interpret(path: path)
            self.pathLock.lock()
            self.pathSnapshot = state
            self.pathLock.unlock()
        }
        pathMonitor.start(queue: DispatchQueue(label: "MemoryGuardian.NetworkPath", qos: .utility))
    }

    deinit {
        pathMonitor.cancel()
    }

    func resetBaselines() {
        storageRateTracker.reset()
        networkRateTracker.reset()
    }

    func sample(at now: Date = Date()) -> MachineHardwareTelemetry {
        MachineHardwareTelemetry(
            timestamp: now,
            chipName: Self.readChipName(),
            uptimeSeconds: Self.readUptimeSeconds(now: now),
            loadAverage1m: Self.readLoadAverage1m(),
            gpu: Self.readGPUSnapshot(),
            battery: Self.readBatterySnapshot(),
            storage: readStorageTelemetry(at: now),
            network: readNetworkTelemetry(at: now)
        )
    }

    static func readChipName() -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        var size = buffer.count
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func readUptimeSeconds(now: Date = Date()) -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
        return max(0, now.timeIntervalSince(bootDate))
    }

    static func readLoadAverage1m() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        guard count >= 1, loads[0].isFinite, loads[0] >= 0 else { return nil }
        return loads[0]
    }

    static func readGPUSnapshot() -> GPUSnapshot {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return GPUSnapshot()
        }
        defer { IOObjectRelease(iterator) }

        var snapshot = GPUSnapshot()
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            if let util = numberValue(stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) {
                snapshot.utilizationPercent = max(snapshot.utilizationPercent ?? 0, min(100, max(0, util)))
            }
            if let renderer = numberValue(stats["Renderer Utilization %"]) {
                snapshot.rendererPercent = max(snapshot.rendererPercent ?? 0, min(100, max(0, renderer)))
            }
            if let tiler = numberValue(stats["Tiler Utilization %"]) {
                snapshot.tilerPercent = max(snapshot.tilerPercent ?? 0, min(100, max(0, tiler)))
            }
            if let mem = uint64Value(stats["In use system memory"] ?? stats["Alloc system memory"]) {
                snapshot.inUseMemoryBytes = (snapshot.inUseMemoryBytes ?? 0) + mem
            }
        }
        return snapshot
    }

    static func readBatterySnapshot() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propertiesRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propertiesRef?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let currentCapacity = intValue(props["CurrentCapacity"])
        let cycleCount = intValue(props["CycleCount"])
        let designCapacity = intValue(props["DesignCapacity"])
        let nominalMax = intValue(props["NominalChargeCapacity"])
        let rawMax = intValue(props["AppleRawMaxCapacity"])
        let maxCap = nominalMax ?? rawMax
        let healthPercent: Int? = {
            guard let maxCap, let designCapacity, designCapacity > 0 else { return nil }
            return min(100, max(0, Int((Double(maxCap) / Double(designCapacity) * 100).rounded())))
        }()

        let isExternalConnected = boolValue(props["ExternalConnected"]) ?? false
        let isCharging = boolValue(props["IsCharging"]) ?? false
        let adapterDetails = props["AdapterDetails"] as? [String: Any]
        let adapterWatts = adapterDetails.flatMap { intValue($0["Watts"]) }

        let telemetry = props["PowerTelemetryData"] as? [String: Any]
        let systemLoadMilliWatts = telemetry.flatMap { numberValue($0["SystemLoad"]) }
        let systemPowerWatts = systemLoadMilliWatts.map { $0 / 1000.0 }

        var batteryDischargeWatts: Double?
        if let voltageMv = numberValue(props["Voltage"]),
           let rawAmperage = uint64Value(props["InstantAmperage"] ?? props["Amperage"]) {
            let signedMa = Int64(bitPattern: rawAmperage)
            if signedMa < 0 {
                batteryDischargeWatts = (voltageMv / 1000.0) * (Double(-signedMa) / 1000.0)
            }
        }

        let remainingEstimate = IOPSGetTimeRemainingEstimate()
        let timeRemainingMinutes: Int? = (remainingEstimate > 0 && remainingEstimate != kIOPSTimeRemainingUnlimited)
            ? Int((remainingEstimate / 60).rounded())
            : intValue(props["TimeRemaining"])

        return BatterySnapshot(
            percent: currentCapacity.map { min(100, max(0, $0)) },
            cycleCount: cycleCount,
            healthPercent: healthPercent,
            isExternalConnected: isExternalConnected,
            isCharging: isCharging,
            adapterWatts: adapterWatts,
            systemPowerWatts: systemPowerWatts,
            batteryDischargeWatts: batteryDischargeWatts,
            designCapacityMah: designCapacity,
            maxCapacityMah: maxCap,
            timeRemainingMinutes: timeRemainingMinutes
        )
    }

    private func readStorageTelemetry(at now: Date) -> StorageTelemetrySnapshot {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let total = values?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
        let available: UInt64? = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
            ?? values?.volumeAvailableCapacity.map { UInt64(max(0, $0)) }

        var readPerSec: Double?
        var writePerSec: Double?
        if let totals = Self.readBlockStorageByteTotals() {
            if let rates = storageRateTracker.update(rxBytes: totals.readBytes, txBytes: totals.writeBytes, at: now) {
                readPerSec = rates.rxPerSecond
                writePerSec = rates.txPerSecond
            }
        } else {
            storageRateTracker.reset()
        }

        return StorageTelemetrySnapshot(
            totalBytes: total,
            availableBytes: available,
            readBytesPerSecond: readPerSec,
            writeBytesPerSecond: writePerSec
        )
    }

    static func readBlockStorageByteTotals() -> (readBytes: UInt64, writeBytes: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var foundAny = false
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            foundAny = true
            totalRead &+= uint64Value(stats["Bytes (Read)"]) ?? 0
            totalWrite &+= uint64Value(stats["Bytes (Write)"]) ?? 0
        }
        return foundAny ? (totalRead, totalWrite) : nil
    }

    private func readNetworkTelemetry(at now: Date) -> NetworkTelemetrySnapshot {
        pathLock.lock()
        let path = pathSnapshot
        pathLock.unlock()

        if path.interfaceName != lastNetworkInterfaceName {
            lastNetworkInterfaceName = path.interfaceName
            networkRateTracker.reset()
        }

        guard path.kind != .disconnected else {
            networkRateTracker.reset()
            return NetworkTelemetrySnapshot(interfaceKind: .disconnected, interfaceName: nil)
        }

        var downBps: Double?
        var upBps: Double?
        if let totals = Self.readNetworkByteTotals(targetInterface: path.interfaceName) {
            if let rates = networkRateTracker.update(rxBytes: totals.rxBytes, txBytes: totals.txBytes, at: now) {
                downBps = rates.rxPerSecond
                upBps = rates.txPerSecond
            }
        } else {
            networkRateTracker.reset()
        }

        return NetworkTelemetrySnapshot(
            interfaceKind: path.kind,
            interfaceName: path.interfaceName,
            downloadBytesPerSecond: downBps,
            uploadBytesPerSecond: upBps,
            isConstrained: path.isConstrained,
            isExpensive: path.isExpensive
        )
    }

    static func readNetworkByteTotals(targetInterface: String?) -> (rxBytes: UInt64, txBytes: UInt64)? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return nil }
        defer { freeifaddrs(first) }

        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0
        var matched = false

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = current.pointee.ifa_data else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            let isUpRunning = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUpRunning, !isLoopback else { continue }

            let name = String(cString: current.pointee.ifa_name)
            if let targetInterface {
                guard name == targetInterface else { continue }
            } else {
                guard name.hasPrefix("en") else { continue }
            }

            let ifData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            rxTotal &+= UInt64(ifData.ifi_ibytes)
            txTotal &+= UInt64(ifData.ifi_obytes)
            matched = true
        }
        return matched ? (rxTotal, txTotal) : nil
    }

    private static func interpret(path: NWPath) -> NetworkPathState {
        guard path.status == .satisfied else {
            return NetworkPathState(kind: .disconnected, interfaceName: nil, isConstrained: path.isConstrained, isExpensive: path.isExpensive)
        }
        let primary = path.availableInterfaces.first
        let kind: NetworkInterfaceKind
        if path.usesInterfaceType(.wifi) || primary?.type == .wifi {
            kind = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) || primary?.type == .wiredEthernet {
            kind = .ethernet
        } else if let name = primary?.name {
            kind = .other(name)
        } else {
            kind = .other("网络")
        }
        return NetworkPathState(
            kind: kind,
            interfaceName: primary?.name,
            isConstrained: path.isConstrained,
            isExpensive: path.isExpensive
        )
    }

    private static func numberValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Float: return Double(value)
        case let value as Int: return Double(value)
        case let value as Int64: return Double(value)
        case let value as UInt64: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int: return value
        case let value as Int64: return Int(exactly: value)
        case let value as UInt64: return Int(exactly: value)
        case let value as NSNumber: return value.intValue
        default: return nil
        }
    }

    private static func uint64Value(_ raw: Any?) -> UInt64? {
        switch raw {
        case let value as UInt64: return value
        case let value as Int: return value >= 0 ? UInt64(value) : nil
        case let value as Int64: return value >= 0 ? UInt64(value) : UInt64(bitPattern: value)
        case let value as NSNumber: return value.uint64Value
        default: return nil
        }
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        default: return nil
        }
    }
}
