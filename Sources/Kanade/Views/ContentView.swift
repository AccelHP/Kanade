import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            HStack(spacing: 0) {
                PadGrid()
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.03)))
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.editing {
                    Divider()
                    Inspector()
                        .frame(width: 330)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.18), value: store.editing)
            Divider()
            StatusBar()
        }
        .frame(minWidth: 1280, minHeight: 680)
        .font(.app(13))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { toast }
        .overlay(alignment: .top) { captureBanner }
        .sheet(item: $store.editorTarget) { t in
            PadEditorSheet(padID: t.id).environmentObject(store)
        }
        .alert(store.prompt?.title ?? "", isPresented: Binding(
            get: { store.prompt != nil },
            set: { if !$0 { store.prompt = nil } })) {
            TextField("", text: $store.promptText)
            Button("确定") { store.commitPrompt() }
            Button("取消", role: .cancel) { store.prompt = nil }
        }
        .confirmationDialog("删除这一页？", isPresented: Binding(
            get: { store.pendingDeleteBoard != nil },
            set: { if !$0 { store.pendingDeleteBoard = nil } })) {
            Button("删除", role: .destructive) { store.confirmDeleteBoard() }
        } message: {
            Text("这一页上的音频会一起从 Kanade 中删除，你电脑上的原文件不受影响。")
        }
        .background(WindowAccessor { w in store.mainWindow = w })
        .onAppear { store.installKeyMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshDevices()
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let m = store.message {
            Text(m)
                .font(.app(13))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                .padding(.bottom, 48)
        }
    }

    @ViewBuilder
    private var captureBanner: some View {
        if let text = store.midiLearnDescription {
            HStack(spacing: 10) {
                Image(systemName: "pianokeys")
                Text(text)
                Text("Esc 取消").foregroundColor(.secondary)
            }
            .font(.app(13, .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
            .padding(.top, 72)
        } else if let id = store.capturingPadID, let pad = store.padByID(id) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                Text("为“\(pad.displayName)”按下新的键")
                Text("会移到那个键的格子，Esc 取消").foregroundColor(.secondary)
            }
            .font(.app(13, .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
            .padding(.top, 72)
        }
    }
}

// MARK: - 顶栏

struct TopBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let live = store.liveCount > 0
        let anyPaused = store.pausedCount > 0
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                // logo：九宫格在上，名字在下
                VStack(spacing: 3) {
                    AppMark(size: 22)
                    Text("Kanade")
                        .font(AppFont.logo(14))
                        .foregroundColor(.primary)
                        .fixedSize()
                }
                OnAirBadge(live: live, paused: anyPaused)
                    .fixedSize()
            }
            .fixedSize()

            BoardTabs()

            Spacer(minLength: 8)

            LevelMeter(meter: store.meter)

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.icon(12))
                    .foregroundColor(.secondary)
                    .onTapGesture(count: 2) { store.setMaster(1) }
                Slider(value: Binding(get: { store.lib.master }, set: { store.setMaster($0) }), in: 0...1)
                    .controlSize(.small)
                    .frame(width: 90)
                Text(LevelMeter.dbText(store.lib.master > 0 ? 20 * log10(store.lib.master) : -200)
                        .replacingOccurrences(of: "−0.0", with: "0.0") + " dB")
                    .font(.app(11, .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 58, alignment: .leading)
            }
            .help("Kanade 总输出电平，只影响 Kanade 送出的声音，不改变系统音量。双击喇叭图标恢复 0 dB。")

            Menu {
                Toggle("系统默认输出", isOn: Binding(
                    get: { store.lib.outputDeviceUID == nil },
                    set: { _ in store.setDevice(nil) }))
                Divider()
                ForEach(store.devices) { d in
                    Toggle(d.name, isOn: Binding(
                        get: { store.lib.outputDeviceUID == d.uid },
                        set: { _ in store.setDevice(d.uid) }))
                }
            } label: {
                Label(store.outputName, systemImage: "hifispeaker")
                    .font(.app(12))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .frame(maxWidth: 150)
            .fixedSize(horizontal: true, vertical: false)
            .help("输出设备")

            Toggle(isOn: $store.editing) {
                Label("编辑", systemImage: "slider.horizontal.3")
                    .fixedSize()
            }
            .toggleStyle(.button)
            .help("编辑模式：点选按钮修改设置，拖动交换位置")

            Button {
                store.togglePauseAll()
            } label: {
                Label(live || !anyPaused ? "全部暂停" : "全部继续",
                      systemImage: live || !anyPaused ? "pause.fill" : "play.fill")
                    .font(.app(13, .semibold))
                    .fixedSize()
                    .frame(minWidth: 76)
            }
            .controlSize(.large)
            .disabled(!live && !anyPaused)
            .help("空格键：暂停或继续所有声音")

            Button {
                store.stopAll(hard: NSEvent.modifierFlags.contains(.shift))
            } label: {
                Label("全部停止", systemImage: "stop.fill")
                    .font(.app(13, .semibold))
                    .fixedSize()
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .help("Esc 淡出停止，Shift+Esc 立即停止")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

struct OnAirBadge: View {
    let live: Bool
    let paused: Bool
    var body: some View {
        let on = live || paused
        let tint: Color = live ? .red : .orange
        let text: String = live ? "播出中" : (paused ? "已暂停" : "待机")
        HStack(spacing: 5) {
            Circle().fill(on ? Color.white : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
            Text(text).font(.app(11, .bold))
        }
        .foregroundColor(on ? .white : .secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(on ? tint : Color.primary.opacity(0.06)))
        .shadow(color: on ? tint.opacity(0.6) : Color.clear, radius: 6)
        .animation(.easeOut(duration: 0.15), value: live)
        .animation(.easeOut(duration: 0.15), value: paused)
    }
}

struct BoardTabs: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(store.lib.boards.enumerated()), id: \.element.id) { i, b in
                    let selected = i == store.lib.active
                    let live = store.boardLive(i)
                    Button {
                        store.switchBoard(to: i)
                    } label: {
                        HStack(spacing: 6) {
                            if live { Circle().fill(Color.red).frame(width: 6, height: 6) }
                            Text(store.boardDisplayName(i))
                                .font(.app(13, selected ? .semibold : .regular))
                        }
                        .foregroundColor(selected ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(selected ? Color.primary.opacity(0.10) : Color.clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("重命名…") { store.beginBoardRename(i) }
                        Button("删除这一页…", role: .destructive) { store.requestDeleteBoard(i) }
                            .disabled(store.lib.boards.count < 2)
                    }
                }
                Button {
                    store.addBoard()
                } label: {
                    Image(systemName: "plus")
                        .font(.icon(12, .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("新建页面")
            }
        }
        .frame(minWidth: 120)
    }
}

// MARK: - 状态栏

struct StatusBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let n = store.liveCount
        let pausedN = store.pausedCount
        let status: String = {
            var parts: [String] = []
            if n > 0 { parts.append("正在播放 \(n) 个声音") }
            if pausedN > 0 { parts.append("已暂停 \(pausedN) 个") }
            return parts.isEmpty ? "待机中" : parts.joined(separator: "，")
        }()
        let summary: String = "\(store.boardName)，已用 \(store.usedCount)/\(padsPerBoard) 格"
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                LED(on: n > 0 || pausedN > 0, fading: false, color: n > 0 ? .red : .orange)
                Text(status)
            }
            Divider().frame(height: 12)
            HStack(spacing: 4) { KeyCap(text: "空格"); Text("暂停 / 继续") }
            HStack(spacing: 4) { KeyCap(text: "Esc"); Text("全部停止") }
            HStack(spacing: 4) { KeyCap(text: "⇧"); KeyCap(text: "Esc"); Text("立即停止") }
            HStack(spacing: 4) { KeyCap(text: "Tab"); Text("下一页") }
            HStack(spacing: 4) { KeyCap(text: "⇧"); KeyCap(text: "Tab"); Text("上一页") }
            Text("右键点按钮可以看到更多选项")
            Spacer()
            if !store.midiSources.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "pianokeys").font(.icon(10))
                    Text("MIDI \(store.midiSources.count)")
                }
                .help("已连接的 MIDI 设备：" + store.midiSources.joined(separator: "、"))
                Divider().frame(height: 12)
            }
            Text(summary)
        }
        .font(.app(11))
        .foregroundColor(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

// MARK: - 按钮网格

struct PadGrid: View {
    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(0..<4, id: \.self) { r in
                GridRow {
                    ForEach(0..<8, id: \.self) { c in
                        PadView(index: r * 8 + c)
                    }
                }
            }
        }
    }
}
