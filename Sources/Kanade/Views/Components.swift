import SwiftUI
import AppKit

/// 菜单里用的彩色圆点
func swatchImage(_ color: NSColor) -> NSImage {
    let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    img.isTemplate = false
    return img
}

struct KeyCap: View {
    let text: String
    /// 格子上用的大号键帽
    var large: Bool = false

    var body: some View {
        let radius: CGFloat = large ? 7 : 4
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Text(text)
            .font(.app(large ? 17 : 11, .bold))
            .lineLimit(1)
            .padding(.horizontal, large ? 8 : 5)
            .frame(minWidth: large ? 30 : 18, minHeight: large ? 28 : 17)
            .background(shape.fill(Color.primary.opacity(large ? 0.11 : 0.10)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.15)))
            .overlay(alignment: .bottom) {
                // 键帽底部的一道厚边，看起来像实体按键
                if large {
                    shape.fill(Color.primary.opacity(0.12))
                        .frame(height: 2.5)
                        .padding(.horizontal, 1)
                }
            }
            .clipShape(shape)
    }
}

struct TagChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.app(10, .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.32)))
    }
}

struct LED: View {
    let on: Bool
    let fading: Bool
    var color: Color = .red
    var body: some View {
        Circle()
            .fill(on ? color : Color.primary.opacity(0.14))
            .frame(width: 8, height: 8)
            .shadow(color: on ? color.opacity(0.9) : Color.clear, radius: on ? 4 : 0)
            .opacity(fading ? 0.45 : 1)
    }
}

/// 按钮上的迷你波形
struct MiniWaveform: View {
    let peaks: WavePeaks
    let duration: Double
    let start: Double
    let end: Double
    let position: Double?
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard peaks.count > 0, duration > 0 else { return }
            let mid = size.height / 2
            let cols = max(1, Int(size.width / 2))
            for x in 0..<cols {
                let f0 = Double(x) / Double(cols)
                let f1 = Double(x + 1) / Double(cols)
                let a = min(peaks.count - 1, Int(f0 * Double(peaks.count)))
                let b = max(a + 1, min(peaks.count, Int(f1 * Double(peaks.count))))
                var m: Float = 0
                for k in a..<b {
                    let v = max(peaks.left[k], peaks.right[k])
                    if v > m { m = v }
                }
                let amp = max(0.6, CGFloat(m) * mid)
                let t = f0 * duration
                let inside = t >= start && t <= end
                let played = position.map { t <= $0 } ?? false
                let opacity: Double = !inside ? 0.16 : (played ? 1.0 : 0.5)
                let rect = CGRect(x: CGFloat(x) * 2, y: mid - amp, width: 1.4, height: amp * 2)
                ctx.fill(Path(rect), with: .color(color.opacity(opacity)))
            }
        }
    }
}

/// 总输出峰值表（dBFS），分段显示，带刻度、峰值保持、数值读数和过载指示
struct LevelMeter: View {
    @ObservedObject var meter: MeterModel

    static let segments = 64
    static let ticks: [Double] = [-40, -20, -12, -6, -3, 0]
    /// 刻度映射：顶部区间放大（dB → 0…1 的位置）
    private static let curve: [(db: Double, pos: Double)] = [
        (-60, 0), (-40, 0.15), (-20, 0.40), (-12, 0.57), (-6, 0.74), (-3, 0.86), (0, 1)
    ]

    static func pos(_ db: Double) -> Double {
        if db <= curve[0].db { return 0 }
        for k in 1..<curve.count where db <= curve[k].db {
            let a = curve[k - 1], b = curve[k]
            return a.pos + (db - a.db) / (b.db - a.db) * (b.pos - a.pos)
        }
        return 1
    }

    static func db(atPos p: Double) -> Double {
        if p <= 0 { return curve[0].db }
        for k in 1..<curve.count where p <= curve[k].pos {
            let a = curve[k - 1], b = curve[k]
            return a.db + (p - a.pos) / (b.pos - a.pos) * (b.db - a.db)
        }
        return 0
    }

