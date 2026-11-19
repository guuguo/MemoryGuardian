import SwiftUI

struct PhysicalMemoryPart: Identifiable {
    let id: String
    let label: String
    let bytes: UInt64
    let color: Color
}

struct PhysicalMemoryComposition {
    let totalBytes: UInt64
    let parts: [PhysicalMemoryPart]

    init(_ snapshot: MemorySnapshot) {
        totalBytes = snapshot.totalBytes
        parts = [
            .init(id: "app", label: "应用", bytes: snapshot.appBytes, color: MemoryStyle.mint),
            .init(id: "wired", label: "系统常驻", bytes: snapshot.wiredBytes, color: Color(red: 0.51, green: 0.62, blue: 0.73)),
            .init(id: "compressed", label: "压缩", bytes: snapshot.compressedBytes, color: Color(red: 0.71, green: 0.61, blue: 0.84)),
            .init(id: "cached", label: "缓存", bytes: snapshot.cachedBytes, color: Color(red: 0.39, green: 0.42, blue: 0.47)),
            .init(id: "free", label: "空闲", bytes: snapshot.freeBytes, color: Color(red: 0.24, green: 0.29, blue: 0.32)),
            .init(id: "other", label: "其他物理页", bytes: snapshot.unclassifiedBytes, color: Color(red: 0.58, green: 0.60, blue: 0.62))
        ]
    }

    var isComplete: Bool { totalBytes > 0 && parts.reduce(UInt64(0)) { $0 + $1.bytes } == totalBytes }

    func fraction(_ bytes: UInt64) -> Double { totalBytes > 0 ? Double(bytes) / Double(totalBytes) : 0 }

    func range(at index: Int) -> (start: Double, end: Double) {
        let start = parts.prefix(index).reduce(UInt64(0)) { $0 + $1.bytes }
        return (fraction(start), min(1, fraction(start + parts[index].bytes)))
    }
}

struct CoreCPUChart: View {
    let cores: [CoreCPUReading]
    let allowsMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if cores.isEmpty {
            Text("逐核数据暂未读取").font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 8) {
                VStack { Text("100%"); Spacer(); Text("50"); Spacer(); Text("0") }
                    .font(.system(size: 8)).foregroundStyle(MemoryStyle.secondary).frame(width: 27, height: 88)
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(cores) { core in
                        VStack(spacing: 7) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 2).fill(MemoryStyle.line)
                                RoundedRectangle(cornerRadius: 2).fill(MemoryStyle.mint)
                                    .scaleEffect(x: 1, y: (core.percent ?? 0) / 100, anchor: .bottom)
                                    .animation(allowsMotion && !reduceMotion ? .easeOut(duration: 0.25) : nil, value: core.percent)
                                if core.percent == nil {
                                    Text("—").font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
                                        .padding(.bottom, 3)
                                }
                            }.frame(height: 88)
                            Text("\(core.id + 1)").font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                            .help("逻辑核心 \(core.id + 1)：\(core.percent.map { cpuText($0) } ?? "等待相邻采样")")
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("逐核 CPU 使用率")
            .accessibilityValue(cores.map { "核心 \($0.id + 1)：\(cpuText($0.percent))" }.joined(separator: "；"))
        }
    }
}

struct PhysicalMemoryRing: View {
    let snapshot: MemorySnapshot
    let allowsMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted: String?
    private var composition: PhysicalMemoryComposition { .init(snapshot) }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(MemoryStyle.line, lineWidth: 16)
                if composition.isComplete {
                    ForEach(Array(composition.parts.enumerated()), id: \.element.id) { index, part in
                        let range = composition.range(at: index)
                        Circle().trim(from: range.start, to: range.end)
                            .stroke(part.color, style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                            .opacity(highlighted == nil || highlighted == part.id ? 1 : 0.3)
                            .animation(allowsMotion && !reduceMotion ? .easeOut(duration: 0.25) : nil, value: range.end)
                    }
                }
                VStack(spacing: 4) {
                    Text(snapshot.totalBytes > 0 ? snapshot.usedBytes.binaryBytesText : "—")
                        .font(.system(size: 21, weight: .semibold)).monospacedDigit()
                    Text(snapshot.totalBytes > 0 ? "已用 / \(snapshot.totalBytes.binaryBytesText)" : "等待采样")
                        .font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
                }
            }.padding(9).frame(width: 146, height: 146).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                if snapshot.totalBytes > 0 {
                    ForEach(composition.parts) { part in
                        HStack(spacing: 7) {
                            Circle().fill(part.color).frame(width: 7, height: 7)
                            Text(part.label)
                            Spacer(minLength: 8)
                            Text(part.bytes.binaryBytesText).monospacedDigit()
                        }.font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                            .contentShape(Rectangle())
                            .onHover { highlighted = $0 ? part.id : nil }
                            .help("\(part.label)：\(part.bytes.binaryBytesText)，占物理容量 \(String(format: "%.1f%%", composition.fraction(part.bytes) * 100))")
                    }
                } else {
                    Text("等待物理内存统计").font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                }
            }.frame(maxWidth: .infinity)
        }
    }
}
