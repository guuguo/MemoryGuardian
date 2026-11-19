import SwiftUI

struct CodexToolsView: View {
    let application: AppMemoryUsage
    @EnvironmentObject private var monitor: MemoryMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter = 1
    @State private var selection: Set<CodexProcessIdentity> = []
    @State private var kernelSelection: Set<CodexProcessIdentity> = []
    @State private var confirmsCleanup = false

    private var memoryScope: CodexToolMemoryScope {
        let key = CodexToolMemoryScope.key(for: application)
        let current = monitor.apps.first { CodexToolMemoryScope.key(for: $0) == key }
        return CodexToolMemoryScope(application: current, applicationKey: key, assessments: monitor.codexTools)
    }
    private var tools: [CodexToolAssessment] { memoryScope.tools }
    private var ready: [CodexToolAssessment] { tools.filter(\.canClean) }
    private var selected: [CodexToolAssessment] { ready.filter { selection.contains($0.id) } }
    private var kernelMode: Bool { filter == 1 }
    private var kernels: [CodexKernelAssessment] {
        monitor.codexKernels.filter { $0.applicationKey == CodexToolMemoryScope.key(for: application) }
    }
    private var readyKernels: [CodexKernelAssessment] { kernels.filter(\.canReset) }
    private var selectedKernels: [CodexKernelAssessment] { readyKernels.filter { kernelSelection.contains($0.id) } }
    private var visibleKernels: [CodexKernelAssessment] {
        kernels.filter { query.isEmpty || $0.workingDirectory.localizedCaseInsensitiveContains(query) ||
            String($0.host.pid).contains(query) || $0.members.contains { String($0.pid).contains(query) } }
    }
    private var visibleReadyKernels: [CodexKernelAssessment] { visibleKernels.filter(\.canReset) }
    private var resetConfirmation: String {
        let entries = selectedKernels.prefix(3).map { "PID \($0.trusted.pid) · \($0.workingDirectory)" }.joined(separator: "\n")
        let more = selectedKernels.count > 3 ? "\n另有 \(selectedKernels.count - 3) 个所选内核" : ""
        return entries + more + "\n\n请确认所选目录没有正在运行或等待返回的工具任务。重置会清空脚本变量和本地工具句柄，保留 MCP 服务与对话记录；下一次调用需重新初始化。不能确认时请选择取消。"
    }
    private var outcomes: [CodexCleanupOutcome] { kernelMode ? monitor.codexKernelResetOutcomes : monitor.codexCleanupOutcomes }
    private var visible: [CodexToolAssessment] {
        tools.filter { row in
            (filter != 2 || row.canClean) &&
            (query.isEmpty || row.kind.rawValue.localizedCaseInsensitiveContains(query) || String(row.process.pid).contains(query) ||
             row.process.command.localizedCaseInsensitiveContains(query) || row.process.service?.name.localizedCaseInsensitiveContains(query) == true ||
             row.owner.map { String($0.pid).contains(query) } == true)
        }
    }

