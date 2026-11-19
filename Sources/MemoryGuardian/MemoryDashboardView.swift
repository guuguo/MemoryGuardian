import SwiftUI
import AppKit

enum MemoryStyle {
    static let background = Color(red: 0.094, green: 0.102, blue: 0.110)
    static let surface = Color(red: 0.135, green: 0.149, blue: 0.157)
    static let text = Color(red: 0.925, green: 0.929, blue: 0.914)
    static let secondary = Color(red: 0.61, green: 0.64, blue: 0.68)
    static let mint = Color(red: 0.65, green: 0.85, blue: 0.76)
    static let line = Color.white.opacity(0.09)
}

struct DashboardView: View {
    @EnvironmentObject private var monitor: MemoryMonitor
    @State private var query = ""
    @State private var ascending = false
    @State private var processApp: AppMemoryUsage?
    @State private var confirmsQuit = false
    @State private var showsInfo = false
    @State private var toolsApp: AppMemoryUsage?
    @State private var section: DashboardSection = .machine
    @Namespace private var navigationMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: MemorySnapshot { monitor.snapshot }
    private var loaded: Bool { snapshot.totalBytes > 0 }
    private var effectivePressure: MemoryPressure { monitor.lastError == nil ? snapshot.pressure : .unknown }
    private var pressureColor: Color {
        switch effectivePressure {
        case .normal: MemoryStyle.mint
        case .medium: .orange
        case .high: .red
        case .unknown: MemoryStyle.secondary
        }
    }
    private var statusText: String {
        guard loaded else { return monitor.lastError ?? "正在读取本机内存…" }
        switch effectivePressure {
        case .normal: return "内存运行良好，暂时无需处理。"
        case .medium: return "内存开始承压，可关闭不再使用的窗口。"
        case .high: return "系统内存紧张，请先保存工作，再关闭闲置应用。"
        case .unknown: return "系统压力未知，请结合实际占用与交换速率判断。"
        }
    }
    private var visibleApps: [AppMemoryUsage] {
        let filtered = monitor.apps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.command.localizedCaseInsensitiveContains(query)
                || $0.processes.contains { String($0.pid) == query || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.service?.name.localizedCaseInsensitiveContains(query) == true
                    || $0.service?.entryPoint?.localizedCaseInsensitiveContains(query) == true }
        }
        return ascending ? filtered.sorted { $0.memoryBytes < $1.memoryBytes } : filtered
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1250
            let inset: CGFloat = compact ? 24 : 36
            let detailsWidth: CGFloat = compact ? 295 : 350
            VStack(spacing: 0) {
                topBar
                if section != .memory {
                    MachineLoadView(section: $section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                HStack(alignment: .top, spacing: 28) {
                    memorySummary(compact: compact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    swapSummary
                        .frame(width: detailsWidth, alignment: .leading)
                }
                .padding(.vertical, compact ? 24 : 30)
                Rectangle().fill(MemoryStyle.line).frame(height: 1)
                HStack(alignment: .top, spacing: 28) {
                    appList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    appDetails
                        .frame(width: detailsWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.top, 22)
                }
                footer.padding(.vertical, 12)
            }
            .padding(.horizontal, inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MemoryStyle.background)
            .foregroundStyle(MemoryStyle.text)
            .font(.system(size: 14))
        }
        .preferredColorScheme(.dark)
        .sheet(item: $processApp) { app in NativeProcessSheet(app: app).focusEffectDisabled() }
        .sheet(item: $toolsApp) { app in CodexToolsView(application: app).environmentObject(monitor) }
        .alert("正常退出 \(monitor.selectedApp?.name ?? "应用")？", isPresented: $confirmsQuit) {
            Button("取消", role: .cancel) {}
            Button("请求正常退出") { monitor.requestQuitSelectedApp() }
        } message: {
            Text("请先保存工作。应用可能显示保存提示；不会强制终止其子进程。")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 65)
            Image(systemName: "memorychip").font(.system(size: 21, weight: .light)).foregroundStyle(MemoryStyle.mint)
            Text("内存守卫").font(.system(size: 16, weight: .medium))
            HStack(spacing: 4) {
                ForEach(DashboardSection.allCases) { item in
                    Button { section = item } label: {
                        Text(item.rawValue).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(section == item ? MemoryStyle.mint : MemoryStyle.secondary)
                            .padding(.horizontal, 16).frame(height: 32)
                            .background(section == item ? MemoryStyle.mint.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(alignment: .bottom) {
                                if section == item { Rectangle().fill(MemoryStyle.mint).frame(height: 2).padding(.horizontal, 16)
                                        .matchedGeometryEffect(id: "navigation-selection", in: navigationMotion) }
                            }
                    }.buttonStyle(TelemetryButtonStyle()).accessibilityLabel("切换到\(item.rawValue)")
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }.padding(.leading, 16)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: section)
            Spacer()
            Text(loaded ? "采样于 \(snapshot.timestamp.formatted(date: .omitted, time: .standard))" : "正在采样")
                .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
            Button { Task { await monitor.refresh() } } label: {
                Image(systemName: monitor.isRefreshing ? "hourglass" : "arrow.clockwise").font(.system(size: 17, weight: .light)).frame(width: 30, height: 30)
            }
            .buttonStyle(TelemetryButtonStyle())
            .disabled(monitor.isRefreshing).help("刷新本机数据").accessibilityLabel("刷新本机数据")
            Button { showsInfo.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 17, weight: .light)).frame(width: 30, height: 30) }
                .buttonStyle(TelemetryButtonStyle())
                .help("数据口径与采样说明").accessibilityLabel("数据口径与采样说明")
                .popover(isPresented: $showsInfo) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("数据口径").font(.headline)
                        Text("容量使用二进制单位：1 GiB = 1024 MiB。\n物理分类来自系统 VM 页统计，压力来自系统状态。")
                        Text("应用优先读取 footprint，包含压缩内存。读取受限的整组以 RSS 常驻内存展示，并单独标注；两种口径不能直接相加。")
                        Text("前台正常每 5 秒采样，高压每 3 秒采样。后台、遮挡或收起窗口时，每 30 秒只更新系统内存摘要，暂停进程与传感器采集；睡眠时停止，回到前台立即刷新。趋势仅保留本次运行的最近 5 分钟，暂停期间不补数据。")
                        Text("缓存由系统按需回收。Swap 位于启动盘，不计入物理内存容量。")
                        Text("CPU 由相邻累计时间计算，100% 表示整机容量；应用包含已归因后台服务，≥ 表示只读到部分进程。CPU 温度为已识别温区最高值，风扇每 10 秒读取；热状态来自系统。本地规则生成汇总，不上传数据，不控制风扇。")
                        Text("GPU、电池、存储与网络速率分别读取自 IOKit 与系统接口统计；磁盘容量使用 10 进制 GB 与访达对齐，读写及网络速率在连续采样后展示。")
                    }.font(.system(size: 13)).padding(24).frame(width: 360)
                }
        }
        .buttonStyle(.plain)
        .frame(height: 54)
        .overlay(alignment: .bottom) { Rectangle().fill(MemoryStyle.line).frame(height: 1) }
    }

    private func memorySummary(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                Text("内存状态").font(.system(size: 24, weight: .medium))
                HStack(spacing: 7) {
                    Circle().fill(pressureColor).frame(width: 8, height: 8)
                    Text(effectivePressure.rawValue).font(.system(size: 13, weight: .medium)).foregroundStyle(pressureColor)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(loaded ? String(format: "%.1f", Double(snapshot.usedBytes) / 1_073_741_824) : "—")
                    .font(.system(size: compact ? 52 : 62, weight: .semibold)).tracking(-1.5)
                    .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: snapshot.usedBytes)
                Text(loaded ? "/ \(String(format: "%.0f", Double(snapshot.totalBytes) / 1_073_741_824)) GiB" : "/ — GiB")
                    .font(.system(size: compact ? 25 : 31, weight: .medium)).foregroundStyle(MemoryStyle.secondary)
                Spacer(minLength: 8)
                Text(loaded ? "已用 \(share(snapshot.usedBytes))" : "")
                    .font(.system(size: compact ? 15 : 18)).padding(.trailing, 4)
            }
            .monospacedDigit()
            Text(statusText).foregroundStyle(MemoryStyle.secondary).font(.system(size: 14))
            capacityBar.frame(height: 13).padding(.top, 2)
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Circle().fill(segment.color).frame(width: 8, height: 8)
                            Text(segment.name).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                        }
                        Text(loaded ? segment.bytes.binaryBytesText : "—")
                            .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var segments: [(name: String, bytes: UInt64, color: Color)] {
        var values: [(String, UInt64, Color)] = [
            ("应用", snapshot.appBytes, MemoryStyle.mint),
            ("系统常驻", snapshot.wiredBytes, Color(red: 0.51, green: 0.62, blue: 0.73)),
            ("压缩", snapshot.compressedBytes, Color(red: 0.71, green: 0.61, blue: 0.84)),
            ("缓存", snapshot.cachedBytes, Color(red: 0.40, green: 0.42, blue: 0.47)),
            ("空闲", snapshot.freeBytes, Color(red: 0.24, green: 0.27, blue: 0.30))
        ]
        if snapshot.unclassifiedBytes > 0 { values.append(("其他物理页", snapshot.unclassifiedBytes, .gray)) }
        return values
    }

    private var capacityBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segment.color.frame(width: loaded ? geometry.size.width * Double(segment.bytes) / Double(snapshot.totalBytes) : 0)
                        .help("\(segment.name)：\(segment.bytes.binaryBytesText)")
                }
            }
        }
        .background(MemoryStyle.surface)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: snapshot.usedBytes)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("物理内存组成")
    }

    private var swapSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("交换空间").font(.system(size: 19, weight: .medium))
            Text(snapshot.swapTotalBytes != nil ? snapshot.swapUsedBytes.binaryBytesText : "—")
                .font(.system(size: 34, weight: .semibold)).monospacedDigit()
            Text(swapCaption).font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) { Text("换入"); Text(rate(snapshot.swapInBytesPerSecond)).foregroundStyle(MemoryStyle.text) }
                VStack(alignment: .leading, spacing: 5) { Text("换出"); Text(rate(snapshot.swapOutBytesPerSecond)).foregroundStyle(MemoryStyle.text) }
            }.font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary).monospacedDigit()
            Text("启动盘可用  \(snapshot.startupDiskAvailableBytes?.binaryBytesText ?? "未获取")")
                .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 28)
        .overlay(alignment: .leading) { Rectangle().fill(MemoryStyle.line).frame(width: 1) }
    }

    private var swapCaption: String {
        guard loaded else { return "等待系统数据" }
        guard let total = snapshot.swapTotalBytes else { return "交换空间读取失败" }
        return total == 0 ? "尚未分配 · 系统动态分配" : "已分配 \(total.binaryBytesText) · 系统动态分配"
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("应用").font(.system(size: 24, weight: .medium))
                Button { ascending.toggle() } label: {
                    HStack(spacing: 5) { Text("按内存影响排序"); Image(systemName: ascending ? "arrow.up" : "arrow.down") }
                        .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                }.buttonStyle(.plain).accessibilityLabel("切换内存排序")
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(MemoryStyle.secondary)
                    TextField("搜索应用、路径或 PID", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                        .accessibilityLabel("搜索应用")
                }
                .padding(.horizontal, 11).frame(width: 205, height: 32)
                .background(MemoryStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            }
            HStack {
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("内存影响").frame(width: 110, alignment: .trailing)
                Text("相当于物理容量").frame(width: 108, alignment: .trailing)
                Text("进程").frame(width: 52, alignment: .trailing)
                Spacer().frame(width: 16)
            }.font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(visibleApps) { app in
                        Button { monitor.selectedAppID = app.pid } label: { appRow(app) }
                            .buttonStyle(TelemetryButtonStyle())
                            .accessibilityLabel("选择 \(app.name)，\(app.memoryBytes.binaryBytesText)")
                    }
                }
            }
            .overlay {
                if visibleApps.isEmpty {
                    Text(!loaded ? (monitor.lastError ?? "正在读取应用列表…") : query.isEmpty ? "暂无可读取的应用" : "没有匹配的应用")
                        .foregroundStyle(MemoryStyle.secondary)
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text("footprint 包含压缩内存；受限组标注 RSS，不能直接相加为物理分区。")
                Spacer(minLength: 4)
                Text("\(visibleApps.count) / \(monitor.apps.count) 组").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
        }
    }

    private func appRow(_ app: AppMemoryUsage) -> some View {
        let selected = monitor.selectedApp?.id == app.id
        return HStack(spacing: 10) {
            NativeMemoryIcon(command: app.command, size: 30)
            Text(app.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(app.memoryBytes.binaryBytesText)
                if !app.usesFootprint { Text("RSS · 读取受限").font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary) }
            }.frame(width: 100, alignment: .trailing)
            Text(share(app.memoryBytes)).frame(width: 98, alignment: .trailing)
            Text("\(app.processCount)").foregroundStyle(MemoryStyle.secondary).frame(width: 42, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).frame(width: 8)
        }
        .font(.system(size: 13)).monospacedDigit()
        .padding(.horizontal, 12).frame(height: 53)
        .background(selected ? Color.white.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 2).fill(MemoryStyle.mint).frame(width: 3).padding(.vertical, 6) }
        }
        .overlay(alignment: .bottom) { if !selected { Rectangle().fill(MemoryStyle.line.opacity(0.5)).frame(height: 1).padding(.horizontal, 12) } }
        .contentShape(Rectangle()).help(app.command)
    }

    private var appDetails: some View {
        ScrollView {
            if let app = monitor.selectedApp {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        NativeMemoryIcon(command: app.command, size: 48)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.name).font(.system(size: 19, weight: .medium)).lineLimit(2)
                            Text("\(app.processCount) 个进程 · \(app.processes.filter { $0.service != nil }.count) 个服务进程")
                                .foregroundStyle(MemoryStyle.secondary).font(.system(size: 12))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.memoryBytes.binaryBytesText).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                        Text("相当于物理容量 \(share(app.memoryBytes)) · \(app.usesFootprint ? "footprint" : "RSS · 读取受限")")
                            .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                    }
                    if CodexToolMemoryScope.supports(app) { appToolsEntry(app) }
                    NativeMemoryHistory(history: monitor.history, app: app)
                    Rectangle().fill(MemoryStyle.line).frame(height: 1)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("建议").font(.system(size: 15, weight: .medium))
                        Text(statusText).font(.system(size: 13))
                        Text(app.applicationURL == nil ? "未确认原应用，请查看入口脚本与启动链，在原工具中停止闲置任务。" : "占用包含已归因的后台服务。如需释放内存，可先保存工作，再关闭闲置窗口。")
                            .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary).lineSpacing(4)
                    }
                    HStack(spacing: 20) {
                        Button("查看进程") { processApp = app }
                            .buttonStyle(.bordered).tint(MemoryStyle.mint).accessibilityLabel("查看选中应用进程")
                        Button("正常退出") { confirmsQuit = true }
                            .buttonStyle(.plain).foregroundStyle(MemoryStyle.secondary)
                            .disabled(monitor.runningApplication(for: app) == nil)
                            .help("通过 macOS 请求应用正常退出；后台服务请在原工具中停止")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("选择应用查看详情").foregroundStyle(MemoryStyle.secondary).padding(.top, 30)
            }
        }
        .padding(.leading, 28)
        .overlay(alignment: .leading) { Rectangle().fill(MemoryStyle.line).frame(width: 1) }
    }

    private func appToolsEntry(_ app: AppMemoryUsage) -> some View {
        let scope = CodexToolMemoryScope(application: app, applicationKey: CodexToolMemoryScope.key(for: app), assessments: monitor.codexTools)
        return Button { toolsApp = app } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Codex 工具与回收", systemImage: "terminal").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }.foregroundStyle(MemoryStyle.mint)
                Text("其中工具 \(scope.toolBytes.binaryBytesText) · \(scope.included.count) 个进程")
                    .font(.system(size: 12)).monospacedDigit()
                Text("已计入上方总占用 · 其余进程 \((scope.otherBytes ?? 0).binaryBytesText)")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(MemoryStyle.surface, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(TelemetryButtonStyle()).accessibilityLabel("查看 \(app.name) 的 Codex 工具与回收")
            .accessibilityValue("其中工具 \(scope.toolBytes.binaryBytesText)，已计入应用总占用 \(app.memoryBytes.binaryBytesText)；其余进程 \((scope.otherBytes ?? 0).binaryBytesText)")
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 10) {
            if let error = monitor.lastError {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text("\(error) · 当前显示上次成功采样").foregroundStyle(.orange)
            } else if let observation = monitor.quitObservation {
                let current = monitor.apps.first { $0.historyKey == observation.key }
                Text("\(observation.name) 退出请求前 \(observation.beforeBytes.binaryBytesText) · 当前 \(current?.memoryBytes.binaryBytesText ?? "已不在列表")；观测变化不等于释放量")
                    .foregroundStyle(MemoryStyle.secondary)
            } else if let message = monitor.lastActionMessage {
                Text(message).foregroundStyle(MemoryStyle.secondary)
            } else {
                Image(systemName: "checkmark.shield").foregroundStyle(MemoryStyle.secondary)
                Text("仅本机处理 · 缓存由系统按需回收").foregroundStyle(MemoryStyle.secondary)
            }
            Spacer(minLength: 10)
            Text(monitor.samplingDescription).foregroundStyle(MemoryStyle.secondary)
        }.font(.system(size: 10)).lineLimit(2)
    }

    private func share(_ bytes: UInt64) -> String {
        guard snapshot.totalBytes > 0 else { return "—" }
        return String(format: "%.1f%%", Double(bytes) / Double(snapshot.totalBytes) * 100)
    }

    private func rate(_ value: Double?) -> String {
        guard let value else { return "等待采样" }
        return "\(UInt64(max(0, value)).binaryBytesText)/s"
    }
}

