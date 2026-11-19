import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case machine = "整机"
    case memory = "内存"
    case cpu = "CPU"
    var id: String { rawValue }
}

struct MachineLoadView: View {
    @EnvironmentObject private var monitor: MemoryMonitor
    @Binding var section: DashboardSection
    @State private var query = ""
    @State private var ascending = false
    @State private var showsProcesses = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var load: MachineLoadSnapshot { monitor.load }
    private var stale: Bool { monitor.lastError != nil }
    private var assessment: LoadAssessment {
        .evaluate(load: load, memory: monitor.snapshot, apps: monitor.apps, history: monitor.loadHistory, stale: stale)
    }
    private var cpuApps: [AppMemoryUsage] {
        monitor.apps.sorted {
            let a = $0.cpuPercent ?? -1, b = $1.cpuPercent ?? -1
            return a == b ? $0.name < $1.name : a > b
        }
    }
    private var filteredApps: [AppMemoryUsage] {
        let values = cpuApps.filter { app in
            query.isEmpty || app.name.localizedCaseInsensitiveContains(query) || app.command.localizedCaseInsensitiveContains(query)
                || app.processes.contains { String($0.pid) == query || $0.service?.name.localizedCaseInsensitiveContains(query) == true
                    || $0.service?.entryPoint?.localizedCaseInsensitiveContains(query) == true }
        }
        return ascending ? values.reversed() : values
    }
    private var tint: Color {
        switch assessment.level {
        case .normal: MemoryStyle.mint
        case .watch: .orange
        case .high: .red
        case .unknown: MemoryStyle.secondary
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let detailsWidth: CGFloat = geometry.size.width < 1180 ? 295 : 350
            if section == .machine {
                overview(availableWidth: geometry.size.width)
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 28) {
                        cpuSummary.frame(maxWidth: .infinity, alignment: .leading)
                        ThermalSummaryView(load: load, stale: stale, compact: true)
                            .frame(width: detailsWidth).padding(.leading, 28)
                            .overlay(alignment: .leading) { divider.frame(width: 1) }
                    }.padding(.vertical, 16)
                    divider.frame(height: 1)
                    HStack(alignment: .top, spacing: 28) {
                        cpuList.frame(maxWidth: .infinity, maxHeight: .infinity)
                        cpuDetails.frame(width: detailsWidth).padding(.leading, 28)
                            .overlay(alignment: .leading) { divider.frame(width: 1) }
                    }.padding(.top, 20)
                }
            }
        }
        .sheet(isPresented: $showsProcesses) {
            CPUProcessSheet(monitor: monitor).focusEffectDisabled()
        }
    }

    private var divider: some View { Rectangle().fill(MemoryStyle.line) }

    private func overview(availableWidth: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MachineOverviewGridView(section: $section, availableWidth: availableWidth)
                HStack(alignment: .top, spacing: 28) {
                    ranking(title: "CPU 主要占用", apps: Array(cpuApps.filter { $0.cpuPercent != nil }.prefix(5)), cpu: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ranking(title: "内存主要占用", apps: Array(monitor.apps.prefix(5)), cpu: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.top, 18).padding(.bottom, 12)
        }
    }

    private func ranking(title: String, apps: [AppMemoryUsage], cpu: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 19, weight: .medium))
                Spacer()
                Button(cpu ? "查看 CPU →" : "查看内存 →") { section = cpu ? .cpu : .memory }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(MemoryStyle.mint)
            }
            if apps.isEmpty {
                Text("正在积累相邻采样…").font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary).padding(.vertical, 24)
            }
            ForEach(apps) { app in
                Button {
                    monitor.selectedAppID = app.pid
                    section = cpu ? .cpu : .memory
                } label: {
                    HStack(spacing: 12) {
                        NativeMemoryIcon(command: app.command, size: 28)
                        Text(app.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(cpu ? appCPUText(app) : app.memoryBytes.binaryBytesText).monospacedDigit().fontWeight(.medium)
                    }.font(.system(size: 13)).padding(.horizontal, 10).frame(height: 46)
                        .background(MemoryStyle.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(TelemetryButtonStyle())
            }
        }
    }

    private var cpuSummary: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CPU 使用率").font(.system(size: 18, weight: .medium))
                    Spacer()
                    Text("\(ProcessInfo.processInfo.activeProcessorCount) 个逻辑核心")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
                HStack(spacing: 12) {
                    TelemetryRing(fraction: load.cpuPercent.map { $0 / 100 }, secondaryFraction: (load.cpuSystem ?? 0) / 100)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cpuText(load.cpuPercent)).font(.system(size: 40, weight: .semibold)).tracking(-1).monospacedDigit()
                            .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: load.cpuPercent)
                        Text(stale ? "上次成功采样" : "100% 为整机容量")
                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                    }
                }
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        MemoryStyle.mint.frame(width: proxy.size.width * (load.cpuUser ?? 0) / 100)
                        Color(red: 0.51, green: 0.62, blue: 0.73).frame(width: proxy.size.width * (load.cpuSystem ?? 0) / 100)
                        Spacer(minLength: 0)
                    }
                }.frame(height: 6).background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 3))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: load.cpuPercent)
                HStack(spacing: 12) {
                    Text("用户 \(cpuText(load.cpuUser))")
                    Text("系统 \(cpuText(load.cpuSystem))")
                    Text("空闲 \(cpuText(load.cpuPercent.map { max(0, 100 - $0) }))")
                }.font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).monospacedDigit()
                Text(assessment.title).font(.system(size: 11)).foregroundStyle(tint)
            }.frame(width: 260, alignment: .leading)
            LoadTrendView(history: monitor.loadHistory, appKey: nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cpuList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("应用").font(.system(size: 23, weight: .medium))
                Button { ascending.toggle() } label: {
                    Label("按 CPU 排序", systemImage: ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                }.buttonStyle(.plain).accessibilityLabel("切换 CPU 排序")
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    TextField("搜索应用、服务或 PID", text: $query).textFieldStyle(.plain).accessibilityLabel("搜索 CPU 应用")
                }.font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                    .padding(.horizontal, 10).frame(width: 205, height: 32)
                    .background(MemoryStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("整机 CPU 占比").frame(width: 100, alignment: .trailing)
                Text("进程").frame(width: 55, alignment: .trailing)
            }.font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredApps) { app in
                        Button { monitor.selectedAppID = app.pid } label: {
                            HStack(spacing: 10) {
                                NativeMemoryIcon(command: app.command, size: 30)
                                Text(app.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                Text(appCPUText(app)).fontWeight(.medium).frame(width: 100, alignment: .trailing)
                                Text("\(app.processCount)").foregroundStyle(MemoryStyle.secondary).frame(width: 55, alignment: .trailing)
                            }.font(.system(size: 13)).monospacedDigit().padding(.horizontal, 12).frame(height: 54)
                                .background(monitor.selectedApp?.id == app.id ? MemoryStyle.mint.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .leading) {
                                    if monitor.selectedApp?.id == app.id { RoundedRectangle(cornerRadius: 2).fill(MemoryStyle.mint).frame(width: 3).padding(.vertical, 10) }
                                }.contentShape(Rectangle())
                        }.buttonStyle(TelemetryButtonStyle()).accessibilityLabel("选择 CPU 应用 \(app.name)，\(appCPUText(app))")
                    }
                }
            }.overlay {
                if filteredApps.isEmpty { Text("没有匹配的应用").foregroundStyle(MemoryStyle.secondary).font(.system(size: 13)) }
            }
            Text("100% 表示整机容量 · ≥ 为可读部分 · — 为等待差分或读取受限 · \(filteredApps.count) 组")
                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
        }
    }

    private var cpuDetails: some View {
        ScrollView {
            if let app = monitor.selectedApp {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        NativeMemoryIcon(command: app.command, size: 42)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.name).font(.system(size: 18, weight: .medium)).lineLimit(2)
                            Text("\(app.processCount) 个进程 · 含已归因服务").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(appCPUText(app)).font(.system(size: 36, weight: .semibold)).monospacedDigit()
                        Text(app.cpuIsPartial ? "仅可读部分；首次差分或权限受限" : "占整机 CPU 容量")
                            .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                    }
                    LoadTrendView(history: monitor.loadHistory, appKey: app.cpuHistoryKey)
                    divider.frame(height: 1)
                    Text("主要子进程").font(.system(size: 15, weight: .medium))
                    ForEach(app.processes.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }.prefix(5)) { process in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(process.service?.name ?? process.name).lineLimit(1)
                                Text("PID \(process.pid)").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(cpuText(process.cpuPercent)).monospacedDigit()
                        }.font(.system(size: 12))
                    }
                    Button("查看全部进程与服务") { showsProcesses = true }.buttonStyle(.bordered).tint(MemoryStyle.mint)
                    Text("建议在原应用中暂停不急的任务。CPU 占用不代表故障，也不能单凭占用定位具体业务原因。")
                        .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary).lineSpacing(4)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private func temperatureText(_ value: Double?) -> String { value.map { String(format: "%.1f°C", $0) } ?? "—" }
