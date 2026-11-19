import Foundation
import Darwin
import IOKit

/// 由 SystemSampler 的单一刷新调用，跟随原采样生命周期；不启动后台进程。
final class LoadSampler {
    private var previousTicks: [CPUTicks]?
    private let sensors = ReadOnlySMC()
    private var lastSensors = SensorSnapshot()

    func resetCPUBaseline() { previousTicks = nil }

    func sample() -> MachineLoadSnapshot {
        let now = Date()
        var result = MachineLoadSnapshot(timestamp: now, thermalState: MachineThermalState(ProcessInfo.processInfo.thermalState))
        if let ticks = readTicks() {
            let usage = Self.cpuUsage(ticks: ticks, previous: previousTicks)
            result.cpuUser = usage.user
            result.cpuSystem = usage.system
            result.cores = usage.cores
            previousTicks = ticks
        } else { previousTicks = nil }
        if lastSensors.timestamp.map({ now.timeIntervalSince($0) >= 10 }) ?? true { lastSensors = sensors.sample(at: now) }
        result.sensors = lastSensors
        return result
    }

    private func readTicks() -> [CPUTicks]? {
        var cores: natural_t = 0
        var data: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let status = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &data, &count)
        guard status == KERN_SUCCESS, let data else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: data)),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        guard Int(count) >= Int(cores) * stride else { return nil }
        return (0..<Int(cores)).map { index in
            let base = index * stride
            return CPUTicks(user: UInt32(bitPattern: data[base + Int(CPU_STATE_USER)]),
                            system: UInt32(bitPattern: data[base + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt32(bitPattern: data[base + Int(CPU_STATE_IDLE)]),
                            nice: UInt32(bitPattern: data[base + Int(CPU_STATE_NICE)]))
        }
    }

    static func cpuUsage(ticks: [CPUTicks], previous: [CPUTicks]?) -> (user: Double?, system: Double?, cores: [CoreCPUReading]) {
        let baseline = previous?.count == ticks.count ? previous : nil
        let readings = ticks.enumerated().map { index, value in
            let usage = value.utilization(since: baseline?[index])
            return CoreCPUReading(id: index, percent: usage.map { $0.user + $0.system })
        }
        func sum(_ values: [CPUTicks]) -> CPUTicks {
            values.reduce(CPUTicks(user: 0, system: 0, idle: 0, nice: 0)) {
                CPUTicks(user: $0.user &+ $1.user, system: $0.system &+ $1.system,
                         idle: $0.idle &+ $1.idle, nice: $0.nice &+ $1.nice)
            }
        }
        // 整机与逐核共用同一份计数；按累计时间求总量，不假定各核心性能相同。
        let total = sum(ticks).utilization(since: baseline.map(sum))
        return (total?.user, total?.system, readings)
    }
}

/// 只实现 SMC 的读元数据(9)与读值(5)，没有写入或风扇控制接口。
/// 协议布局/代际温区资料：exelban/stats SMC/smc.swift、Modules/Sensors/values.swift。
/// key 是热传感器标识，不代表一一对应的 CPU 核心。
final class ReadOnlySMC {
    private var connection: io_connect_t = 0
    private var metadata: [String: (size: UInt32, type: String)] = [:]
    private let temperatureKeys: [String]
    private var fanMaximumRPM: [Int: Double] = [:]

    init() {
        var brand = [CChar](repeating: 0, count: 128)
        var size = brand.count
        let ok = sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0) == 0
        temperatureKeys = Self.keys(for: ok ? String(decoding: brand.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    static func keys(for chip: String) -> [String] {
        let family = chip.split(separator: " ").prefix(2).joined(separator: " ")
        if family == "Apple M5" { return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"] }
        if family == "Apple M4" { return ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"] }
        if family == "Apple M3" { return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"] }
        if family == "Apple M2" { return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"] }
        if family == "Apple M1" { return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"] }
        if chip.contains("Intel") { return ["TC0D", "TC0P", "TCAD"] }
        return []
    }

    func sample(at timestamp: Date) -> SensorSnapshot {
        var snapshot = SensorSnapshot(timestamp: timestamp)
        guard connection != 0 else {
            snapshot.temperatureIssue = "SMC 传感器不可访问"; snapshot.fanIssue = "SMC 转速不可访问"
            return snapshot
        }
        snapshot.temperatures = temperatureKeys.compactMap { key in
            guard let value = read(key), value.isFinite, value > 0, value < 150 else { return nil }
            return TemperatureReading(id: key, celsius: value)
        }
        snapshot.temperatureIssue = temperatureKeys.isEmpty ? "此芯片温区映射尚未支持" : snapshot.temperatures.isEmpty ? "CPU 温区读取失败" : nil
        if let count = read("FNum"), count.isFinite, count >= 0, count <= 8, count.rounded() == count {
            snapshot.fanCount = Int(count)
            snapshot.fans = (0..<Int(count)).map { index in
                let rpm = read("F\(index)Ac")
                if fanMaximumRPM[index] == nil {
                    fanMaximumRPM[index] = Self.validRPM(read("F\(index)Mx"), maximum: true)
                }
                return FanReading(id: index, rpm: Self.validRPM(rpm), maximumRPM: fanMaximumRPM[index])
            }
            snapshot.fanIssue = snapshot.fans.contains { $0.rpm == nil } ? "部分风扇转速读取失败" : nil
        } else { snapshot.fanIssue = "风扇数量未读取" }
        return snapshot
    }

    static func validRPM(_ value: Double?, maximum: Bool = false) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 && $0 < 30_000 && (!maximum || $0 > 0) ? $0 : nil }
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var size = 80
        let status = input.withUnsafeBytes { bytes in
            output.withUnsafeMutableBytes { out in
                IOConnectCallStructMethod(connection, 2, bytes.baseAddress, 80, out.baseAddress, &size)
            }
        }
        return status == KERN_SUCCESS && size == 80 && output[40] == 0 ? output : nil
    }

    private func read(_ key: String) -> Double? {
        var input = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        withUnsafeBytes(of: code) { input.replaceSubrange(0..<4, with: $0) }
        if metadata[key] == nil {
            input[42] = 9
            guard let meta = call(input) else { return nil }
            let size = meta.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
            guard size > 0, size <= 32, let type = String(bytes: meta[32..<36].reversed(), encoding: .ascii) else { return nil }
            metadata[key] = (size, type)
        }
        guard let meta = metadata[key] else { return nil }
        withUnsafeBytes(of: meta.size) { input.replaceSubrange(28..<32, with: $0) }
        input[42] = 5
        guard let value = call(input) else { return nil }
        return Self.decode(type: meta.type, bytes: Array(value[48..<(48 + Int(meta.size))]))
    }

    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt " where bytes.count == 4: return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 " where bytes.count == 1: return Double(bytes[0])
        case "fpe2" where bytes.count == 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78" where bytes.count == 2: return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
    }
}
