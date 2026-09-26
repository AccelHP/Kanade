import SwiftUI
import AppKit
import AVFoundation

struct PadEditorSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let padID: UUID

    var body: some View {
        let _ = store.liveTick
        VStack(spacing: 0) {
            if let pad = store.padByID(padID) {
                header(pad)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        WaveformEditor(padID: padID)
                        HStack(alignment: .top, spacing: 16) {
                            PlaybackPanel(padID: padID)
                                .frame(maxWidth: .infinity, alignment: .top)
                            FXPanel(padID: padID)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 12) {
                    Text("这个按钮已经被清空。").foregroundColor(.secondary)
                    Button("关闭") { dismiss() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 940, height: 760)
        .font(.app(13))
    }

    private func header(_ pad: Pad) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(padColor(pad.colorIndex))
                .frame(width: 6, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                TextField("名称", text: store.padNameBinding(id: padID))
                    .textFieldStyle(.plain)
                    .font(.app(19, .semibold))
                Text("\(pad.originalName)，全长 \(formatPrecise(pad.duration))")
                    .font(.app(11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let k = pad.keyLabel {
                HStack(spacing: 4) {
                    Text("快捷键").font(.app(11)).foregroundColor(.secondary)
                    KeyCap(text: k)
                }
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

// MARK: - 视口：缩放与平移

final class WaveViewport: ObservableObject {
    @Published var zoom: Double = 1
    @Published var viewStart: Double = 0
    var duration: Double = 1
    var frame: CGRect = .zero          // 波形区域在窗口中的位置
    private var monitor: Any?

    var span: Double { duration / zoom }
    var viewEnd: Double { viewStart + span }
    /// 最多放大到窗口里只显示 20 毫秒
    var maxZoom: Double { max(1, duration / 0.02) }

    func setDuration(_ d: Double) {
        let nd = max(d, 0.001)
        if abs(nd - duration) > 0.0001 {
            objectWillChange.send()
            duration = nd
            clamp()
        }
    }

    func clamp() {
        let z = min(max(zoom, 1), maxZoom)
        if z != zoom { zoom = z }
        let s = min(max(0, viewStart), max(0, duration - duration / z))
        if s != viewStart { viewStart = s }
    }

    func x(_ t: Double, width: CGFloat) -> CGFloat { CGFloat((t - viewStart) / span) * width }
    func t(_ x: CGFloat, width: CGFloat) -> Double { viewStart + Double(x / max(width, 1)) * span }

    /// 以 anchorX 处为中心缩放：手指下面的那个时间点保持不动
    func zoom(by factor: Double, anchorX ax: CGFloat, width: CGFloat) {
        guard width > 0, factor.isFinite, factor > 0 else { return }
        let anchor = t(ax, width: width)
        let nz = min(max(zoom * factor, 1), maxZoom)
        zoom = nz
        viewStart = anchor - Double(ax / width) * (duration / nz)
        clamp()
    }

    func zoomCentered(by factor: Double) {
        let w = frame.width > 0 ? frame.width : 1000
        zoom(by: factor, anchorX: w / 2, width: w)
    }

    func pan(pixels dx: CGFloat) {
        guard frame.width > 0 else { return }
        viewStart -= Double(dx / frame.width) * span
        clamp()
    }

    func center(on t: Double) {
        viewStart = t - span / 2
        clamp()
    }

    func show(from a: Double, to b: Double) {
        let len = max(b - a, 0.02)
        let margin = len * 0.08
        zoom = duration / (len + margin * 2)
        viewStart = a - margin
        clamp()
    }

    func fit() {
        zoom = 1
        viewStart = 0
    }

    /// 监听触控板捏合和滚动：只处理落在波形区域里的事件
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] e in
            guard let self, let win = e.window, win.isKeyWindow, let host = win.contentView else { return e }
            let p = CGPoint(x: e.locationInWindow.x, y: host.bounds.height - e.locationInWindow.y)
            guard self.frame.width > 0, self.frame.contains(p) else { return e }
            let ax = p.x - self.frame.minX
            let w = self.frame.width

            if e.type == .magnify {
                // 两指张开放大、捏合缩小
                self.zoom(by: 1 + Double(e.magnification), anchorX: ax, width: w)
                return nil
            }

            let dx = e.scrollingDeltaX
            let dy = e.scrollingDeltaY
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
            if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                // 鼠标用户：按住 ⌘ 或 ⌥ 滚动滚轮缩放
                self.zoom(by: exp(Double(dy * k) * 0.01), anchorX: ax, width: w)
                return nil
            }
            if abs(dx) > abs(dy) {
                // 两指左右滑动平移
                self.pan(pixels: dx * k)
                return nil
            }
            if !e.hasPreciseScrollingDeltas && self.zoom > 1.001 {
                // 鼠标滚轮在放大状态下平移
                self.pan(pixels: dy * k)
                return nil
            }
            return e
        }
    }

    func uninstall() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit { uninstall() }
}

// MARK: - 波形编辑

struct WaveformEditor: View {
    @EnvironmentObject var store: Store
    let padID: UUID
    @StateObject private var vp = WaveViewport()
    @State private var draft: Markers? = nil

    struct Markers: Equatable {
        var start: Double
        var end: Double
        var loopIn: Double
        var loopOut: Double
    }

    enum Handle { case start, end, loopIn, loopOut }

    private let minLength = 0.005

    /// 当前显示的时间范围：直接用按钮的真实时长计算，第一帧就正确
    private func window(_ pad: Pad) -> (start: Double, span: Double) {
        let dur = max(pad.duration, 0.001)
        let z = min(max(vp.zoom, 1), max(1, dur / 0.02))
        let span = dur / z
        let start = min(max(0, vp.viewStart), max(0, dur - span))
        return (start, span)
    }

    private func xFor(_ t: Double, _ pad: Pad, width: CGFloat) -> CGFloat {
        let w = window(pad)
        return CGFloat((t - w.start) / w.span) * width
    }

    private func tFor(_ x: CGFloat, _ pad: Pad, width: CGFloat) -> Double {
        let w = window(pad)
        return w.start + Double(x / max(width, 1)) * w.span
    }

    private func markers(_ pad: Pad) -> Markers {
        draft ?? Markers(start: pad.regionStart, end: pad.regionEnd, loopIn: pad.loopIn, loopOut: pad.loopOut)
    }

    var body: some View {
        if let pad = store.padByID(padID) {
            let m = markers(pad)
            let live = store.engine.isLive(padID)
            let paused = store.engine.isPaused(padID)
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    waveArea(pad, m, size: geo.size)
                        .background(
                            GeometryReader { g in
                                Color.clear
                                    .onAppear { vp.frame = g.frame(in: .global) }
                                    .onChange(of: g.frame(in: .global)) { f in vp.frame = f }
                            }
                        )
                }
                .frame(height: 250)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.15)))

                HStack(spacing: 10) {
                    overview(pad, m)
                    zoomControls(m)
                }

                HStack(alignment: .center, spacing: 18) {
                    HStack(spacing: 6) {
                        Button {
                            if live { store.pausePad(padID) }
                            else if paused { store.resumePad(padID) }
                            else { store.triggerByID(padID) }
                        } label: {
                            Label(live ? "暂停" : (paused ? "继续" : "播放"),
                                  systemImage: live ? "pause.fill" : "play.fill")
                                .frame(width: 64)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button {
                            store.stopPad(padID)
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .controlSize(.large)
                        .disabled(!live && !paused)
                        .help("停止")
                    }
                    TimeReadout(title: "起点", value: formatPrecise(m.start))
                    TimeReadout(title: "终点", value: formatPrecise(m.end))
                    TimeReadout(title: "长度", value: formatPrecise(m.end - m.start))
                    if pad.loop {
                        TimeReadout(title: "循环范围", value: "\(formatPrecise(m.loopIn)) – \(formatPrecise(m.loopOut))")
                    }
                    Spacer()
                    Toggle("循环", isOn: store.padBinding(id: padID, \.loop, fallback: false))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Button("重置范围") {
                        draft = nil
                        store.editPad(id: padID) {
                            $0.startTime = 0
                            $0.endTime = nil
                            $0.loopStart = nil
                            $0.loopEnd = nil
                        }
                    }
                    .controlSize(.small)
                }

                Text(helpText(pad))
                    .font(.app(11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear {
                vp.setDuration(pad.duration)
                vp.install()
            }
            .onDisappear { vp.uninstall() }
            .onChange(of: pad.duration) { d in vp.setDuration(d) }
        }
    }

    private func helpText(_ pad: Pad) -> String {
        var s = "触控板两指张开或捏合，可以在手指所在位置放大缩小波形；两指左右滑动平移；用鼠标时按住 ⌘ 滚动滚轮缩放。"
        s += "拖动波形选择播放范围，拖动标记微调，单击波形从该处试听。"
        if pad.loop {
            s += "按住 Shift 拖动波形可以设置循环范围。"
        }
        return s
    }

    private var zoomText: String {
        vp.zoom < 10 ? String(format: "%.1f×", vp.zoom) : "\(Int(vp.zoom.rounded()))×"
    }

    private func zoomControls(_ m: Markers) -> some View {
        HStack(spacing: 4) {
            Button { vp.zoomCentered(by: 1 / 1.6) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("缩小（⌘-）")
            Text(zoomText)
                .font(.app(11, .medium).monospacedDigit())
                .frame(width: 50)
            Button { vp.zoomCentered(by: 1.6) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .help("放大（⌘=）")
            Button("看选区") { vp.show(from: m.start, to: m.end) }
                .help("放大到播放范围")
            Button("看全部") { vp.fit() }
                .keyboardShortcut("0", modifiers: .command)
                .help("显示整段（⌘0）")
        }
        .controlSize(.small)
    }

    /// 全曲缩略图：蓝框是当前看到的部分，拖动它可以移动视图
    private func overview(_ pad: Pad, _ m: Markers) -> some View {
        let peaks = store.engine.peaks(padID)
        let color = padColor(pad.colorIndex)
        let dur = max(pad.duration, 0.001)
        let win = window(pad)
        return GeometryReader { g in
            let w = g.size.width
            let x0 = CGFloat(win.start / dur) * w
            let vw = max(6, CGFloat(win.span / dur) * w)
            ZStack(alignment: .topLeading) {
                if let peaks {
                    MiniWaveform(peaks: peaks, duration: dur, start: m.start, end: m.end,
                                 position: store.engine.progress(padID)?.position, color: color)
                        .padding(.vertical, 5)
                }
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: vw, height: g.size.height)
                    .offset(x: x0)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        vp.center(on: Double(max(0, min(w, v.location.x)) / w) * dur)
                    }
            )
        }
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.15)))
        .opacity(vp.zoom > 1.001 ? 1 : 0.55)
        .help("拖动蓝框移动视图")
    }

    // MARK: 波形区域

    @ViewBuilder
    private func waveArea(_ pad: Pad, _ m: Markers, size: CGSize) -> some View {
        let live = store.engine.hasVoices(padID)
        let peaks = store.engine.peaks(padID)
        let buffer = store.engine.buffer(padID)
        let color = padColor(pad.colorIndex)
        let dur = max(pad.duration, 0.001)
        let width = size.width
        let height = size.height
        let win = window(pad)
        let viewStart = win.start
        let span = win.span
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { _ in
            let pos = store.engine.progress(padID)?.position
            ZStack(alignment: .topLeading) {
                Canvas { ctx, sz in
                    WaveformEditor.draw(&ctx, size: sz, buffer: buffer, peaks: peaks,
                                        viewStart: viewStart, span: span, m: m,
                                        loop: pad.loop, color: color, position: pos)
                }
                .contentShape(Rectangle())
                .gesture(backgroundGesture(pad, width: width, duration: dur))

                handle(.start, m: m, pad: pad, width: width, height: height, duration: dur,
                       color: Color(red: 0.13, green: 0.66, blue: 0.32), label: "起")
                handle(.end, m: m, pad: pad, width: width, height: height, duration: dur,
                       color: Color(red: 0.90, green: 0.25, blue: 0.25), label: "止")
                if pad.loop {
                    handle(.loopIn, m: m, pad: pad, width: width, height: height, duration: dur,
                           color: Color.orange, label: "循环起")
                    handle(.loopOut, m: m, pad: pad, width: width, height: height, duration: dur,
                           color: Color.orange, label: "循环止")
                }
            }
            .frame(width: width, height: height)
            .coordinateSpace(name: "wave")
        }
    }

    @ViewBuilder
    private func handle(_ h: Handle, m: Markers, pad: Pad, width: CGFloat, height: CGFloat,
                        duration: Double, color: Color, label: String) -> some View {
        let t: Double = {
            switch h {
            case .start: return m.start
            case .end: return m.end
            case .loopIn: return m.loopIn
            case .loopOut: return m.loopOut
            }
        }()
        let x = xFor(t, pad, width: width)
        let isLoop = h == .loopIn || h == .loopOut
        if x >= -14 && x <= width + 14 {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(color)
                    .frame(width: 2, height: height - 20)
                    .offset(y: 20)
                Text(label)
                    .font(.app(10, .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color))
                    .fixedSize()
                    .offset(y: isLoop ? 44 : 22)
            }
            .frame(width: 28, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                    .onChanged { v in
                        var d = draft ?? markers(pad)
                        let tt = tFor(max(0, min(width, v.location.x)), pad, width: width)
                        apply(h, tt, to: &d, duration: duration)
                        draft = d
                    }
                    .onEnded { _ in commit(pad, duration: duration) }
            )
            .position(x: x, y: height / 2)
        }
    }

    private func backgroundGesture(_ pad: Pad, width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
            .onChanged { v in
                guard abs(v.translation.width) > 3 else { return }
                let a = tFor(max(0, min(width, v.startLocation.x)), pad, width: width)
                let b = tFor(max(0, min(width, v.location.x)), pad, width: width)
                let lo = max(0, min(a, b))
                let hi = min(duration, max(a, b))
                var d = draft ?? markers(pad)
                if NSEvent.modifierFlags.contains(.shift) && pad.loop {
                    d.loopIn = min(max(d.start, lo), d.end - minLength)
                    d.loopOut = max(min(d.end, hi), d.loopIn + minLength)
                } else if hi - lo >= minLength {
                    d.start = lo
                    d.end = hi
                    d.loopIn = lo
                    d.loopOut = hi
                }
                draft = d
            }
            .onEnded { v in
                if abs(v.translation.width) <= 3 {
                    let t = tFor(max(0, min(width, v.location.x)), pad, width: width)
                    store.preview(padID, from: t)
                } else {
                    commit(pad, duration: duration)
                }
            }
    }

    private func apply(_ h: Handle, _ t: Double, to d: inout Markers, duration: Double) {
        switch h {
        case .start:
            d.start = min(max(0, t), d.end - minLength)
            if d.loopIn < d.start { d.loopIn = d.start }
            if d.loopOut < d.loopIn + minLength { d.loopOut = min(d.end, d.loopIn + minLength) }
        case .end:
            d.end = max(min(duration, t), d.start + minLength)
            if d.loopOut > d.end { d.loopOut = d.end }
            if d.loopIn > d.loopOut - minLength { d.loopIn = max(d.start, d.loopOut - minLength) }
        case .loopIn:
            d.loopIn = min(max(d.start, t), d.loopOut - minLength)
        case .loopOut:
            d.loopOut = max(min(d.end, t), d.loopIn + minLength)
        }
    }

    private func commit(_ pad: Pad, duration: Double) {
        guard let d = draft else { return }
        store.editPad(id: padID) { p in
            p.startTime = d.start < 0.0005 ? 0 : d.start
            p.endTime = d.end >= duration - 0.0005 ? nil : d.end
            p.loopStart = abs(d.loopIn - d.start) < 0.0005 ? nil : d.loopIn
            p.loopEnd = abs(d.loopOut - d.end) < 0.0005 ? nil : d.loopOut
        }
        draft = nil
    }

    // MARK: 绘制

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, buffer: AVAudioPCMBuffer?, peaks: WavePeaks?,
                     viewStart: Double, span: Double, m: Markers, loop: Bool, color: Color, position: Double?) {
        let w = size.width
        let h = size.height
        guard w > 0, span > 0 else { return }
        let rulerH: CGFloat = 20
        let laneTop = rulerH + 6
        let laneH = (h - laneTop - 8) / 2
        let viewEnd = viewStart + span
        func x(_ t: Double) -> CGFloat { CGFloat((t - viewStart) / span) * w }

        // 标尺：刻度随缩放自动变细，最细到 1 毫秒
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: rulerH)), with: .color(Color.black.opacity(0.04)))
        let pps = Double(w) / span
        let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25, 0.5,
                               1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first { $0 * pps >= 80 } ?? 600
        var t = (viewStart / step).rounded(.up) * step
        var ticks = 0
        while t <= viewEnd + 1e-9 && ticks < 400 {
            let xx = x(t)
            ctx.fill(Path(CGRect(x: xx, y: rulerH - 6, width: 1, height: 6)), with: .color(Color.black.opacity(0.35)))
            let text = step < 1 ? formatPrecise(t) : formatTime(t)
            ctx.draw(Text(text).font(.app(9, .medium).monospacedDigit())
                        .foregroundColor(Color.black.opacity(0.55)),
                     at: CGPoint(x: xx + 3, y: 8), anchor: .leading)
            t += step
            ticks += 1
        }

        // 循环范围底色
        if loop {
            let a = x(m.loopIn)
            let b = x(m.loopOut)
            ctx.fill(Path(CGRect(x: a, y: rulerH, width: max(1, b - a), height: h - rulerH)),
                     with: .color(Color.orange.opacity(0.16)))
        }

        // 左右声道波形
        if let buffer, let data = buffer.floatChannelData, buffer.frameLength > 0 {
            let sr = buffer.format.sampleRate
            let n = Int(buffer.frameLength)
            let chs = max(1, min(2, Int(buffer.format.channelCount)))
            let startS = viewStart * sr
            let spanS = span * sr
            let samplesPerPixel = spanS / Double(w)
            let binS: Double = {
                guard let peaks, peaks.count > 0 else { return Double.infinity }
                return Double(n) / Double(peaks.count)
            }()
            for lane in 0..<2 {
                let p = data[min(lane, chs - 1)]
                let mid = laneTop + laneH * (CGFloat(lane) + 0.5)
                let scale = laneH * 0.47
                ctx.fill(Path(CGRect(x: 0, y: mid, width: w, height: 0.5)), with: .color(Color.black.opacity(0.12)))

                if samplesPerPixel < 1.5 {
                    // 放得很大时直接画出每一个采样点连成的线
                    let i0 = max(0, Int(startS.rounded(.down)) - 1)
                    let i1 = min(n - 1, Int((startS + spanS).rounded(.up)) + 1)
                    if i1 > i0 {
                        var path = Path()
                        for i in i0...i1 {
                            let px = CGFloat((Double(i) - startS) / spanS) * w
                            let py = mid - CGFloat(p[i]) * scale
                            if i == i0 { path.move(to: CGPoint(x: px, y: py)) } else { path.addLine(to: CGPoint(x: px, y: py)) }
                        }
                        ctx.stroke(path, with: .color(color), lineWidth: 1.3)
                        if samplesPerPixel < 0.25 {
                            for i in i0...i1 {
                                let px = CGFloat((Double(i) - startS) / spanS) * w
                                let py = mid - CGFloat(p[i]) * scale
                                ctx.fill(Path(ellipseIn: CGRect(x: px - 2, y: py - 2, width: 4, height: 4)),
                                         with: .color(color))
                            }
                        }
                    }
                } else {
                    let cols = max(1, Int(w / 2))
                    let spc = spanS / Double(cols)
                    let arr: [Float]? = peaks.map { lane == 0 ? $0.left : $0.right }
                    for c in 0..<cols {
                        let s0 = startS + Double(c) * spc
                        let s1 = s0 + spc
                        var mx: Float = 0
                        if spc >= binS, let arr, !arr.isEmpty {
                            // 缩小时用预先算好的峰值
                            let a = max(0, min(arr.count - 1, Int(s0 / binS)))
                            let b = max(a + 1, min(arr.count, Int(s1 / binS)))
                            for k in a..<b where arr[k] > mx { mx = arr[k] }
                        } else {
                            // 放大时直接读取原始采样
                            let a = max(0, min(n, Int(s0)))
                            let b = max(a, min(n, Int(s1.rounded(.up))))
                            var i = a
                            while i < b {
                                let v = abs(p[i])
                                if v > mx { mx = v }
                                i += 1
                            }
                        }
                        let amp = max(0.5, CGFloat(mx) * scale)
                        let time = s0 / sr
                        let played = position.map { time <= $0 } ?? false
                        let col: Color = played ? color : color.opacity(0.72)
                        ctx.fill(Path(CGRect(x: CGFloat(c) * 2, y: mid - amp, width: 1.5, height: amp * 2)), with: .color(col))
                    }
                }
            }
            ctx.draw(Text("L").font(.app(10, .bold)).foregroundColor(Color.black.opacity(0.45)),
                     at: CGPoint(x: 8, y: laneTop + 10), anchor: .leading)
            ctx.draw(Text("R").font(.app(10, .bold)).foregroundColor(Color.black.opacity(0.45)),
                     at: CGPoint(x: 8, y: laneTop + laneH + 10), anchor: .leading)
        } else {
            ctx.draw(Text("载入中…").font(.app(12)).foregroundColor(Color.black.opacity(0.5)),
                     at: CGPoint(x: w / 2, y: h / 2), anchor: .center)
        }

        // 播放范围之外变暗
        let xs = min(max(x(m.start), 0), w)
        let xe = min(max(x(m.end), 0), w)
        if xs > 0 {
            ctx.fill(Path(CGRect(x: 0, y: rulerH, width: xs, height: h - rulerH)), with: .color(Color(white: 0.9).opacity(0.72)))
        }
        if xe < w {
            ctx.fill(Path(CGRect(x: xe, y: rulerH, width: w - xe, height: h - rulerH)), with: .color(Color(white: 0.9).opacity(0.72)))
        }

        // 播放头
        if let pos = position, pos >= viewStart, pos <= viewEnd {
            ctx.fill(Path(CGRect(x: x(pos) - 0.75, y: 0, width: 1.5, height: h)), with: .color(Color.black.opacity(0.85)))
        }
    }
}
