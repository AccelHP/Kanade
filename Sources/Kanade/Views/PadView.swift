import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DragIfEditing: ViewModifier {
    let enabled: Bool
    let index: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { NSItemProvider(object: "kanade-pad:\(index)" as NSString) }
        } else {
            content
        }
    }
}

struct PadView: View {
    @EnvironmentObject var store: Store
    let index: Int
    @GestureState private var isDown = false
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        let pad = store.pad(index)
        let _ = store.liveTick
        let capturing = pad != nil && store.capturingPadID == pad?.id
        ZStack {
            if let pad {
                PadFace(pad: pad, pressed: isDown, hovering: hovering)
            } else {
                EmptySlot(keyLabel: store.defaultKeyLabel(for: index), hovering: hovering)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(isDown ? 0.965 : 1)
        .animation(.easeOut(duration: 0.08), value: isDown)
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(-4)
                .opacity((store.editing && store.selected == index) || capturing ? 1 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                .padding(-4)
                .opacity(targeted ? 1 : 0)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        // 演出模式：鼠标按下的瞬间就触发
        .gesture(DragGesture(minimumDistance: 0).updating($isDown) { _, state, _ in state = true },
                 including: store.editing ? GestureMask.none : GestureMask.all)
        .onChange(of: isDown) { down in
            if down { store.tap(index) }
        }
        // 编辑模式：单击选中，双击打开波形与音效编辑
        .onTapGesture(count: 2) {
            if store.editing, pad != nil { store.openEditor(index) }
        }
        .onTapGesture {
            if store.editing { store.tap(index) }
        }
        .modifier(DragIfEditing(enabled: store.editing && pad != nil, index: index))
        .onDrop(of: [UTType.fileURL, UTType.utf8PlainText, UTType.plainText], isTargeted: $targeted) { providers in
            store.handleDrop(providers, at: index)
        }
        .contextMenu { PadMenu(index: index) }
    }
}

// MARK: - 按钮外观

struct PadFace: View {
    @EnvironmentObject var store: Store
    let pad: Pad
    let pressed: Bool
    let hovering: Bool

    var body: some View {
        let status = store.engine.status(pad.id)
        let ready = status == .ready
        let color = padColor(pad.colorIndex)
        let live = store.engine.hasVoices(pad.id)
        let paused = store.engine.isPaused(pad.id)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { _ in
            let pr = store.engine.progress(pad.id)
            let playing = pr != nil && !paused
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let k = pad.keyLabel { KeyCap(text: k, large: true) }
                    if let t = pad.tag, !t.isEmpty { TagChip(text: t, color: ready ? color : Color.gray) }
                    Spacer(minLength: 2)
                    badges
                    if status == .failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.icon(11))
                            .foregroundColor(.orange)
                            .help("载入失败，右键选择“重新载入”")
                    } else if paused {
                        LED(on: true, fading: false, color: .orange)
                    } else {
                        LED(on: playing, fading: pr?.fading ?? false)
                    }
                }
                // 名称：居中，字号随格子大小和字数自动调整
                GeometryReader { g in
                    let title = pad.displayTitle
                    let size = PadFace.fontSize(for: title, width: g.size.width, height: g.size.height)
                    Text(title)
                        .font(.app(size, .semibold))
                        .foregroundColor(ready ? .primary : .secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.75)
                        .lineSpacing(size * 0.14)
                        .frame(width: g.size.width, height: g.size.height)
                }
                .padding(.vertical, 4)
                ZStack {
                    if ready, let peaks = store.engine.peaks(pad.id) {
                        MiniWaveform(peaks: peaks, duration: pad.duration,
                                     start: pad.regionStart, end: pad.regionEnd,
                                     position: pr?.position, color: color)
                    }
                }
                .frame(height: 18)
                HStack(spacing: 4) {
                    if paused {
                        Image(systemName: "pause.fill").font(.icon(9, .bold))
                        Text("已暂停").font(.app(10, .semibold))
                    } else if pr?.looping == true {
                        Image(systemName: "repeat").font(.icon(9, .bold))
                    }
                    Spacer(minLength: 0)
                    Text(timeText(pr, ready: ready))
                        .font(.app(11, (playing || paused) ? .bold : .medium).monospacedDigit())
                }
                .foregroundColor(paused ? .orange : (playing ? .primary : .secondary))
                .padding(.top, 3)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    if ready {
                        // 载入完成才上色；播放时颜色更深
                        LinearGradient(colors: [color.opacity(playing ? 0.52 : 0.34),
                                                color.opacity(playing ? 0.32 : 0.16)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    if hovering { Color.white.opacity(0.05) }
                }
            )
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(ready ? 0.18 : 0.06), Color.white.opacity(0.0)],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 1)
            )
            .overlay(
                shape.strokeBorder(
                    paused ? Color.orange : (playing ? color : (ready ? color.opacity(0.45) : Color.primary.opacity(0.12))),
                    style: StrokeStyle(lineWidth: (playing || paused) ? 2 : 1,
                                       dash: paused ? [6, 4] : (ready ? [] : [4, 3])))
            )
            .shadow(color: playing ? color.opacity(0.55) : Color.black.opacity(ready ? 0.18 : 0.06),
                    radius: playing ? 10 : 2, x: 0, y: playing ? 0 : 1)
            .animation(.easeOut(duration: 0.35), value: ready)
        }
    }

    /// 字号规则：能单行放下就用大字（最大 30），否则两行（最大 21），再不行三行（最大 16）
    static func fontSize(for text: String, width: CGFloat, height: CGFloat) -> CGFloat {
        guard width > 10, height > 8 else { return 12 }
        // 估算文字宽度（单位：字宽）：中文和全角 1，英文大写和数字约 0.62，小写约 0.52
        let units = text.unicodeScalars.reduce(0.0) { acc, u -> Double in
            let v = u.value
            if (0x2000...0x200A).contains(v) { return acc + 0.25 }
            if v >= 0x2E80 { return acc + 1.0 }
            if v == 0x20 { return acc + 0.28 }
            if (0x41...0x5A).contains(v) || (0x30...0x39).contains(v) { return acc + 0.62 }
            return acc + 0.52
        }
        let u = CGFloat(max(units, 1))
        let lineHeight: CGFloat = 1.34

        // 单行
        let one = min(30, width / u, height / lineHeight)
        if one >= 17 { return floor(one) }
        // 两行（换行不会刚好排满，按 88% 的利用率估算）
        let two = min(21, 2 * width * 0.88 / u, height / (2 * lineHeight))
        if two >= 13 { return floor(two) }
        // 三行
        let three = min(16, 3 * width * 0.85 / u, height / (3 * lineHeight))
        return max(10, floor(three))
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 3) {
            if pad.loop { Image(systemName: "repeat") }
            if pad.mode == .pause { Image(systemName: "playpause") }
            if pad.exclusive { Image(systemName: "1.circle") }
            if pad.isTrimmed { Image(systemName: "scissors") }
            if pad.fx.anyOn { Image(systemName: "wand.and.stars") }
            if let b = pad.channelMode.badge {
                Text(b).font(.app(9, .heavy))
            }
            if pad.pan < -0.05 { Image(systemName: "arrow.left") }
            if pad.pan > 0.05 { Image(systemName: "arrow.right") }
        }
        .font(.icon(9, .semibold))
        .foregroundColor(.secondary)
    }

    private func timeText(_ pr: VoiceProgress?, ready: Bool) -> String {
        guard ready else { return formatTime(pad.regionLength) }
        guard let pr else { return formatTime(pad.regionLength) }
        if let r = pr.remaining { return "-" + formatTime(r.rounded(.up)) }
        return formatTime(pr.position)
    }
}