    var body: some View {
        let scope = memoryScope
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "terminal").foregroundStyle(MemoryStyle.mint)
                Text("\(application.name) · 工具与回收").font(.system(size: 21, weight: .medium))
                Spacer()
                Button("刷新检查") { Task { await monitor.refresh() } }
                    .disabled(monitor.isRefreshing || monitor.isWorking)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 32) {
                    metric("\(application.name) 总占用 · \(scope.usesFootprint ? "footprint" : "RSS")", value: scope.application?.memoryBytes.binaryBytesText ?? "—")
                    Text("≈").foregroundStyle(MemoryStyle.secondary)
                    metric("其中工具 · \(scope.included.count) 个进程", value: scope.toolBytes.binaryBytesText)
                    Text("+").foregroundStyle(MemoryStyle.secondary)
                    metric("其余应用进程", value: scope.otherBytes?.binaryBytesText ?? "—")
                    Spacer()
                }
                Text(scope.application == nil ? "应用已不在当前列表；仅展示已验证属于此应用的残留。" : "与应用列表同一采样 · \(monitor.snapshot.timestamp.formatted(date: .omitted, time: .standard)) · 工具已计入合计，显示值按精度取整")
                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                if !scope.detached.isEmpty {
                    Text("另有应用外残留 \(scope.detached.count) 个 · \(scope.detachedBytes.binaryBytesText)（\(scope.detachedUsesFootprint ? "footprint" : "RSS")），不计入上述应用合计。")
                        .font(.system(size: 11)).foregroundStyle(MemoryStyle.mint)
                }
            }
            Text(kernelMode ? "无法从 CPU 判断是否有等待中的工具请求。重置会清空临时变量及浏览器/文档句柄，请先确认相关目录没有在途工具任务。" : "宿主存在不代表工具正在使用。孤立残留可清理；仍连接的执行环境可到“疑似闲置内核”中查看和手动重置。")
                .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
            HStack(spacing: 14) {
                Picker("范围", selection: $filter) {
                    Text("工具明细").tag(0)
                    Text("疑似闲置内核 · \(kernels.count)").tag(1)
                    Text("可清理残留").tag(2)
                }.pickerStyle(.segmented).frame(width: 430)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    TextField(kernelMode ? "搜索工作目录或 PID" : "搜索工具、路径或 PID", text: $query).textFieldStyle(.plain)
                }.font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                    .padding(.horizontal, 10).frame(width: 255, height: 30)
                    .background(MemoryStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(spacing: 0) {
                HStack {
                    Text(kernelMode ? "内核初始目录 / 执行环境" : "工具 / 原宿主").frame(maxWidth: .infinity, alignment: .leading)
                    Text("无 CPU 活动").frame(width: 90, alignment: .trailing)
                    Text("占用").frame(width: 100, alignment: .trailing)
                    Text("处理条件").frame(width: 200, alignment: .leading)
                }.font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).padding(.horizontal, 12).padding(.bottom, 10)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if kernelMode {
                            ForEach(visibleKernels) { row in kernelRow(row, scope: scope) }
                        } else {
                            ForEach(visible) { row in toolRow(row, scope: scope) }
                        }
                    }
                }.id(kernelMode).overlay {
                    if kernelMode ? visibleKernels.isEmpty : visible.isEmpty {
                        Text(kernelMode ? "暂无已识别的配对执行内核；空工具宿主不会被误作内核重置。" : tools.isEmpty ? "暂无已识别的 Codex 工具环境" : "当前筛选下没有工具进程")
                            .font(.system(size: 13)).foregroundStyle(MemoryStyle.secondary)
                    }
                }
            }.frame(maxHeight: .infinity)
            Rectangle().fill(MemoryStyle.line).frame(height: 1)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = monitor.lastError {
                        Text("\(error) · 数据未更新，暂不能清理").foregroundStyle(.orange)
                    } else if !outcomes.isEmpty {
                        Text(outcomeText).foregroundStyle(MemoryStyle.mint)
                        ForEach(Array(outcomes.filter { $0.status != .exited }.prefix(2).enumerated()), id: \.offset) { _, outcome in
                            Text("PID \(outcome.pid)：\(outcome.detail)").foregroundStyle(MemoryStyle.secondary)
                        }
                    } else {
                        Text(kernelMode ? "已识别 \(kernels.count) 个内核，\(readyKernels.count) 个达到至少 60 秒未见 CPU 活动的观察条件。" : ready.isEmpty ? "没有可确认的孤立残留；这不代表不存在闲置内核。" : "仅已验证原宿主退出、无子进程且连续安静至少 60 秒的工具可选。")
                            .foregroundStyle(MemoryStyle.secondary)
                    }
                    Text("\(monitor.samplingMode == .detailed ? "随前台采样观察" : "后台已暂停观察，可手动刷新") · " + (kernelMode ? "可手动重置 \(readyKernels.count) 个 · 当前占用 \(readyKernels.reduce(UInt64(0)) { $0 + $1.bytes(usesFootprint: scope.usesFootprint) }.binaryBytesText)，不等于实际释放量。" : "可清理孤立残留 \(ready.count) 个，占用不等于可释放空间。"))
                        .foregroundStyle(MemoryStyle.secondary)
                }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                Button(kernelMode ? "选择当前可重置项" : "选择可清理项") {
                    if kernelMode { kernelSelection = Set(visibleReadyKernels.map(\.id)) } else { selection = Set(ready.map(\.id)) }
                }.disabled((kernelMode ? visibleReadyKernels.isEmpty : ready.isEmpty) || monitor.isWorking)
                Button(kernelMode ? "重置所选内核（\(selectedKernels.count)）" : "清理所选残留（\(selected.count)）") { confirmsCleanup = true }
                    .tint(kernelMode ? .orange : MemoryStyle.mint)
                    .disabled((kernelMode ? selectedKernels.isEmpty : selected.isEmpty) || monitor.isWorking || monitor.lastError != nil)
            }
        }
        .padding(24).frame(width: 900, height: 650)
        .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).preferredColorScheme(.dark)
        .buttonStyle(.bordered).focusEffectDisabled()
        .task { await monitor.refresh() }
        .onChange(of: ready.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .onChange(of: readyKernels.map(\.id)) { _, ids in kernelSelection.formIntersection(ids) }
        .alert(kernelMode ? "重置 \(selectedKernels.count) 个执行内核？" : "清理 \(selected.count) 个工具残留？", isPresented: $confirmsCleanup) {
            Button("取消", role: .cancel) {}
            Button(kernelMode ? "确认无在途任务并重置" : "请求退出残留", role: kernelMode ? .destructive : nil) {
                if kernelMode {
                    let ids = kernelSelection
                    Task { await monitor.resetCodexKernels(ids); kernelSelection.removeAll() }
                } else {
                    let ids = selection
                    Task { await monitor.cleanCodexTools(ids); selection.removeAll() }
                }
            }
        } message: {
            Text(kernelMode ? resetConfirmation : "只向已脱离原宿主的工具发送退出请求；执行前再次核对身份与活动，条件变化会跳过。不会强制终止，也不会修改对话记录。")
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            Text(value).font(.system(size: 23, weight: .medium)).monospacedDigit()
        }
    }

    private func toolRow(_ row: CodexToolAssessment, scope: CodexToolMemoryScope) -> some View {
        HStack(spacing: 10) {
            if row.canClean {
                Toggle("选择 PID \(row.process.pid)", isOn: Binding(get: { selection.contains(row.id) }, set: { value in
                    if value { selection.insert(row.id) } else { selection.remove(row.id) }
                })).toggleStyle(.checkbox).labelsHidden().frame(width: 18)
            } else { Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).frame(width: 18) }
            VStack(alignment: .leading, spacing: 5) {
                Text("\(row.kind.rawValue) · PID \(row.process.pid)").font(.system(size: 12, weight: .medium))
                Text("\(scope.isIncluded(row) ? "已计入应用合计" : "应用外残留") · " + (row.owner.map { "宿主 PID \($0.pid)" } ?? "原宿主未验证"))
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(row.process.cpuTimeTicks == nil ? "—" : duration(row.quietSeconds)).frame(width: 90, alignment: .trailing)
            Text(scope.bytes(for: row).binaryBytesText).frame(width: 100, alignment: .trailing)
            Text(row.stateText).font(.system(size: 11)).foregroundStyle(row.canClean ? MemoryStyle.mint : MemoryStyle.secondary)
                .frame(width: 200, alignment: .leading)
        }.font(.system(size: 12)).monospacedDigit().padding(.horizontal, 12).frame(height: 56)
            .background(selection.contains(row.id) ? MemoryStyle.mint.opacity(0.08) : MemoryStyle.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
            .help([row.process.command, row.process.service?.entryPoint].compactMap { $0 }.joined(separator: "\n"))
    }

    private func duration(_ value: TimeInterval) -> String {
        value >= 60 ? "\(Int(value / 60)) 分 \(Int(value) % 60) 秒" : "\(Int(value)) 秒"
    }

    private var outcomeText: String {
        return "本次\(kernelMode ? "重置" : "检查")：已退出 \(outcomes.filter { $0.status == .exited }.count) · 仍运行 \(outcomes.filter { $0.status == .requested }.count) · 跳过 \(outcomes.filter { $0.status == .skipped }.count) · 失败 \(outcomes.filter { $0.status == .failed }.count)"
    }

    private func kernelRow(_ row: CodexKernelAssessment, scope: CodexToolMemoryScope) -> some View {
        HStack(spacing: 10) {
            if row.canReset {
                Toggle("选择内核 PID \(row.trusted.pid)", isOn: Binding(get: { kernelSelection.contains(row.id) }, set: { value in
                    if value { kernelSelection.insert(row.id) } else { kernelSelection.remove(row.id) }
                })).toggleStyle(.checkbox).labelsHidden().frame(width: 18)
            } else { Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).frame(width: 18) }
            VStack(alignment: .leading, spacing: 5) {
                Text(URL(fileURLWithPath: row.workingDirectory).lastPathComponent).font(.system(size: 12, weight: .medium))
                Text(row.workingDirectory).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(duration(row.quietSeconds)).frame(width: 90, alignment: .trailing)
            Text(row.bytes(usesFootprint: scope.usesFootprint).binaryBytesText).frame(width: 100, alignment: .trailing)
            Text(row.stateText).font(.system(size: 11)).foregroundStyle(row.canReset ? .orange : MemoryStyle.secondary)
                .frame(width: 200, alignment: .leading)
        }.font(.system(size: 12)).monospacedDigit().padding(.horizontal, 12).frame(height: 60)
            .background(kernelSelection.contains(row.id) ? Color.orange.opacity(0.08) : MemoryStyle.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
            .help("工具宿主 PID \(row.host.pid)；执行内核 PID \(row.trusted.pid)、\(row.kernel.pid)。目录来自内核初始化参数，未确认具体会话或在途工具调用。")
    }
}
