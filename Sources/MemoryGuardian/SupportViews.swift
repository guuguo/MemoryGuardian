import SwiftUI

struct MenuBarStatusLabel: View {
    @ObservedObject var status: MenuBarStatus
    var body: some View { Image(systemName: status.icon).accessibilityLabel("内存守卫") }
}

struct MenuBarView: View {
    @EnvironmentObject private var monitor: MemoryMonitor
    @ObservedObject var status: MenuBarStatus
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系统总内存：\(status.snapshot.totalBytes.binaryBytesText)")
            Text("已用：\(status.snapshot.usedBytes.binaryBytesText)")
            Text("内存压力：\(status.lastError == nil ? status.snapshot.pressure.rawValue : "读取失败")")
            Text("交换空间：\(status.snapshot.swapTotalBytes != nil ? status.snapshot.swapUsedBytes.binaryBytesText : "未获取")")
            Text("后台每 30 秒更新系统摘要；打开窗口恢复详细采样")
            if let error = status.lastError { Text(error) }
            Divider()
            Button("显示主窗口") {
                showGuardianWindow(using: openWindow)
            }
            Button("刷新") {
                Task { await monitor.refresh() }
            }
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
    }
}
