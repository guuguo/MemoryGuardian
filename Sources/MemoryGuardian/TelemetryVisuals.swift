import SwiftUI
import AppKit
import QuartzCore

/// 显示节奏，不是物理风扇每秒圈数；真实 RPM 始终单独显示。
enum FanMotion {
    static func period(rpm: Double?, enabled: Bool) -> TimeInterval? {
        guard enabled, let rpm, rpm.isFinite, rpm > 0 else { return nil }
        return 1 / (0.28 + min(rpm, 7000) / 7000 * 0.9)
    }
}

struct FanRotorView: NSViewRepresentable {
    let rpm: Double?
    var stale = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> FanLayerView { FanLayerView() }
    func updateNSView(_ view: FanLayerView, context: Context) {
        view.configure(rpm: rpm, allowsMotion: !stale && !reduceMotion)
    }
    static func dismantleNSView(_ view: FanLayerView, coordinator: ()) { view.tearDown() }
}

/// 旋转由合成层处理，不触发 SwiftUI 每帧重绘或增加采样定时器。
final class FanLayerView: NSView {
    private let board = CALayer()
    private let housing = CAShapeLayer()
    private let rotor = CAShapeLayer()
    private let hub = CAShapeLayer()
    private var observers: [NSObjectProtocol] = []
    private var rpm: Double?
    private var allowsMotion = false
    private var currentPeriod: TimeInterval?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(board)
        board.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        [housing, rotor, hub].forEach {
            $0.bounds = board.bounds
            $0.position = CGPoint(x: 50, y: 50)
            board.addSublayer($0)
        }
        housing.path = CGPath(roundedRect: CGRect(x: 3, y: 3, width: 94, height: 94), cornerWidth: 17, cornerHeight: 17, transform: nil)
        housing.fillColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        housing.strokeColor = NSColor(calibratedRed: 0.65, green: 0.85, blue: 0.76, alpha: 0.24).cgColor
        housing.lineWidth = 1.5
        rotor.path = Self.blades()
        hub.path = CGPath(ellipseIn: CGRect(x: 42, y: 42, width: 16, height: 16), transform: nil)
        hub.fillColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
        hub.strokeColor = NSColor(calibratedRed: 0.65, green: 0.85, blue: 0.76, alpha: 0.8).cgColor
        hub.lineWidth = 2
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    private static func blades() -> CGPath {
        let blade = CGMutablePath()
        blade.move(to: CGPoint(x: 56, y: 46))
        blade.addCurve(to: CGPoint(x: 74, y: 15), control1: CGPoint(x: 64, y: 37), control2: CGPoint(x: 61, y: 19))
        blade.addCurve(to: CGPoint(x: 91, y: 43), control1: CGPoint(x: 86, y: 14), control2: CGPoint(x: 94, y: 30))
        blade.addCurve(to: CGPoint(x: 58, y: 55), control1: CGPoint(x: 79, y: 38), control2: CGPoint(x: 66, y: 43))
        blade.closeSubpath()
        let path = CGMutablePath()
        for index in 0..<7 {
            let transform = CGAffineTransform(translationX: 50, y: 50)
                .rotated(by: CGFloat(index) * .pi * 2 / 7).translatedBy(x: -50, y: -50)
            path.addPath(blade, transform: transform)
        }
        return path
    }

