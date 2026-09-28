import SwiftUI
import AppKit

/// 播放、声道、标记设置（编辑面板和波形编辑窗口共用）
struct PlaybackPanel: View {
    @EnvironmentObject var store: Store
    let padID: UUID

    var body: some View {
        if let pad = store.padByID(padID) {
            VStack(alignment: .leading, spacing: 12) {
                Card(title: "播放", icon: "play.circle") {
                    ParamSlider("音量", value: b(\.volume, 1), range: 0...1, defaultValue: 1) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                    ParamSlider("增益", value: b(\.gainDB, 0), range: 0...18, step: 0.5, defaultValue: 0) { v in
                        v < 0.05 ? "0 dB" : String(format: "+%.1f dB", v)
                    }
                    HStack(spacing: 6) {
                        Spacer().frame(width: 56)
                        Button("自动增益") { store.autoGain(id: padID) }
                            .help("把这个格子的峰值放大到 −1 dB")
                        Button("恢复") { store.editPad(id: padID) { $0.gainDB = 0 } }
                    }
                    .controlSize(.small)
                    ParamSlider("淡出", value: b(\.fade, 0.3), range: 0...5, step: 0.1, defaultValue: 0.3) {
                        String(format: "%.1f 秒", $0)
                    }
                    Row("再按一次") {
                        Picker("", selection: b(\.mode, .toggle)) {
                            ForEach(PressMode.allCases) { m in Text(m.label).tag(m) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    Toggle("循环播放", isOn: b(\.loop, false))
                    Toggle("播放时淡出其他声音", isOn: b(\.exclusive, false))
                }

                Card(title: "声道", icon: "hifispeaker.2") {
                    Picker("", selection: b(\.channelMode, .stereo)) {
                        ForEach(ChannelMode.allCases) { m in Text(m.segment).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(pad.channelMode.label)
                        .font(.app(11))
                        .foregroundColor(.secondary)
                    ParamSlider("声像", value: b(\.pan, 0), range: -1...1, defaultValue: 0) { formatPan($0) }
                    HStack(spacing: 6) {
                        Spacer().frame(width: 56)
                        Button("左") { store.editPad(id: padID) { $0.pan = -1 } }
                        Button("中") { store.editPad(id: padID) { $0.pan = 0 } }
                        Button("右") { store.editPad(id: padID) { $0.pan = 1 } }
                    }
                    .controlSize(.small)
                }

                Card(title: "标记", icon: "tag") {
                    Row("颜色") {
                        ColorSwatches(selected: pad.colorIndex) { k in
                            store.editPad(id: padID) { $0.colorIndex = k }
                        }
                    }
                    Row("标签") {
                        Menu {
                            Button("无标签") { store.setTag(id: padID, nil) }
                            Divider()
                            ForEach(presetTags, id: \.self) { t in
                                Button(t) { store.setTag(id: padID, t) }
                            }
                            Divider()
                            Button("自定义…") { store.beginTag(id: padID) }
                        } label: {
                            Text(pad.tag ?? "无标签")
                        }
                        .fixedSize()
                        .controlSize(.small)
                    }
                    Row("键位") {
                        KeyCap(text: pad.keyLabel ?? "")
                        Button(store.capturingPadID == padID ? "请按目标键…" : "移动…") {
                            store.beginKeyCapture(id: padID)
                        }
                        .controlSize(.small)
                        .help("按下另一个格子的键，把这个音频移过去（两边互换）")
                    }
                    Row("MIDI") {
                        Text(pad.midi?.label ?? "无")
                            .font(.app(12))
                            .foregroundColor(pad.midi == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Button(store.midiLearn == .pad(padID) ? "请操作设备…" : "学习") {
                            store.beginMIDILearn(.pad(padID))
                        }
                        .controlSize(.small)
                        if pad.midi != nil {
                            Button("清除") { store.clearMIDI(id: padID) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func b<T>(_ kp: WritableKeyPath<Pad, T>, _ fallback: T) -> Binding<T> {
        store.padBinding(id: padID, kp, fallback: fallback)
    }
}

/// 音效设置
struct FXPanel: View {
    @EnvironmentObject var store: Store
    let padID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("音效", systemImage: "wand.and.stars")
                    .font(.app(13, .semibold))
                Spacer()
                Button("全部重置") { store.editPad(id: padID) { $0.fx = FXSettings() } }
                    .controlSize(.small)
            }

            FXSection(title: "均衡器", icon: "slider.vertical.3", isOn: b(\.fx.eqOn, false)) {
                ParamSlider("低频", value: b(\.fx.eqLow, 0), range: -12...12, defaultValue: 0, format: formatDB)
                ParamSlider("中频", value: b(\.fx.eqMid, 0), range: -12...12, defaultValue: 0, format: formatDB)
                ParamSlider("高频", value: b(\.fx.eqHigh, 0), range: -12...12, defaultValue: 0, format: formatDB)
            }

            FXSection(title: "变调 / 变速", icon: "tuningfork", isOn: b(\.fx.pitchOn, false)) {
                ParamSlider("音高", value: b(\.fx.pitch, 0), range: -12...12, step: 1, defaultValue: 0) { v in
                    abs(v) < 0.5 ? "原调" : String(format: "%+.0f 半音", v)
                }
                ParamSlider("速度", value: b(\.fx.speed, 1), range: 0.5...2, step: 0.05, defaultValue: 1) {
                    String(format: "%.2f×", $0)
                }
            }

            FXSection(title: "混响", icon: "building.columns", isOn: b(\.fx.reverbOn, false)) {
                Row("空间") {
                    Picker("", selection: b(\.fx.reverbPreset, .mediumHall)) {
                        ForEach(ReverbPreset.allCases) { p in Text(p.label).tag(p) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 140)
                }
                ParamSlider("混合", value: b(\.fx.reverbMix, 30), range: 0...100, defaultValue: 30) {
                    "\(Int($0.rounded()))%"
                }
            }

            FXSection(title: "延迟", icon: "dot.radiowaves.right", isOn: b(\.fx.delayOn, false)) {
                ParamSlider("时间", value: b(\.fx.delayTime, 0.35), range: 0.05...1.5, defaultValue: 0.35) {
                    String(format: "%.2f 秒", $0)
                }
                ParamSlider("反馈", value: b(\.fx.delayFeedback, 30), range: 0...90, defaultValue: 30) {
                    "\(Int($0.rounded()))%"
                }
                ParamSlider("混合", value: b(\.fx.delayMix, 25), range: 0...100, defaultValue: 25) {
                    "\(Int($0.rounded()))%"
                }
            }

            Text("双击参数名称可以恢复默认值。")
                .font(.app(11))
                .foregroundColor(.secondary)
        }
    }

    private func b<T>(_ kp: WritableKeyPath<Pad, T>, _ fallback: T) -> Binding<T> {
        store.padBinding(id: padID, kp, fallback: fallback)
    }
}

/// 编辑模式右侧面板
struct Inspector: View {
    @EnvironmentObject var store: Store
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let i = store.selected, let pad = store.pad(i) {
                    header(i, pad)
                    PlaybackPanel(padID: pad.id)
                    HStack {
                        Button("更换音频…") { store.requestPanel(for: i, replace: true) }
                        Spacer()
                        Button("清空这一格", role: .destructive) { confirmClear = true }
                    }
                    .confirmationDialog("清空这一格？", isPresented: $confirmClear) {
                        Button("清空", role: .destructive) { store.clearPad(id: pad.id) }
                    } message: {
                        Text("音频会从 Kanade 中移除，你电脑上的原文件不受影响。")
                    }
                } else {
                    boardSection
                }
            }
            .padding(16)
        }
        .font(.app(13))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(_ i: Int, _ pad: Pad) -> some View {
        let color = padColor(pad.colorIndex)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pad.displayName)
                        .font(.app(16, .semibold))
                        .lineLimit(1)
                    Text("\(pad.originalName)，\(formatTime(pad.duration))")
                        .font(.app(11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button("重命名…") { store.beginRename(id: pad.id) }
                    .controlSize(.small)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.1))
                if let peaks = store.engine.peaks(pad.id) {
                    MiniWaveform(peaks: peaks, duration: pad.duration, start: pad.regionStart,
                                 end: pad.regionEnd, position: store.engine.progress(pad.id)?.position, color: color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
            .frame(height: 50)
            Button {
                store.openEditor(i)
            } label: {
                Label("编辑波形与音效…", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private var boardSection: some View {
        Card(title: "本页", icon: "square.grid.3x3") {
            HStack {
                Text(store.boardName).font(.app(14, .semibold))
                Spacer()
                Button("重命名…") { store.beginBoardRename(store.lib.active) }
                    .controlSize(.small)
            }
            Text("已用 \(store.usedCount) / \(padsPerBoard) 格")
                .font(.app(11))
                .foregroundColor(.secondary)
            Menu("批量设置“再按一次”") {
                Button("15 秒以内的格子设为“从头重播”") { store.setModeForBoard(.restart, shortOnly: true) }
                Divider()
                ForEach(PressMode.allCases) { m in
                    Button("本页全部设为“\(m.label)”") { store.setModeForBoard(m, shortOnly: false) }
                }
            }
            .controlSize(.small)
            .fixedSize()
            HStack {
                Button("导出这一页…") { store.exportBackup(currentPageOnly: true) }
                Button("导入备份…") { store.importBackup() }
            }
            .controlSize(.small)
            Button("删除这一页…", role: .destructive) { store.requestDeleteBoard(store.lib.active) }
                .disabled(store.lib.boards.count < 2)
        }
        Card(title: "怎么用", icon: "lightbulb") {
            VStack(alignment: .leading, spacing: 6) {
                Text("点选一个按钮，在这里修改它的设置。")
                Text("双击按钮打开波形与音效编辑，可以剪掉开头结尾、设置循环范围、加均衡和混响。")
                Text("把音频文件拖到空格上即可添加，拖动按钮可以交换位置，键位跟着位置走。")
                Text("键位固定在格子上。“移动…”会把音频移到另一个键的格子，原来在那里的音频换过来。")
                Text("任何模式下都可以右键点按钮，快速改颜色、标签和声道，或者用“MIDI 学习”绑定 MIDI 设备。")
                Text("格子是灰色虚线框时表示还在载入，变成彩色就可以播放了。")
                Text("有多个页面时，Tab 切到下一页，Shift+Tab 切到上一页。")
                Text("空格键暂停或继续全部；把“再按一次”设成“暂停 / 继续”，按格子的键就能单独暂停。")
            }
            .font(.app(12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