    static func color(for db: Double) -> Color {
        if db >= -6 { return Color(red: 0.95, green: 0.24, blue: 0.21) }
        if db >= -18 { return Color(red: 0.98, green: 0.73, blue: 0.12) }
        return Color(red: 0.20, green: 0.78, blue: 0.36)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("L", channel: 0)
            row("R", channel: 1)
            HStack(spacing: 6) {
                Color.clear.frame(width: 10, height: 1)
                scale
                Button {
                    meter.resetClip()
                } label: {
                    Text("过载")
                        .font(.app(10, .bold))
                        .foregroundColor(meter.clipped ? .white : .secondary)
                        .frame(width: 44, height: 14)
                        .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(meter.clipped ? Color.red : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("输出达到 0 dBFS 时点亮并保持，点击复位")
            }
        }
        .frame(width: 264)
        .help("总输出峰值电平（dBFS）")
    }

    private func row(_ label: String, channel: Int) -> some View {
        let peak = meter.hold[channel]
        return HStack(spacing: 6) {
            Text(label)
                .font(.app(10, .bold))
                .foregroundColor(.secondary)
                .frame(width: 10)
            bar(channel)
            Text(LevelMeter.dbText(peak))
                .font(.app(11, .medium).monospacedDigit())
                .foregroundColor(LevelMeter.readoutColor(peak))
                .frame(width: 44, alignment: .trailing)
        }
        .frame(height: 12)
    }

    private func bar(_ ch: Int) -> some View {
        let level = meter.level[ch]
        let hold = meter.hold[ch]
        return Canvas { ctx, size in
            let n = LevelMeter.segments
            let gap: CGFloat = 1.5
            let segW = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let lit = level > MeterModel.floor ? LevelMeter.pos(level) : -1
            let holdIndex = hold > MeterModel.floor + 0.5
                ? min(n - 1, Int(LevelMeter.pos(hold) * Double(n))) : -1
            for k in 0..<n {
                let center = (Double(k) + 0.5) / Double(n)
                let on = center <= lit || k == holdIndex
                let color = LevelMeter.color(for: LevelMeter.db(atPos: center))
                let rect = CGRect(x: CGFloat(k) * (segW + gap), y: 0, width: segW, height: size.height)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                         with: .color(on ? color : Color.primary.opacity(0.09)))
            }
        }
        .frame(height: 10)
    }

    private var scale: some View {
        Canvas { ctx, size in
            for t in LevelMeter.ticks {
                let x = CGFloat(LevelMeter.pos(t)) * size.width
                ctx.fill(Path(CGRect(x: min(x, size.width - 1), y: 0, width: 1, height: 3)),
                         with: .color(Color.secondary.opacity(0.6)))
                let label = t == 0 ? "0" : "−\(Int(-t))"
                let anchor: UnitPoint = t == 0 ? .topTrailing : .top
                ctx.draw(Text(label).font(.app(10, .medium).monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: x, y: 3), anchor: anchor)
            }
        }
        .frame(height: 16)
    }

    static func dbText(_ v: Double) -> String {
        v <= MeterModel.floor + 0.05 ? "−∞" : String(format: "%.1f", v).replacingOccurrences(of: "-", with: "−")
    }

    static func readoutColor(_ v: Double) -> Color {
        if v > -1 { return .red }
        if v > -6 { return Color(red: 0.9, green: 0.55, blue: 0.0) }
        return .secondary
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.app(13, .semibold))
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct FXSection<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    let content: Content

    init(title: String, icon: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self._isOn = isOn
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(isOn ? .accentColor : .secondary)
                    .frame(width: 18)
                Text(title).font(.app(13, .semibold))
                Spacer()
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            content
                .disabled(!isOn)
                .opacity(isOn ? 1 : 0.45)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(isOn ? 0.12 : 0.05)))
    }
}

/// 带标签和数值的滑杆；双击标签恢复默认值
struct ParamSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let defaultValue: Double?
    let format: (Double) -> String

    init(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
         step: Double? = nil, defaultValue: Double? = nil, format: @escaping (Double) -> String) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.format = format
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.app(12))
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if let d = defaultValue { value = d }
                }
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
            }
            .controlSize(.small)
            Text(format(value))
                .font(.app(12, .medium).monospacedDigit())
                .frame(width: 62, alignment: .trailing)
        }
    }
}

struct Row<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.app(12))
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

