import SwiftUI
import AppKit

// MARK: - 个性化设置（保存在系统偏好设置里，不随备份导出）

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

enum NameSize: String, CaseIterable, Identifiable {
    case small, standard, large
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        }
    }
    var scale: CGFloat {
        switch self {
        case .small: return 0.82
        case .standard: return 1
        case .large: return 1.18
        }
    }
}

enum EditorSpaceAction: String, CaseIterable, Identifiable {
    case pauseAll, previewCurrent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pauseAll: return "全部暂停 / 继续"
        case .previewCurrent: return "播放或停止正在编辑的格子"
        }
    }
}

enum NewPadModeRule: String, CaseIterable, Identifiable {
    case byDuration, allRestart, allStop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .byDuration: return "按时长自动"
        case .allRestart: return "全部“从头重播”"
        case .allStop: return "全部“停止”"
        }
    }
}

enum ClipHoldMode: String, CaseIterable, Identifiable {
    case manual, auto3s, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: return "保持到手动复位"
        case .auto3s: return "3 秒后自动熄灭"
        case .none: return "不保持"
        }
    }
}

enum TimeDisplay: String, CaseIterable, Identifiable {
    case remaining, elapsed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .remaining: return "剩余时间"
        case .elapsed: return "已播放时间"
        }
    }
}

final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var theme: ThemeMode { didSet { d.set(theme.rawValue, forKey: "theme"); applyTheme() } }
    @Published var nameSize: NameSize { didSet { d.set(nameSize.rawValue, forKey: "nameSize") } }
    @Published var editorSpace: EditorSpaceAction { didSet { d.set(editorSpace.rawValue, forKey: "editorSpace") } }
    @Published var editorAutoPlay: Bool { didSet { d.set(editorAutoPlay, forKey: "editorAutoPlay") } }
    @Published var stopFade: Double { didSet { d.set(stopFade, forKey: "stopFade") } }
    @Published var newPadMode: NewPadModeRule { didSet { d.set(newPadMode.rawValue, forKey: "newPadMode") } }
    @Published var shortThreshold: Double { didSet { d.set(shortThreshold, forKey: "shortThreshold") } }
    @Published var clipHold: ClipHoldMode { didSet { d.set(clipHold.rawValue, forKey: "clipHold") } }
    @Published var showWaveform: Bool { didSet { d.set(showWaveform, forKey: "showWaveform") } }
    @Published var timeDisplay: TimeDisplay { didSet { d.set(timeDisplay.rawValue, forKey: "timeDisplay") } }

    init() {
        theme = ThemeMode(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        nameSize = NameSize(rawValue: d.string(forKey: "nameSize") ?? "") ?? .standard
        editorSpace = EditorSpaceAction(rawValue: d.string(forKey: "editorSpace") ?? "") ?? .pauseAll
        editorAutoPlay = d.object(forKey: "editorAutoPlay") as? Bool ?? false
        stopFade = d.object(forKey: "stopFade") as? Double ?? 0.4
        newPadMode = NewPadModeRule(rawValue: d.string(forKey: "newPadMode") ?? "") ?? .allStop
        shortThreshold = d.object(forKey: "shortThreshold") as? Double ?? 15
        clipHold = ClipHoldMode(rawValue: d.string(forKey: "clipHold") ?? "") ?? .manual
        showWaveform = d.object(forKey: "showWaveform") as? Bool ?? true
        timeDisplay = TimeDisplay(rawValue: d.string(forKey: "timeDisplay") ?? "") ?? .remaining
    }

    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 新加入的音频默认用哪种“再按一次”
    func defaultMode(forDuration duration: Double) -> PressMode {
        switch newPadMode {
        case .byDuration: return duration < shortThreshold ? .restart : .toggle
        case .allRestart: return .restart
        case .allStop: return .toggle
        }
    }

    func resetAll() {
        theme = .system
        nameSize = .standard
        editorSpace = .pauseAll
        editorAutoPlay = false
        stopFade = 0.4
        newPadMode = .allStop
        shortThreshold = 15
        clipHold = .manual
        showWaveform = true
        timeDisplay = .remaining
    }
}

// MARK: - 设置窗口（⌘,）

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.theme) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("格子名称字号", selection: $settings.nameSize) {
                    ForEach(NameSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("格子显示") {
                Toggle("显示迷你波形", isOn: $settings.showWaveform)
                Picker("时间显示", selection: $settings.timeDisplay) {
                    ForEach(TimeDisplay.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("波形编辑窗口") {
                Picker("空格键", selection: $settings.editorSpace) {
                    ForEach(EditorSpaceAction.allCases) { Text($0.label).tag($0) }
                }
                Toggle("打开窗口时自动播放", isOn: $settings.editorAutoPlay)
            }

            Section("播放") {
                HStack {
                    Text("全部停止（Esc）的淡出")
                    Slider(value: $settings.stopFade, in: 0...3, step: 0.1)
                    Text(String(format: "%.1f 秒", settings.stopFade))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Toggle("短音效加入时默认“从头重播”", isOn: Binding(
                    get: { settings.newPadMode == .byDuration },
                    set: { settings.newPadMode = $0 ? .byDuration : .allStop }))
                if settings.newPadMode == .byDuration {
                    HStack {
                        Text("短音效的时长界限")
                        Slider(value: $settings.shortThreshold, in: 3...60, step: 1)
                        Text("\(Int(settings.shortThreshold)) 秒")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Text("关闭时，新加入的音频一律默认“停止”。只影响之后新加入的音频。")
                    .font(.app(11))
                    .foregroundColor(.secondary)
            }

            Section("电平表") {
                Picker("过载指示", selection: $settings.clipHold) {
                    ForEach(ClipHoldMode.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("恢复默认设置") { settings.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .font(.app(13))
        .frame(width: 540, height: 660)
    }
}