struct EmptySlot: View {
    /// 加入音频后会自动分配的键；这个键已被别的格子占用时为 nil
    let keyLabel: String?
    let hovering: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.icon(15, .medium))
                Text(hovering ? "点击或拖入音频" : "空").font(.app(11))
            }
            .foregroundColor(Color.secondary.opacity(hovering ? 1 : 0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let keyLabel {
                KeyCap(text: keyLabel, large: true)
                    .foregroundColor(Color.primary.opacity(hovering ? 0.85 : 0.6))
                    .padding(10)
            }
        }
        .background(shape.fill(Color.primary.opacity(hovering ? 0.05 : 0.02)))
        .overlay(shape.strokeBorder(Color.primary.opacity(hovering ? 0.25 : 0.10),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

// MARK: - 右键菜单

struct PadMenu: View {
    @EnvironmentObject var store: Store
    let index: Int

    var body: some View {
        if let pad = store.pad(index) {
            let id = pad.id
            if store.engine.isPaused(id) {
                Button("继续播放") { store.resumePad(id) }
                Button("停止") { store.stopPad(id) }
            } else if store.engine.isLive(id) {
                Button("暂停") { store.pausePad(id) }
                Button("停止") { store.stopPad(id) }
            } else {
                Button("播放") { store.trigger(index: index) }
            }
            Divider()
            if store.engine.status(id) == .failed {
                Button("重新载入") { store.reload(id: id) }
                Divider()
            }
            Button("编辑波形与音效…") { store.openEditor(index) }
            Button("重命名…") { store.beginRename(id: id) }
            Divider()
            Menu("颜色") {
                ForEach(padPalette.indices, id: \.self) { k in
                    Toggle(isOn: Binding(
                        get: { paletteIndex(pad.colorIndex) == k },
                        set: { _ in store.editPad(id: id) { $0.colorIndex = k } })) {
                        Label {
                            Text(padPalette[k].name)
                        } icon: {
                            Image(nsImage: swatchImage(padPalette[k].nsColor))
                        }
                    }
                }
            }
            Menu("标签") {
                Toggle("无标签", isOn: Binding(
                    get: { pad.tag == nil },
                    set: { _ in store.setTag(id: id, nil) }))
                Divider()
                ForEach(presetTags, id: \.self) { t in
                    Toggle(t, isOn: Binding(
                        get: { pad.tag == t },
                        set: { _ in store.setTag(id: id, t) }))
                }
                Divider()
                Button("自定义…") { store.beginTag(id: id) }
            }
            Menu("声道") {
                ForEach(ChannelMode.allCases) { m in
                    Toggle(m.label, isOn: Binding(
                        get: { pad.channelMode == m },
                        set: { _ in store.editPad(id: id) { $0.channelMode = m } }))
                }
                Divider()
                Toggle("从左侧输出", isOn: Binding(
                    get: { pad.pan <= -0.99 },
                    set: { _ in store.editPad(id: id) { $0.pan = -1 } }))
                Toggle("居中输出", isOn: Binding(
                    get: { abs(pad.pan) < 0.01 },
                    set: { _ in store.editPad(id: id) { $0.pan = 0 } }))
                Toggle("从右侧输出", isOn: Binding(
                    get: { pad.pan >= 0.99 },
                    set: { _ in store.editPad(id: id) { $0.pan = 1 } }))
            }
            Menu("正在播放时再按一次") {
                ForEach(PressMode.allCases) { m in
                    Toggle(m.label, isOn: Binding(
                        get: { pad.mode == m },
                        set: { _ in store.editPad(id: id) { $0.mode = m } }))
                }
            }
            Toggle("循环播放", isOn: store.padBinding(id: id, \.loop, fallback: false))
            Toggle("播放时淡出其他声音", isOn: store.padBinding(id: id, \.exclusive, fallback: false))
            Divider()
            let keyTitle: String = pad.keyLabel.map { "更改快捷键（当前 \($0)）…" } ?? "设置快捷键…"
            Button(keyTitle) {
                store.beginKeyCapture(id: id)
            }
            if pad.keyCode != nil {
                Button("清除快捷键") { store.clearKey(id: id) }
            }
            Divider()
            Button("更换音频…") { store.requestPanel(for: index, replace: true) }
            Button("清空这一格", role: .destructive) { store.clearPad(id: id) }
        } else {
            Button("添加音频…") { store.requestPanel(for: index, replace: false) }
        }
    }
}