struct ColorSwatches: View {
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(padPalette.indices, id: \.self) { k in
                Circle()
                    .fill(padPalette[k].color)
                    .frame(width: 19, height: 19)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                        .opacity(paletteIndex(selected) == k ? 1 : 0))
                    .overlay(Circle().stroke(Color.primary.opacity(0.55), lineWidth: 1).padding(-2.5)
                        .opacity(paletteIndex(selected) == k ? 1 : 0))
                    .contentShape(Circle())
                    .onTapGesture { onSelect(k) }
                    .help(padPalette[k].name)
            }
        }
    }
}

struct TimeReadout: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.app(10)).foregroundColor(.secondary)
            Text(value).font(.app(13, .semibold).monospacedDigit())
        }
    }
}

// MARK: - 字体：思源黑体（SIL 开源字体许可），没有打包进来时退回系统字体

enum AppFont {
    static let regular = "SourceHanSansCN-Regular"
    static let medium = "SourceHanSansCN-Medium"
    static let bold = "SourceHanSansCN-Bold"

    /// 字体文件是否已随 app 打包并成功载入
    static let available: Bool = NSFont(name: regular, size: 12) != nil

    static func name(for weight: Font.Weight) -> String {
        switch weight {
        case .medium: return medium
        case .semibold, .bold, .heavy, .black: return bold
        default: return regular
        }
    }
}

extension AppFont {
    /// logo 字体：编译脚本里 LOGO_FONT 指定、随 app 打包的开源字体；没有时退回思源黑体
    static func logo(_ size: CGFloat) -> Font {
        let info = Bundle.main.infoDictionary
        guard let family = info?["KanadeLogoFontFamily"] as? String, !family.isEmpty else {
            return .app(size, .bold)
        }
        let weight = (info?["KanadeLogoFontWeight"] as? NSNumber)?.doubleValue ?? 700
        let wghtAxis = NSNumber(value: 0x77676874)   // 可变字体的字重轴 'wght'
        let desc = NSFontDescriptor(fontAttributes: [.family: family])
            .addingAttributes([.variation: [wghtAxis: weight]])
        if let ns = NSFont(descriptor: desc, size: size), ns.familyName == family {
            return Font(ns as CTFont)
        }
        return .app(size, .bold)
    }
}

extension Font {
    /// 界面文字统一用这个
    static func app(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if AppFont.available {
            return .custom(AppFont.name(for: weight), fixedSize: size)
        }
        return .system(size: size, weight: weight)
    }

    /// SF Symbols 图标仍用系统符号字体，保证图标粗细正确
    static func icon(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - 应用标志

/// 顶栏标志：自己绘制的彩色九宫格，与应用图标的图案一致（不使用 SF Symbols）
struct AppMark: View {
    var size: CGFloat = 18

    var body: some View {
        let gap = size * 0.1
        let cell = (size - gap * 2) / 3
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { c in
                        RoundedRectangle(cornerRadius: cell * 0.28, style: .continuous)
                            .fill(padPalette[(2 - r) * 3 + c].color)
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - 即时点击

/// 播放模式下的鼠标点击：用 AppKit 的 mouseDown，按下的瞬间立刻触发，不经过 SwiftUI 的手势判断。
/// 右键和 Control+单击会穿透到下面，让右键菜单照常工作。
struct ClickCatcher: NSViewRepresentable {
    var onDown: () -> Void
    var onUp: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onDown = onDown
        v.onUp = onUp
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.onDown = onDown
        v.onUp = onUp
    }

    final class CatcherView: NSView {
        var onDown: (() -> Void)?
        var onUp: (() -> Void)?

        /// 窗口不在前台时，第一下点击也直接触发
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let e = NSApp.currentEvent {
                let isRight = e.type == .rightMouseDown || e.type == .rightMouseUp || e.type == .rightMouseDragged
                let isControlClick = (e.type == .leftMouseDown || e.type == .leftMouseUp)
                    && e.modifierFlags.contains(.control)
                if isRight || isControlClick { return nil }
            }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) { onDown?() }
        override func mouseUp(with event: NSEvent) { onUp?() }
    }
}

// MARK: - 取得所在的窗口

/// 把 SwiftUI 视图所在的 NSWindow 回传出来（用来判断按键发生在哪个窗口）
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let v = AccessorView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ v: AccessorView, context: Context) {
        v.onWindow = onWindow
    }

    final class AccessorView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(w) }
        }
    }
}