private func appCPUText(_ app: AppMemoryUsage) -> String { (app.cpuIsPartial && app.cpuPercent != nil ? "≥ " : "") + cpuText(app.cpuPercent) }

private struct ThermalSummaryView: View {
    let load: MachineLoadSnapshot
    let stale: Bool
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack {
                Text("散热").font(.system(size: 16, weight: .medium))
                Spacer()
                Text(load.thermalState.rawValue).font(.system(size: 11))
                    .foregroundStyle(load.thermalState.visualTint)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(temperatureText(load.sensors.hottest)).font(.system(size: compact ? 24 : 28, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: load.sensors.hottest)
                Text("CPU 温区最高").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            }
            if let issue = load.sensors.temperatureIssue {
                Text(issue).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            } else {
                Text("温区范围 \(temperatureText(load.sensors.coolest)) – \(temperatureText(load.sensors.hottest))")
                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            }
            if !compact {
                TemperatureTrack(low: load.sensors.coolest, high: load.sensors.hottest, tint: load.thermalState.visualTint)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                ForEach(load.sensors.fans) { fan in
                    HStack(spacing: compact ? 8 : 10) {
                        FanRotorView(rpm: fan.rpm, stale: stale).frame(width: compact ? 34 : 46, height: compact ? 34 : 46)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text("风扇 \(fan.id + 1)")
                                if let fraction = fan.speedFraction {
                                    Text(String(format: "%.0f%%", fraction * 100)).foregroundStyle(MemoryStyle.mint)
                                }
                            }.font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(fan.rpm.map { String(format: "%.0f", $0) } ?? "—")
                                    .font(.system(size: compact ? 16 : 20, weight: .medium)).monospacedDigit()
                                    .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fan.rpm)
                                Text(fan.rpm == nil ? "未读取" : fan.rpm == 0 ? "已停转" : "RPM")
                                    .font(.system(size: 8)).foregroundStyle(MemoryStyle.secondary)
                            }
                            Text(fan.maximumRPM.map { "上限 \(Int($0).formatted()) RPM" } ?? "上限未读取")
                                .font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .help("当前转速为实测，上限由硬件 SMC 报告，百分比为当前/上限；图形快慢仅为示意，减少动态效果或窗口在后台时静止")
                }
            }.padding(.vertical, compact ? 0 : 5)
            if load.sensors.fans.isEmpty {
                Text(load.sensors.fanSummary).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            }
            HStack {
                Text(load.sensors.timestamp.map { "\(stale ? "上次" : "传感器") \($0.formatted(date: .omitted, time: .standard))" } ?? "等待采样")
                Spacer()
                Button("测量说明") { expanded.toggle() }.buttonStyle(.plain).foregroundStyle(MemoryStyle.mint)
                    .popover(isPresented: $expanded) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("只读传感器").font(.headline)
                                Text("前台每 10 秒采样；后台暂停传感器读取，风扇由系统调节。温区是传感器位置，不逐一对应核心；最高读数不代表系统过热。")
                                    .font(.system(size: 12)).lineSpacing(3)
                                Text("风扇硬件上限").font(.headline)
                                Text("最大转速读取自 SMC 的 F{n}Mx，并缓存到本次运行结束；它是硬件报告的上限，不是历史峰值，也不代表需要手动调到此转速。未读取时显示未知。")
                                    .font(.system(size: 12)).lineSpacing(3)
                                ForEach(load.sensors.fans) { fan in
                                    HStack {
                                        Text("风扇 \(fan.id + 1) · F\(fan.id)Mx")
                                        Spacer()
                                        Text(fan.maximumRPM.map { "\(Int($0).formatted()) RPM" } ?? "未知")
                                    }.font(.system(size: 11)).monospacedDigit()
                                }
                                Text("CPU 温区读数").font(.headline)
                                ForEach(load.sensors.temperatures) { value in
                                    HStack { Text(value.id); Spacer(); Text(temperatureText(value.celsius)) }
                                        .font(.system(size: 11)).monospacedDigit()
                                }
                            }.padding(20)
                        }.frame(width: 320, height: 340)
                    }
            }.font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)

        }
    }
}

