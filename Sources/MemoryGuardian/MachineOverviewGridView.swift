import SwiftUI

struct MachineOverviewGridView: View {
    @EnvironmentObject private var monitor: MemoryMonitor
    @Binding var section: DashboardSection
    let availableWidth: CGFloat

    @State private var showsHealthPopover = false
    @State private var showsBatteryPopover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stale: Bool { monitor.lastError != nil }
    private var load: MachineLoadSnapshot { monitor.load }
    private var memory: MemorySnapshot { monitor.snapshot }
    private var telemetry: MachineHardwareTelemetry { monitor.telemetry }
    private var assessment: LoadAssessment {
        .evaluate(load: load, memory: memory, apps: monitor.apps, history: monitor.loadHistory, stale: stale)
    }
    private var health: MachineHealthEvaluation {
        .evaluate(load: load, memory: memory, telemetry: telemetry, assessment: assessment, stale: stale)
    }

    private var columns: [GridItem] {
        let count = availableWidth >= 960 ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    private var topPowerApp: AppMemoryUsage? {
        monitor.apps
            .filter { ($0.cpuPercent ?? 0) > 0.1 }
            .max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            healthCard
            cpuCard
            gpuCard
            memoryCard
            batteryCard
            storageCard
            networkCard
            fanCard
        }
    }

    // MARK: - 1. 健康度

    private var healthAccent: Color {
        switch health.grade {
        case .excellent: Color(red: 0.38, green: 0.84, blue: 0.56)
        case .good: MemoryStyle.mint
        case .watch: Color(red: 0.96, green: 0.65, blue: 0.26)
        case .strained: Color(red: 0.94, green: 0.36, blue: 0.36)
        case .unknown: MemoryStyle.secondary
        }
    }