    func configure(rpm: Double?, allowsMotion: Bool) {
        self.rpm = rpm
        self.allowsMotion = allowsMotion
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let known = rpm.map { $0.isFinite && $0 >= 0 } ?? false
        rotor.fillColor = NSColor(calibratedRed: 0.65, green: 0.85, blue: 0.76, alpha: known ? (rpm == 0 ? 0.35 : 0.85) : 0.18).cgColor
        housing.lineDashPattern = known ? nil : [3, 4]
        CATransaction.commit()
        updateMotion()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        board.position = CGPoint(x: bounds.midX, y: bounds.midY)
        board.setAffineTransform(CGAffineTransform(scaleX: min(bounds.width, bounds.height) / 100,
                                                  y: min(bounds.width, bounds.height) / 100))
        CATransaction.commit()
        updateMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observe(name, object: window)
            }
            observe(NSApplication.didBecomeActiveNotification, object: NSApp)
            observe(NSApplication.didResignActiveNotification, object: NSApp)
            if let clip = enclosingScrollView?.contentView { observe(NSView.boundsDidChangeNotification, object: clip) }
        }
        updateMotion()
    }

    private func observe(_ name: Notification.Name, object: AnyObject) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMotion() }
        })
    }

    private func updateMotion() {
        let visible = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        let period = FanMotion.period(rpm: rpm, enabled: allowsMotion && NSApp.isActive && visible && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty)
        guard period != currentPeriod || (period != nil && rotor.animation(forKey: "rotation") == nil) else { return }
        stop()
        guard let period else { return }
        let angle = (rotor.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = angle; spin.toValue = angle + .pi * 2
        spin.duration = period; spin.repeatCount = .infinity
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        rotor.add(spin, forKey: "rotation")
        currentPeriod = period
    }

    func stop() {
        let angle = (rotor.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double)
            ?? (rotor.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rotor.setValue(angle, forKeyPath: "transform.rotation.z")
        rotor.removeAnimation(forKey: "rotation")
        CATransaction.commit()
        currentPeriod = nil
    }
    func tearDown() {
        stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}

struct TelemetryRing: View {
    let fraction: Double?
    var secondaryFraction: Double = 0
    var tint: Color = MemoryStyle.mint
    var symbol = "cpu"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var amount: CGFloat { CGFloat(min(1, max(0, fraction ?? 0))) }
    var body: some View {
        ZStack {
            Circle().stroke(MemoryStyle.line, lineWidth: 4)
            Circle().trim(from: 0, to: amount)
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
            if secondaryFraction > 0 {
                Circle().trim(from: max(0, amount - secondaryFraction), to: amount)
                    .stroke(Color(red: 0.51, green: 0.62, blue: 0.73), style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbol).font(.system(size: 19, weight: .light)).foregroundStyle(fraction == nil ? MemoryStyle.secondary : tint)
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: amount)
            .accessibilityHidden(true)
    }
}

struct TemperatureTrack: View {
    let low: Double?
    let high: Double?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func fraction(_ value: Double) -> CGFloat { CGFloat(min(1, max(0, (value - 20) / 90))) }
    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(MemoryStyle.line).frame(height: 4)
                    if let high {
                        Capsule().fill(tint.opacity(0.28)).frame(width: proxy.size.width * fraction(high), height: 4)
                        if let low {
                            Capsule().fill(tint.opacity(0.7))
                                .frame(width: max(3, proxy.size.width * (fraction(high) - fraction(low))), height: 4)
                                .offset(x: proxy.size.width * fraction(low))
                        }
                        Circle().fill(tint).frame(width: 7, height: 7).offset(x: max(0, proxy.size.width * fraction(high) - 3.5))
                    }
                }.frame(height: 9)
            }.frame(height: 9)
            HStack { Text("20°C"); Spacer(); Text("温区刻度"); Spacer(); Text("110°C") }
                .font(.system(size: 8)).foregroundStyle(MemoryStyle.secondary)
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: high)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("温区范围 \(low.map { String(format: "%.1f", $0) } ?? "未知") 至 \(high.map { String(format: "%.1f", $0) } ?? "未知") 摄氏度；刻度不代表报警阈值")
    }
}

struct TelemetryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, reduceMotion: reduceMotion)
    }
    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        let reduceMotion: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(hovered ? MemoryStyle.mint.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(hovered ? MemoryStyle.mint.opacity(0.18) : .clear, lineWidth: 1) }
                .opacity(configuration.isPressed ? 0.78 : 1)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.992 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

extension MachineThermalState {
    var visualTint: Color {
        switch self {
        case .nominal: MemoryStyle.mint
        case .fair: .orange
        case .serious, .critical: .red
        case .unknown: MemoryStyle.secondary
        }
    }
}