struct LoadTrendView: View {
    let history: [LoadHistoryPoint]
    let appKey: String?
    private func value(_ point: LoadHistoryPoint) -> Double? { PlotSamples.value(point, appKey: appKey) }
    private var valid: [LoadHistoryPoint] { history.filter { value($0) != nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(appKey == nil ? "整机 · 最近 5 分钟" : "CPU · 最近 5 分钟").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("整机占比").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }
            if valid.count < 2 {
                Text("正在积累真实采样…").font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                HStack(spacing: 6) {
                    VStack { Text("\(Int(PlotSamples.ceiling(history: history, appKey: appKey)))%"); Spacer(); Text("0%") }
                        .font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary).frame(width: 30)
                    InteractiveLoadPlot(history: history, appKey: appKey, ceiling: PlotSamples.ceiling(history: history, appKey: appKey))
                }.frame(height: 100)
                HStack {
                    Text(valid.first!.timestamp.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    Text("已采样 \(Int(valid.last!.timestamp.timeIntervalSince(valid.first!.timestamp))) 秒")
                }.font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }
        }
    }
}

private struct CPUProcessSheet: View {
    @ObservedObject var monitor: MemoryMonitor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(monitor.selectedApp?.name ?? "应用") · CPU 进程").font(.system(size: 21, weight: .medium))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("随采样更新 · 100% 为整机 CPU 容量 · — 为等待差分或读取受限")
                .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach((monitor.selectedApp?.processes ?? []).sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }) { process in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(process.name).font(.system(size: 13, weight: .medium))
                                if let service = process.service {
                                    Text("服务：\(service.name)").foregroundStyle(MemoryStyle.mint)
                                    if let entry = service.entryPoint { Text(entry).textSelection(.enabled) }
                                }
                                Text(process.command).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                                Text("PID \(process.pid) / 父 PID \(process.parentPid)").foregroundStyle(MemoryStyle.secondary)
                            }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(cpuText(process.cpuPercent)).font(.system(size: 15, weight: .medium)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        Rectangle().fill(MemoryStyle.line).frame(height: 1)
                    }
                }
            }
        }.padding(28).frame(minWidth: 760, minHeight: 520)
            .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).preferredColorScheme(.dark)
    }
}