struct NativeMemoryIcon: View {
    let command: String
    let size: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "terminal").resizable().scaledToFit().padding(size * 0.2).foregroundStyle(MemoryStyle.secondary) }
        }
        .frame(width: size, height: size)
        .task(id: command) {
            if let cached = AppIconCache.shared.get(command) { icon = cached; return }
            let resolved = await Task.detached(priority: .utility) { AppAssets.icon(forAppPathOrName: command) }.value
            if let resolved { AppIconCache.shared.set(command, image: resolved); icon = resolved }
        }
    }
}

private struct NativeMemoryHistory: View {
    let history: [MemoryHistoryPoint]
    let app: AppMemoryUsage
    private var points: [(date: Date, value: UInt64)] {
        history.compactMap { point in point.appBytes[app.historyKey].map { (point.timestamp, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近 5 分钟").font(.system(size: 13, weight: .medium))
                Spacer()
                if let first = points.first, let last = points.last {
                    Text("已采样 \(Int(last.date.timeIntervalSince(first.date))) 秒")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
            }
            if points.count < 2 {
                Text("正在积累该应用的真实采样…")
                    .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                chart.frame(height: 110)
                HStack {
                    Text(points.first!.date.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    Text(points.last!.date.formatted(date: .omitted, time: .shortened))
                }.font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }
        }
    }

    private var chart: some View {
        let low = Double(points.map(\.value).min() ?? 0) * 0.85
        let high = max(low + 1_048_576, Double(points.map(\.value).max() ?? 0) * 1.1)
        return HStack(spacing: 8) {
            VStack(alignment: .trailing) {
                Text(UInt64(high).binaryBytesText)
                Spacer()
                Text(UInt64(low).binaryBytesText)
            }.font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary).frame(width: 48)
            Canvas { context, size in
                var grid = Path()
                for fraction in [0.0, 0.5, 1.0] {
                    grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                    grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                }
                context.stroke(grid, with: .color(MemoryStyle.line), lineWidth: 0.5)
                guard let start = points.first?.date, let end = points.last?.date else { return }
                let duration = max(1, end.timeIntervalSince(start))
                var path = Path()
                for (index, point) in points.enumerated() {
                    let p = CGPoint(x: point.date.timeIntervalSince(start) / duration * size.width,
                                    y: (1 - (Double(point.value) - low) / (high - low)) * size.height)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(MemoryStyle.mint), lineWidth: 1.5)
            }
        }
    }
}

private struct NativeProcessSheet: View {
    let app: AppMemoryUsage
    @Environment(\.dismiss) private var dismiss
    private var services: [(id: String, name: String, bytes: UInt64, count: Int)] {
        Dictionary(grouping: app.processes.filter { $0.service != nil }, by: { $0.service!.identity })
            .map { key, processes in
                (id: key, name: processes[0].service!.name,
                 bytes: processes.reduce(UInt64(0)) { $0 + (app.usesFootprint ? ($1.footprintBytes ?? 0) : $1.memoryBytes) },
                 count: processes.count)
            }
            .sorted { $0.bytes > $1.bytes }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("\(app.name) · 进程快照").font(.system(size: 21, weight: .medium))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(app.processCount) 个进程 · footprint 为内存影响，RSS 为常驻内存；受权限限制时 footprint 显示 —。")
                .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !services.isEmpty {
                        Text("后台服务（已包含在总占用中）").font(.system(size: 15, weight: .medium))
                        ForEach(services, id: \.id) { service in
                            HStack {
                                Text(service.name).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(service.count) 个进程").foregroundStyle(MemoryStyle.secondary)
                                Text(service.bytes.binaryBytesText).frame(width: 110, alignment: .trailing).monospacedDigit()
                            }.font(.system(size: 13))
                        }
                        Rectangle().fill(MemoryStyle.line).frame(height: 1)
                    }
                    HStack {
                        Text("进程 / 归因依据").frame(maxWidth: .infinity, alignment: .leading)
                        Text("PID / 父 PID").frame(width: 110)
                        Text("footprint").frame(width: 105, alignment: .trailing)
                        Text("RSS").frame(width: 105, alignment: .trailing)
                    }.font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                    ForEach(app.processes) { process in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(process.name).font(.system(size: 13, weight: .medium))
                                if let service = process.service {
                                    Text("服务：\(service.name)").font(.system(size: 11)).foregroundStyle(MemoryStyle.mint)
                                    if let entry = service.entryPoint {
                                        Text("入口：\(entry)").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                                    }
                                }
                                Text(process.command).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                                if !process.parentChain.isEmpty {
                                    Text("启动链：\(process.parentChain.joined(separator: " ← "))")
                                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(process.pid) / \(process.parentPid)").frame(width: 110)
                            Text(process.footprintBytes?.binaryBytesText ?? "—").frame(width: 105, alignment: .trailing)
                            Text(process.memoryBytes.binaryBytesText).frame(width: 105, alignment: .trailing)
                        }.font(.system(size: 12)).monospacedDigit()
                        Rectangle().fill(MemoryStyle.line).frame(height: 1)
                    }
                }
            }
        }
        .padding(28).frame(minWidth: 800, minHeight: 520)
        .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).preferredColorScheme(.dark)
    }
}