/// 仅用于图形查点与纵轴；不填补缺失数据，也不改变采样值。
enum PlotSamples {
    static func value(_ point: LoadHistoryPoint, appKey: String?) -> Double? {
        if let appKey { return point.appCPU[appKey] }
        return point.cpuPercent
    }
    static func nearest(in history: [LoadHistoryPoint], fraction: Double) -> LoadHistoryPoint? {
        guard let first = history.first, let last = history.last else { return nil }
        let target = first.timestamp.addingTimeInterval(last.timestamp.timeIntervalSince(first.timestamp) * min(1, max(0, fraction)))
        guard let point = history.min(by: { abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target)) }),
              abs(point.timestamp.timeIntervalSince(target)) <= 10 else { return nil }
        return point
    }
    static func ceiling(history: [LoadHistoryPoint], appKey: String?) -> Double {
        guard appKey != nil else { return 100 }
        return min(100, max(1, ((history.compactMap { value($0, appKey: appKey) }.max() ?? 0) * 1.2).rounded(.up)))
    }
}

struct InteractiveLoadPlot: View {
    let history: [LoadHistoryPoint]
    let appKey: String?
    let ceiling: Double
    @State private var hoverFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let selected = hoverFraction.flatMap { PlotSamples.nearest(in: history, fraction: $0) }
            Canvas { context, size in
                var grid = Path()
                for fraction in [0.0, 0.5, 1.0] {
                    grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                    grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                }
                context.stroke(grid, with: .color(MemoryStyle.line), lineWidth: 0.5)
                guard let start = history.first?.timestamp, let end = history.last?.timestamp else { return }
                let duration = max(1, end.timeIntervalSince(start))
                var line = Path()
                var previous: Date?
                for sample in history {
                    guard let value = PlotSamples.value(sample, appKey: appKey) else { previous = nil; continue }
                    let p = CGPoint(x: sample.timestamp.timeIntervalSince(start) / duration * size.width,
                                    y: (1 - min(ceiling, max(0, value)) / ceiling) * size.height)
                    if let last = previous, sample.timestamp.timeIntervalSince(last) <= 10 { line.addLine(to: p) }
                    else { line.move(to: p) }
                    previous = sample.timestamp
                }
                context.stroke(line, with: .color(MemoryStyle.mint), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                if let selected {
                    let x = selected.timestamp.timeIntervalSince(start) / duration * size.width
                    var cursor = Path(); cursor.move(to: CGPoint(x: x, y: 0)); cursor.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(cursor, with: .color(MemoryStyle.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let value = PlotSamples.value(selected, appKey: appKey) {
                        let point = CGPoint(x: x, y: (1 - min(ceiling, max(0, value)) / ceiling) * size.height)
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(MemoryStyle.mint))
                    }
                }
            }
            .overlay(alignment: .top) {
                if let hoverFraction {
                    HStack(spacing: 6) {
                        Text(selected?.timestamp.formatted(date: .omitted, time: .standard) ?? "采样间断")
                        Text(selected.flatMap { PlotSamples.value($0, appKey: appKey) }.map { cpuText($0) } ?? "—")
                            .foregroundStyle(MemoryStyle.mint)
                    }.font(.system(size: 10)).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 5)
                        .background(MemoryStyle.surface, in: RoundedRectangle(cornerRadius: 5))
                        .frame(width: 142).position(x: min(max(71, proxy.size.width * hoverFraction), max(71, proxy.size.width - 71)), y: 8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverFraction = min(1, max(0, location.x / max(1, proxy.size.width)))
                case .ended: hoverFraction = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU 使用率趋势，纵轴上限 \(Int(ceiling))%，均为整机容量占比")
        .accessibilityValue(history.last.flatMap { PlotSamples.value($0, appKey: appKey) }.map { "最近采样 \(cpuText($0))" } ?? "当前采样未读取")
    }
}