    private var healthCard: some View {
        Button { showsHealthPopover.toggle() } label: {
            OverviewCardShell(accent: healthAccent, interactive: true) {
                OverviewCardHeader(
                    icon: "sun.max.fill",
                    iconColor: healthAccent,
                    title: "健康度",
                    badgeText: telemetry.chipBadge
                )

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(health.score.map(String.init) ?? "—")
                                .font(.system(size: 38, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(health.grade.rawValue)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(MemoryStyle.text.opacity(0.9))
                        }
                        Text(health.headline)
                            .font(.system(size: 12))
                            .foregroundStyle(MemoryStyle.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HealthSolarOrbView(
                        grade: health.grade,
                        allowsMotion: monitor.samplingMode == .detailed && !reduceMotion && !stale
                    )
                    .frame(width: 78, height: 78)
                }
                .frame(maxHeight: .infinity, alignment: .center)

                HStack {
                    Text(TelemetryFormat.uptime(telemetry.uptimeSeconds))
                    Spacer()
                    Text("依据 →").foregroundStyle(MemoryStyle.mint.opacity(0.85))
                }
                .font(.system(size: 11))
                .foregroundStyle(MemoryStyle.secondary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsHealthPopover) {
            HealthDetailPopover(
                health: health,
                assessment: assessment,
                chipName: telemetry.chipName,
                onSelectCPU: { showsHealthPopover = false; section = .cpu },
                onSelectMemory: { showsHealthPopover = false; section = .memory }
            )
            .focusEffectDisabled()
        }
        .accessibilityLabel("整机健康度 \(health.score.map { "\($0) 分，\(health.grade.rawValue)" } ?? "采样中")，\(health.headline)")
    }

    // MARK: - 2. CPU

    private var cpuTint: Color { Color(red: 0.36, green: 0.83, blue: 0.56) }

    private var cpuCard: some View {
        let cpuTextValue = load.cpuPercent.map { String(format: "%.0f", $0) } ?? "—"
        let tempBadge = load.sensors.hottest.map { String(format: "%.0f°C", $0) } ?? "—"
        let coreCount = load.cores.isEmpty ? ProcessInfo.processInfo.activeProcessorCount : load.cores.count
        let loadAvgText = telemetry.loadAverage1m.map { String(format: "%.1f", $0) } ?? "—"

        return Button { section = .cpu } label: {
            OverviewCardShell(accent: cpuTint, interactive: true) {
                OverviewCardHeader(
                    icon: "cpu",
                    iconColor: cpuTint,
                    title: "CPU",
                    badgeText: tempBadge,
                    badgeColor: load.thermalState == .nominal ? MemoryStyle.secondary : load.thermalState.visualTint
                )

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(cpuTextValue)
                        .font(.system(size: 38, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if load.cpuPercent != nil {
                        Text("%").font(.system(size: 16, weight: .medium)).foregroundStyle(MemoryStyle.secondary)
                    }
                }

                MiniCoreBarStrip(
                    cores: load.cores,
                    tint: cpuTint,
                    allowsMotion: monitor.samplingMode == .detailed && !reduceMotion
                )
                .frame(height: 52)
                .frame(maxHeight: .infinity, alignment: .center)

                Text("\(TelemetryFormat.loadLevel(load.cpuPercent)) · \(coreCount) 核 · 平均负载 \(loadAvgText)")
                    .font(.system(size: 11))
                    .foregroundStyle(MemoryStyle.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("CPU 使用率 \(cpuTextValue)%，温度 \(tempBadge)，\(coreCount) 核，平均负载 \(loadAvgText)")
    }

    // MARK: - 3. GPU

    private var gpuTint: Color { Color(red: 0.93, green: 0.62, blue: 0.34) }

    private var gpuCard: some View {
        let util = telemetry.gpu.utilizationPercent
        let utilText = util.map { String(format: "%.0f", $0) } ?? "—"
        let badgeText: String = {
            if let temp = telemetry.gpu.temperatureCelsius {
                return String(format: "%.0f°C", temp)
            }
            if let vram = telemetry.gpu.inUseMemoryBytes, vram > 0 {
                return String(format: "显存 %.1fG", Double(vram) / 1_073_741_824)
            }
            return "核显"
        }()

        let footerText: String = {
            var parts = [TelemetryFormat.gpuLoadLevel(util)]
            if let watts = telemetry.gpu.powerWatts {
                parts.append(String(format: "%.1fW", watts))
            } else if let renderer = telemetry.gpu.rendererPercent {
                parts.append(String(format: "渲染 %.0f%%", renderer))
            }
            if let vram = telemetry.gpu.inUseMemoryBytes, vram > 0 {
                parts.append("已占 \(vram.binaryBytesText)")
            }
            return parts.joined(separator: " · ")
        }()

        let samples = monitor.overviewHistory.map {
            OverviewSparkSample(timestamp: $0.timestamp, primary: $0.gpuPercent, secondary: nil)
        }

        return OverviewCardShell(accent: gpuTint, interactive: false) {
            OverviewCardHeader(
                icon: "cube.transparent",
                iconColor: gpuTint,
                title: "GPU",
                badgeText: badgeText
            )

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(utilText)
                    .font(.system(size: 38, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if util != nil {
                    Text("%").font(.system(size: 16, weight: .medium)).foregroundStyle(MemoryStyle.secondary)
                }
            }

            OverviewSparklineView(
                samples: samples,
                ceiling: 100,
                primaryColor: gpuTint,
                fillArea: false,
                unitFormatter: { String(format: "%.0f%%", $0) }
            )
            .frame(height: 54)
            .frame(maxHeight: .infinity, alignment: .center)

            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(MemoryStyle.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("GPU 使用率 \(utilText)%，\(footerText)")
    }

    // MARK: - 4. 内存

    private var memoryTint: Color { Color(red: 0.89, green: 0.76, blue: 0.45) }

    private var memoryCard: some View {
        let usedPercent: Double? = memory.totalBytes > 0
            ? Double(memory.usedBytes) / Double(memory.totalBytes) * 100
            : nil
        let percentText = usedPercent.map { String(format: "%.0f", $0) } ?? "—"
        let effectivePressure = stale ? MemoryPressure.unknown : memory.pressure
        let pressureBadgeColor: Color = switch effectivePressure {
        case .normal: MemoryStyle.secondary
        case .medium: .orange
        case .high: .red
        case .unknown: MemoryStyle.secondary
        }
        let swapText = memory.swapUsedBytes == 0 ? "0" : memory.swapUsedBytes.binaryBytesText

        let samples = monitor.overviewHistory.map {
            OverviewSparkSample(timestamp: $0.timestamp, primary: $0.memoryUsedPercent, secondary: nil)
        }

        return Button { section = .memory } label: {
            OverviewCardShell(accent: memoryTint, interactive: true) {
                OverviewCardHeader(
                    icon: "memorychip",
                    iconColor: memoryTint,
                    title: "内存",
                    badgeText: "压力\(effectivePressure.rawValue)",
                    badgeColor: pressureBadgeColor
                )

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(percentText)
                        .font(.system(size: 38, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if usedPercent != nil {
                        Text("%").font(.system(size: 16, weight: .medium)).foregroundStyle(MemoryStyle.secondary)
                    }
                }

                OverviewSparklineView(
                    samples: samples,
                    ceiling: 100,
                    primaryColor: memoryTint,
                    fillArea: true,
                    unitFormatter: { String(format: "%.1f%%", $0) }
                )
                .frame(height: 54)
                .frame(maxHeight: .infinity, alignment: .center)

                Text(memory.totalBytes > 0
                     ? "\(TelemetryFormat.binaryGigabytesTwoDecimals(memory.usedBytes)) · 交换空间 \(swapText)"
                     : "等待内存采样")
                    .font(.system(size: 11))
                    .foregroundStyle(MemoryStyle.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("内存使用率 \(percentText)%，压力\(effectivePressure.rawValue)，已用 \(TelemetryFormat.binaryGigabytesTwoDecimals(memory.usedBytes))")
    }

    // MARK: - 5. 电池

    private var batteryTint: Color { Color(red: 0.36, green: 0.83, blue: 0.56) }

    private var batteryCard: some View {
        let battery = telemetry.battery
        let cycleSubtitle = battery?.cycleCount.map { "循环 \($0) 次" }
        let healthBadge = battery?.healthPercent.map { "健康 \($0)%" } ?? (battery == nil ? "交流供电" : "健康 —")
        let percentValue = battery?.percent.map(String.init) ?? "—"
        let ringFraction = battery?.percent.map { Double($0) / 100 }
        let statusLine = battery?.statusText ?? "桌面 Mac · 外接电源"
        let footerLine: String = {
            if let top = topPowerApp {
                return "当前耗电最多 \(top.name)"
            }
            return battery == nil ? "当前无电池设备" : "正在统计耗电应用…"
        }()

        return Button { showsBatteryPopover.toggle() } label: {
            OverviewCardShell(accent: batteryTint, interactive: true) {
                OverviewCardHeader(
                    icon: "battery.100",
                    iconColor: batteryTint,
                    title: "电池",
                    subtitle: cycleSubtitle,
                    badgeText: healthBadge
                )

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(percentValue)
                                .font(.system(size: 38, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            if battery?.percent != nil {
                                Text("%").font(.system(size: 16, weight: .medium)).foregroundStyle(MemoryStyle.secondary)
                            }
                            if let watts = battery?.headlineWattsText {
                                HStack(spacing: 2) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(battery?.isExternalConnected == true ? batteryTint : .orange)
                                    Text(watts)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(MemoryStyle.text.opacity(0.9))
                                }
                                .padding(.leading, 4)
                            }
                        }
                        Text(statusLine)
                            .font(.system(size: 12))
                            .foregroundStyle(MemoryStyle.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    TelemetryRing(
                        fraction: ringFraction,
                        tint: batteryTint,
                        symbol: "laptopcomputer"
                    )
                    .frame(width: 44, height: 44)
                }
                .frame(maxHeight: .infinity, alignment: .center)

                Text(footerLine)
                    .font(.system(size: 11))
                    .foregroundStyle(MemoryStyle.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsBatteryPopover) {
            BatteryDetailPopover(battery: battery, topApps: Array(monitor.apps.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }.prefix(3)))
                .focusEffectDisabled()
        }
        .accessibilityLabel("电池 \(percentValue)%，\(statusLine)，\(healthBadge)")
    }

    // MARK: - 6. 可用空间

    private var storageTint: Color { Color(red: 0.38, green: 0.62, blue: 0.96) }

    private var storageCard: some View {
        let storage = telemetry.storage
        let availableParts = TelemetryFormat.decimalGigabytesParts(storage.availableBytes ?? memory.startupDiskAvailableBytes)
        let totalText = TelemetryFormat.decimalGigabytes(storage.totalBytes)
        let usedRatio = storage.usedRatio ?? 0
        let readText = TelemetryFormat.rateInline(storage.readBytesPerSecond)
        let writeText = TelemetryFormat.rateInline(storage.writeBytesPerSecond)

        return OverviewCardShell(accent: storageTint, interactive: false) {
            OverviewCardHeader(
                icon: "internaldrive",
                iconColor: storageTint,
                title: "可用空间",
                badgeText: totalText
            )

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(availableParts.value)
                    .font(.system(size: 38, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if !availableParts.unit.isEmpty {
                    Text(availableParts.unit)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(MemoryStyle.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color(red: 0.30, green: 0.55, blue: 0.92), Color(red: 0.45, green: 0.72, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: max(storage.usedRatio == nil ? 0 : 8, proxy.size.width * usedRatio))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: usedRatio)
                    }
                }
                .frame(height: 8)
                .help(storage.usedRatio.map { String(format: "启动盘已用 %.1f%%，总容量 %@", $0 * 100, totalText) } ?? "等待存储统计")
            }
            .frame(maxHeight: .infinity, alignment: .center)

            Text("读 \(readText) · 写 \(writeText)")
                .font(.system(size: 11))
                .foregroundStyle(MemoryStyle.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("启动盘可用空间 \(availableParts.value) \(availableParts.unit)，总容量 \(totalText)，读 \(readText)，写 \(writeText)")
    }

    // MARK: - 7. 网络

    private var networkDownloadTint: Color { Color(red: 0.30, green: 0.78, blue: 0.68) }
    private var networkUploadTint: Color { Color(red: 0.36, green: 0.64, blue: 0.98) }

    private var networkCard: some View {
        let net = telemetry.network
        let downParts = TelemetryFormat.rate(net.downloadBytesPerSecond)
        let upText = TelemetryFormat.rateInline(net.uploadBytesPerSecond)

        let samples = monitor.overviewHistory.map {
            OverviewSparkSample(timestamp: $0.timestamp, primary: $0.networkDownloadBps, secondary: $0.networkUploadBps)
        }
        let maxBps = samples.flatMap { [$0.primary, $0.secondary].compactMap { $0 } }.max() ?? 0
        let dynamicCeiling = max(10_240, maxBps * 1.2)

        return OverviewCardShell(accent: networkDownloadTint, interactive: false) {
            OverviewCardHeader(
                icon: "globe",
                iconColor: networkUploadTint,
                title: "网络",
                badgeText: net.interfaceKind.label
            )

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(downParts.value)
                    .font(.system(size: 38, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if !downParts.unit.isEmpty {
                    Text(downParts.unit)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(MemoryStyle.secondary)
                }
            }

            OverviewSparklineView(
                samples: samples,
                ceiling: dynamicCeiling,
                primaryColor: networkDownloadTint,
                secondaryColor: networkUploadTint,
                fillArea: false,
                unitFormatter: { TelemetryFormat.rateInline($0) }
            )
            .frame(height: 54)
            .frame(maxHeight: .infinity, alignment: .center)

            HStack(spacing: 6) {
                Text("上传 \(upText)")
                    .monospacedDigit()
                Spacer()
                Text(net.statusLabel)
                    .foregroundStyle(MemoryStyle.secondary.opacity(0.9))
            }
            .font(.system(size: 11))
            .foregroundStyle(MemoryStyle.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("网络 \(net.interfaceKind.label)，下载 \(downParts.value) \(downParts.unit)，上传 \(upText)")
    }

    // MARK: - 8. 风扇

    private var fanTint: Color { Color(red: 0.36, green: 0.80, blue: 0.72) }

    private var fanCard: some View {
        let fans = load.sensors.fans
        let peakFan = fans.max { ($0.rpm ?? -1) < ($1.rpm ?? -1) }
        let peakRPMText = peakFan?.rpm.map { String(format: "%.0f", $0) } ?? (load.sensors.fanCount == 0 ? "无" : "—")
        let maxFraction = fans.compactMap(\.speedFraction).max()
        let percentBadge = maxFraction.map { String(format: "转速 %.0f%%", $0 * 100) }
            ?? (load.sensors.fanCount == 0 ? "无风扇" : "转速 —")

        return Button { section = .cpu } label: {
            OverviewCardShell(accent: fanTint, interactive: true) {
                OverviewCardHeader(
                    icon: "fan.fill",
                    iconColor: fanTint,
                    title: "风扇",
                    badgeText: percentBadge
                )

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(peakRPMText)
                        .font(.system(size: 38, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if peakFan?.rpm != nil {
                        Text("RPM")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MemoryStyle.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    if fans.isEmpty {
                        Text(load.sensors.fanSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(MemoryStyle.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ForEach(fans.prefix(2)) { fan in
                                HStack(spacing: 6) {
                                    FanRotorView(rpm: fan.rpm, stale: stale)
                                        .frame(width: 24, height: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("风扇\(fan.id + 1)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(MemoryStyle.secondary)
                                        Text(fan.rpm.map { "\(Int($0)) RPM" } ?? "—")
                                            .font(.system(size: 11, weight: .medium))
                                            .monospacedDigit()
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Text("自动托管")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MemoryStyle.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.11), in: Capsule())
                        Text("散热\(load.thermalState.rawValue)")
                            .font(.system(size: 11))
                            .foregroundStyle(load.thermalState.visualTint)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(load.thermalState.visualTint.opacity(0.12), in: Capsule())
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)

                Text(load.sensors.fanCount == 0 ? "被动散热，无需风扇" : "由系统自动调节（只读监测）")
                    .font(.system(size: 11))
                    .foregroundStyle(MemoryStyle.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("风扇 \(peakRPMText) RPM，\(percentBadge)，由系统自动调节")
    }
}

// MARK: - 卡片壳与通用头组件

private struct OverviewCardShell<Content: View>: View {
    let accent: Color
    let interactive: Bool
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .frame(height: 214, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.145, green: 0.156, blue: 0.165).opacity(0.92))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.035), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    hovered && interactive ? accent.opacity(0.45) : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { if interactive { hovered = $0 } }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

private struct OverviewCardHeader: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    let badgeText: String
    var badgeColor: Color = MemoryStyle.secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MemoryStyle.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(MemoryStyle.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            Text(badgeText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(badgeColor == MemoryStyle.secondary ? MemoryStyle.text.opacity(0.85) : badgeColor)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .lineLimit(1)
        }
    }
}

// MARK: - 健康度光球视觉

private struct HealthSolarOrbView: View {
    let grade: MachineHealthEvaluation.Grade
    let allowsMotion: Bool
    @State private var pulse = false

    private var colors: (core: Color, mid: Color, rim: Color, glow: Color) {
        switch grade {
        case .excellent:
            return (
                Color(red: 1.0, green: 0.93, blue: 0.66),
                Color(red: 0.98, green: 0.56, blue: 0.16),
                Color(red: 0.85, green: 0.28, blue: 0.08),
                Color(red: 1.0, green: 0.55, blue: 0.12)
            )
        case .good:
            return (
                Color(red: 0.85, green: 0.98, blue: 0.92),
                Color(red: 0.38, green: 0.84, blue: 0.65),
                Color(red: 0.14, green: 0.52, blue: 0.42),
                Color(red: 0.40, green: 0.85, blue: 0.68)
            )
        case .watch:
            return (
                Color(red: 1.0, green: 0.88, blue: 0.60),
                Color(red: 0.95, green: 0.52, blue: 0.18),
                Color(red: 0.72, green: 0.24, blue: 0.08),
                Color(red: 0.96, green: 0.54, blue: 0.20)
            )
        case .strained:
            return (
                Color(red: 1.0, green: 0.72, blue: 0.68),
                Color(red: 0.92, green: 0.26, blue: 0.26),
                Color(red: 0.56, green: 0.08, blue: 0.12),
                Color(red: 0.94, green: 0.28, blue: 0.28)
            )
        case .unknown:
            return (
                Color(white: 0.75),
                Color(white: 0.42),
                Color(white: 0.24),
                Color(white: 0.45)
            )
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(colors.glow.opacity(allowsMotion && pulse ? 0.34 : 0.22))
                .blur(radius: 10)
                .scaleEffect(allowsMotion && pulse ? 1.06 : 0.96)

            Circle()
                .fill(RadialGradient(
                    colors: [colors.core, colors.mid, colors.rim],
                    center: UnitPoint(x: 0.38, y: 0.36),
                    startRadius: 4,
                    endRadius: 40
                ))
                .overlay {
                    // 细微表面日冕纹斑，增加真实天体球质感。
                    Circle()
                        .fill(RadialGradient(
                            colors: [colors.core.opacity(0.45), .clear],
                            center: UnitPoint(x: 0.65, y: 0.68),
                            startRadius: 1,
                            endRadius: 24
                        ))
                }
                .overlay {
                    Circle()
                        .stroke(colors.core.opacity(0.35), lineWidth: 0.8)
                }
        }
        .padding(4)
        .onAppear {
            guard allowsMotion else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: allowsMotion) { _, active in
            if active {
                withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    pulse = false
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - CPU 逐核胶囊柱图

private struct MiniCoreBarStrip: View {
    let cores: [CoreCPUReading]
    let tint: Color
    let allowsMotion: Bool

    var body: some View {
        let displayCount = cores.isEmpty ? ProcessInfo.processInfo.activeProcessorCount : cores.count
        HStack(alignment: .bottom, spacing: 3) {
            if cores.isEmpty {
                ForEach(0..<max(1, displayCount), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 10)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(cores) { core in
                    let pct = core.percent ?? 0
                    GeometryReader { proxy in
                        let barHeight = max(6, proxy.size.height * CGFloat(min(100, max(0, pct)) / 100))
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [tint.opacity(0.75), tint],
                                    startPoint: .bottom,
                                    endPoint: .top
                                ))
                                .frame(height: core.percent == nil ? 4 : barHeight)
                                .opacity(core.percent == nil ? 0.35 : 1)
                                .animation(allowsMotion ? .easeOut(duration: 0.25) : nil, value: core.percent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .help("逻辑核心 \(core.id + 1)：\(core.percent.map { String(format: "%.1f%%", $0) } ?? "等待相邻采样")")
                }
            }
        }
    }
}

// MARK: - 通用迷你折线/面积图（GPU、内存、网络共用）

private struct OverviewSparkSample: Identifiable {
    let timestamp: Date
    let primary: Double?
    let secondary: Double?
    var id: Date { timestamp }
}

private struct OverviewSparklineView: View {
    let samples: [OverviewSparkSample]
    let ceiling: Double
    let primaryColor: Color
    var secondaryColor: Color? = nil
    let fillArea: Bool
    let unitFormatter: (Double) -> String

    @State private var hoverFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let validCount = samples.filter { $0.primary != nil }.count
            if validCount < 2 {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(MemoryStyle.line).frame(height: 1)
                    Text("等待连续采样…")
                        .font(.system(size: 10))
                        .foregroundStyle(MemoryStyle.secondary.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            } else {
                let hovered = hoverFraction.flatMap { nearestSample(at: $0) }
                Canvas { context, size in
                    let baselineY = size.height - 1
                    var basePath = Path()
                    basePath.move(to: CGPoint(x: 0, y: baselineY))
                    basePath.addLine(to: CGPoint(x: size.width, y: baselineY))
                    context.stroke(basePath, with: .color(Color.white.opacity(0.08)), lineWidth: 0.7)

                    guard let start = samples.first?.timestamp, let end = samples.last?.timestamp else { return }
                    let duration = max(1, end.timeIntervalSince(start))
                    let effectiveCeiling = max(1, ceiling)

                    if let secondaryColor {
                        let secondaryPath = buildLinePath(
                            size: size, start: start, duration: duration, ceiling: effectiveCeiling
                        ) { $0.secondary }
                        context.stroke(secondaryPath, with: .color(secondaryColor), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }

                    let primaryPath = buildLinePath(
                        size: size, start: start, duration: duration, ceiling: effectiveCeiling
                    ) { $0.primary }

                    if fillArea {
                        let areaPath = buildAreaPath(
                            size: size, start: start, duration: duration, ceiling: effectiveCeiling
                        ) { $0.primary }
                        context.fill(areaPath, with: .linearGradient(
                            Gradient(colors: [primaryColor.opacity(0.32), primaryColor.opacity(0.02)]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)
                        ))
                    }

                    context.stroke(primaryPath, with: .color(primaryColor), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))

                    if let hovered {
                        let x = hovered.timestamp.timeIntervalSince(start) / duration * size.width
                        var cursor = Path()
                        cursor.move(to: CGPoint(x: x, y: 0))
                        cursor.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(cursor, with: .color(MemoryStyle.secondary.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        if let val = hovered.primary {
                            let y = (1 - min(effectiveCeiling, max(0, val)) / effectiveCeiling) * (size.height - 4) + 2
                            context.fill(Path(ellipseIn: CGRect(x: x - 2.8, y: y - 2.8, width: 5.6, height: 5.6)), with: .color(primaryColor))
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if let hoverFraction, let hovered, let primaryVal = hovered.primary {
                        HStack(spacing: 5) {
                            Text(hovered.timestamp.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(MemoryStyle.secondary)
                            Text(unitFormatter(primaryVal))
                                .foregroundStyle(primaryColor)
                            if let secVal = hovered.secondary, secondaryColor != nil {
                                Text("↑\(unitFormatter(secVal))")
                                    .foregroundStyle(secondaryColor ?? MemoryStyle.secondary)
                            }
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.11, green: 0.12, blue: 0.13).opacity(0.95), in: RoundedRectangle(cornerRadius: 4))
                        .position(
                            x: min(max(62, proxy.size.width * hoverFraction), max(62, proxy.size.width - 62)),
                            y: 9
                        )
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverFraction = min(1, max(0, location.x / max(1, proxy.size.width)))
                    case .ended:
                        hoverFraction = nil
                    }
                }
            }
        }
    }

    private func buildLinePath(
        size: CGSize,
        start: Date,
        duration: TimeInterval,
        ceiling: Double,
        extractor: (OverviewSparkSample) -> Double?
    ) -> Path {
        var path = Path()
        var previous: Date?
        for sample in samples {
            guard let val = extractor(sample) else { previous = nil; continue }
            let x = sample.timestamp.timeIntervalSince(start) / duration * size.width
            let y = (1 - min(ceiling, max(0, val)) / ceiling) * (size.height - 4) + 2
            let point = CGPoint(x: x, y: y)
            if let last = previous, sample.timestamp.timeIntervalSince(last) <= 10 {
                path.addLine(to: point)
            } else {
                path.move(to: point)
            }
            previous = sample.timestamp
        }
        return path
    }

    private func buildAreaPath(
        size: CGSize,
        start: Date,
        duration: TimeInterval,
        ceiling: Double,
        extractor: (OverviewSparkSample) -> Double?
    ) -> Path {
        var area = Path()
        var segmentStart: CGPoint?
        var lastPoint: CGPoint?
        var previous: Date?

        func closeSegment() {
            if let first = segmentStart, let last = lastPoint {
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
            }
            segmentStart = nil
            lastPoint = nil
        }

        for sample in samples {
            guard let val = extractor(sample) else {
                closeSegment()
                previous = nil
                continue
            }
            let x = sample.timestamp.timeIntervalSince(start) / duration * size.width
            let y = (1 - min(ceiling, max(0, val)) / ceiling) * (size.height - 4) + 2
            let point = CGPoint(x: x, y: y)
            if let last = previous, sample.timestamp.timeIntervalSince(last) <= 10, segmentStart != nil {
                area.addLine(to: point)
            } else {
                closeSegment()
                area.move(to: point)
                segmentStart = point
            }
            lastPoint = point
            previous = sample.timestamp
        }
        closeSegment()
        return area
    }

    private func nearestSample(at fraction: Double) -> OverviewSparkSample? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let target = first.timestamp.addingTimeInterval(last.timestamp.timeIntervalSince(first.timestamp) * fraction)
        guard let point = samples.min(by: { abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target)) }),
              abs(point.timestamp.timeIntervalSince(target)) <= 10 else { return nil }
        return point
    }
}

// MARK: - 弹窗详情

private struct HealthDetailPopover: View {
    let health: MachineHealthEvaluation
    let assessment: LoadAssessment
    let chipName: String
    let onSelectCPU: () -> Void
    let onSelectMemory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("整机健康度评估").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !chipName.isEmpty {
                    Text(chipName).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                }
            }
            Text(assessment.detail)
                .font(.system(size: 12))
                .foregroundStyle(MemoryStyle.secondary)
                .lineSpacing(4)

            if health.factors.isEmpty {
                Label("所有核心指标运行在健康区间（100 分）", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(MemoryStyle.mint)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("扣分明细").font(.system(size: 12, weight: .medium))
                    ForEach(health.factors) { factor in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(factor.label).font(.system(size: 12, weight: .medium))
                                Text(factor.note).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                            }
                            Spacer()
                            Text("-\(factor.deduction)").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange).monospacedDigit()
                        }
                    }
                }
            }

            Text(assessment.advice)
                .font(.system(size: 12))
                .lineSpacing(4)

            HStack(spacing: 18) {
                Button("查看 CPU 详情", action: onSelectCPU)
                Button("查看内存详情", action: onSelectMemory)
            }
            .font(.system(size: 12))
            .foregroundStyle(MemoryStyle.mint)
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct BatteryDetailPopover: View {
    let battery: BatterySnapshot?
    let topApps: [AppMemoryUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("电源与能耗详情").font(.system(size: 15, weight: .semibold))
            if let battery {
                VStack(alignment: .leading, spacing: 6) {
                    detailRow("状态", battery.statusText)
                    detailRow("当前电量", battery.percent.map { "\($0)%" } ?? "—")
                    detailRow("电池健康度", battery.healthPercent.map { "\($0)%" } ?? "—")
                    detailRow("循环计数", battery.cycleCount.map { "\($0) 次" } ?? "—")
                    if let maxCap = battery.maxCapacityMah, let design = battery.designCapacityMah {
                        detailRow("满充 / 设计容量", "\(maxCap) / \(design) mAh")
                    }
                    if let adapterWatts = battery.adapterWatts, battery.isExternalConnected {
                        detailRow("电源适配器额定", "\(adapterWatts) W")
                    }
                    if let systemWatts = battery.systemPowerWatts {
                        detailRow("整机实时功耗", String(format: "%.1f W", systemWatts))
                    } else if let dischargeWatts = battery.batteryDischargeWatts {
                        detailRow("电池放电功率", String(format: "%.1f W", dischargeWatts))
                    }
                }
            } else {
                Text("当前设备未检测到内置电池，使用外接交流供电。")
                    .font(.system(size: 12))
                    .foregroundStyle(MemoryStyle.secondary)
            }

            if !topApps.isEmpty {
                Rectangle().fill(MemoryStyle.line).frame(height: 1)
                Text("当前活跃能耗参考（按 CPU 占用）").font(.system(size: 12, weight: .medium))
                ForEach(topApps) { app in
                    HStack {
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(app.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(MemoryStyle.secondary)
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(MemoryStyle.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}
