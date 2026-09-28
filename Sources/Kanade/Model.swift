import SwiftUI
import AppKit

let padsPerBoard = 32

// MARK: - 枚举

enum PressMode: String, Codable, CaseIterable, Identifiable {
    case toggle, pause, restart, overlap
    var id: String { rawValue }
    var label: String {
        switch self {
        case .toggle: return "停止（淡出）"
        case .pause: return "暂停 / 继续"
        case .restart: return "从头重播"
        case .overlap: return "叠加再播一遍"
        }
    }
}

enum ChannelMode: String, Codable, CaseIterable, Identifiable {
    case stereo, mono, left, right
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stereo: return "立体声（原样）"
        case .mono: return "单声道（左右混合）"
        case .left: return "只用左声道"
        case .right: return "只用右声道"
        }
    }
    var segment: String {
        switch self {
        case .stereo: return "立体声"
        case .mono: return "混合"
        case .left: return "仅左"
        case .right: return "仅右"
        }
    }
    var badge: String? {
        switch self {
        case .stereo: return nil
        case .mono: return "M"
        case .left: return "L"
        case .right: return "R"
        }
    }
}

enum ReverbPreset: String, Codable, CaseIterable, Identifiable {
    case smallRoom, mediumRoom, largeRoom, mediumHall, largeHall, plate, cathedral
    var id: String { rawValue }
    var label: String {
        switch self {
        case .smallRoom: return "小房间"
        case .mediumRoom: return "中房间"
        case .largeRoom: return "大房间"
        case .mediumHall: return "中厅"
        case .largeHall: return "大厅"
        case .plate: return "板式"
        case .cathedral: return "教堂"
        }
    }
}

// MARK: - 音效设置

struct FXSettings: Codable, Equatable {
    var eqOn = false
    var eqLow: Double = 0
    var eqMid: Double = 0
    var eqHigh: Double = 0
    var pitchOn = false
    var pitch: Double = 0
    var speed: Double = 1
    var reverbOn = false
    var reverbPreset: ReverbPreset = .mediumHall
    var reverbMix: Double = 30
    var delayOn = false
    var delayTime: Double = 0.35
    var delayFeedback: Double = 30
    var delayMix: Double = 25

    var anyOn: Bool { eqOn || pitchOn || reverbOn || delayOn }

    enum CodingKeys: String, CodingKey {
        case eqOn, eqLow, eqMid, eqHigh, pitchOn, pitch, speed
        case reverbOn, reverbPreset, reverbMix, delayOn, delayTime, delayFeedback, delayMix
    }
}

extension FXSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FXSettings()
        eqOn = (try? c.decodeIfPresent(Bool.self, forKey: .eqOn)) ?? d.eqOn
        eqLow = (try? c.decodeIfPresent(Double.self, forKey: .eqLow)) ?? d.eqLow
        eqMid = (try? c.decodeIfPresent(Double.self, forKey: .eqMid)) ?? d.eqMid
        eqHigh = (try? c.decodeIfPresent(Double.self, forKey: .eqHigh)) ?? d.eqHigh
        pitchOn = (try? c.decodeIfPresent(Bool.self, forKey: .pitchOn)) ?? d.pitchOn
        pitch = (try? c.decodeIfPresent(Double.self, forKey: .pitch)) ?? d.pitch
        speed = (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? d.speed
        reverbOn = (try? c.decodeIfPresent(Bool.self, forKey: .reverbOn)) ?? d.reverbOn
        reverbPreset = (try? c.decodeIfPresent(ReverbPreset.self, forKey: .reverbPreset)) ?? d.reverbPreset
        reverbMix = (try? c.decodeIfPresent(Double.self, forKey: .reverbMix)) ?? d.reverbMix
        delayOn = (try? c.decodeIfPresent(Bool.self, forKey: .delayOn)) ?? d.delayOn
        delayTime = (try? c.decodeIfPresent(Double.self, forKey: .delayTime)) ?? d.delayTime
        delayFeedback = (try? c.decodeIfPresent(Double.self, forKey: .delayFeedback)) ?? d.delayFeedback
        delayMix = (try? c.decodeIfPresent(Double.self, forKey: .delayMix)) ?? d.delayMix
    }
}

// MARK: - 按钮

struct Pad: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var fileName: String
    var originalName: String
    var name: String
    var colorIndex: Int
    var keyCode: UInt16? = nil
    var keyLabel: String? = nil
    var volume: Double = 1
    var mode: PressMode = .toggle
    var loop: Bool = false
    var exclusive: Bool = false
    var fade: Double = 0.3
    var duration: Double = 0
    var nameEdited: Bool = false
    var tag: String? = nil
    var startTime: Double = 0
    var endTime: Double? = nil
    var loopStart: Double? = nil
    var loopEnd: Double? = nil
    var channelMode: ChannelMode = .stereo
    var pan: Double = 0
    var fx: FXSettings = FXSettings()
    var midi: MIDITrigger? = nil
    /// 放大增益（dB），0 到 +18
    var gainDB: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, fileName, originalName, name, colorIndex, keyCode, keyLabel, volume, mode
        case loop, exclusive, fade, duration, nameEdited, tag, startTime, endTime
        case loopStart, loopEnd, channelMode, pan, fx, midi, gainDB
    }

    /// 播放范围
    var regionStart: Double { min(max(0, startTime), max(0, duration - 0.005)) }
    var regionEnd: Double { min(max(endTime ?? duration, regionStart + 0.005), max(duration, regionStart + 0.005)) }
    var regionLength: Double { regionEnd - regionStart }
    /// 循环范围（在播放范围之内）
    var loopIn: Double { min(max(loopStart ?? regionStart, regionStart), regionEnd - 0.005) }
    var loopOut: Double { min(max(loopEnd ?? regionEnd, loopIn + 0.005), regionEnd) }
    var isTrimmed: Bool { startTime > 0.001 || endTime != nil }
    var displayName: String { name.isEmpty ? "未命名" : name }
    /// 格子上显示用：中文与英文、数字之间留出约四分之一字宽的空隙
    var displayTitle: String { autospaced(displayName) }
}

extension Pad {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        fileName = try c.decode(String.self, forKey: .fileName)
        originalName = (try? c.decodeIfPresent(String.self, forKey: .originalName)) ?? fileName
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        colorIndex = (try? c.decodeIfPresent(Int.self, forKey: .colorIndex)) ?? 0
        keyCode = try? c.decodeIfPresent(UInt16.self, forKey: .keyCode)
        keyLabel = try? c.decodeIfPresent(String.self, forKey: .keyLabel)
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? 1
        mode = (try? c.decodeIfPresent(PressMode.self, forKey: .mode)) ?? .toggle
        loop = (try? c.decodeIfPresent(Bool.self, forKey: .loop)) ?? false
        exclusive = (try? c.decodeIfPresent(Bool.self, forKey: .exclusive)) ?? false
        fade = (try? c.decodeIfPresent(Double.self, forKey: .fade)) ?? 0.3
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0
        nameEdited = (try? c.decodeIfPresent(Bool.self, forKey: .nameEdited)) ?? false
        tag = try? c.decodeIfPresent(String.self, forKey: .tag)
        startTime = (try? c.decodeIfPresent(Double.self, forKey: .startTime)) ?? 0
        endTime = try? c.decodeIfPresent(Double.self, forKey: .endTime)
        loopStart = try? c.decodeIfPresent(Double.self, forKey: .loopStart)
        loopEnd = try? c.decodeIfPresent(Double.self, forKey: .loopEnd)
        channelMode = (try? c.decodeIfPresent(ChannelMode.self, forKey: .channelMode)) ?? .stereo
        pan = (try? c.decodeIfPresent(Double.self, forKey: .pan)) ?? 0
        fx = (try? c.decodeIfPresent(FXSettings.self, forKey: .fx)) ?? FXSettings()
        midi = try? c.decodeIfPresent(MIDITrigger.self, forKey: .midi)
        gainDB = min(18, max(0, (try? c.decodeIfPresent(Double.self, forKey: .gainDB)) ?? 0))
    }
}

struct Board: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var pads: [Pad?] = Array(repeating: nil, count: padsPerBoard)
}

extension Board {
    /// 没改过名字（空白，或者是“第 N 页”这种默认名）
    var hasDefaultName: Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.range(of: #"^第\s*\d+\s*页$"#, options: .regularExpression) != nil
    }
}

struct Library: Codable {
    var boards: [Board]
    var active: Int = 0
    var master: Double = 0.9
    var stopFade: Double = 0.4
    var outputDeviceUID: String? = nil
    /// 全局操作的 MIDI 映射，键是 GlobalMIDIAction 的 rawValue
    var midiGlobal: [String: MIDITrigger]? = nil
}

// MARK: - MIDI

struct MIDITrigger: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case note, cc }
    var kind: Kind
    var channel: UInt8
    var number: UInt8

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    /// 以中央 C（60）为 C3 的命名方式
    var noteName: String { Self.noteNames[Int(number) % 12] + String(Int(number) / 12 - 2) }
    var shortLabel: String { kind == .note ? noteName : "CC\(number)" }
    var label: String {
        (kind == .note ? "音符 \(noteName)" : "控制器 CC \(number)") + "，通道 \(Int(channel) + 1)"
    }
}

enum GlobalMIDIAction: String, CaseIterable, Identifiable, Codable {
    case stopAll, pauseAll, nextBoard, prevBoard
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stopAll: return "全部停止（淡出）"
        case .pauseAll: return "全部暂停 / 继续"
        case .nextBoard: return "下一页"
        case .prevBoard: return "上一页"
        }
    }
}

enum MIDILearnTarget: Equatable {
    case pad(UUID)
    case global(GlobalMIDIAction)
}

// MARK: - 备份

struct BackupManifest: Codable {
    var app: String = "Kanade"
    var formatVersion: Int = 1
    var appVersion: String
    var exported: Date
    var boards: [Board]
    var midiGlobal: [String: MIDITrigger]?
}

// MARK: - 颜色与标签

struct PaletteEntry {
    let name: String
    let r: Double
    let g: Double
    let b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }
}

let padPalette: [PaletteEntry] = [
    PaletteEntry(name: "蓝", r: 0.27, g: 0.50, b: 0.92),
    PaletteEntry(name: "绿", r: 0.24, g: 0.68, b: 0.42),
    PaletteEntry(name: "橙", r: 0.97, g: 0.58, b: 0.16),
    PaletteEntry(name: "紫", r: 0.58, g: 0.40, b: 0.90),
    PaletteEntry(name: "红", r: 0.93, g: 0.28, b: 0.27),
    PaletteEntry(name: "青", r: 0.13, g: 0.67, b: 0.74),
    PaletteEntry(name: "黄", r: 0.94, g: 0.78, b: 0.18),
    PaletteEntry(name: "粉", r: 0.94, g: 0.40, b: 0.64),
    PaletteEntry(name: "灰", r: 0.52, g: 0.55, b: 0.60)
]

func paletteIndex(_ i: Int) -> Int {
    let n = padPalette.count
    return ((i % n) + n) % n
}
func padColor(_ i: Int) -> Color { padPalette[paletteIndex(i)].color }

let presetTags = ["音乐", "音效", "人声", "开场", "转场", "结束", "掌声", "笑声"]

// MARK: - 时间格式

func formatTime(_ t: Double) -> String {
    let total = max(0, Int(t.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}

func formatPrecise(_ t: Double) -> String {
    let v = max(0, t)
    let m = Int(v / 60)
    return String(format: "%d:%06.3f", m, v - Double(m * 60))
}

func formatDB(_ v: Double) -> String {
    abs(v) < 0.05 ? "0 dB" : String(format: "%+.1f dB", v)
}

func formatPan(_ v: Double) -> String {
    if v < -0.02 { return "左 \(Int((-v * 100).rounded()))" }
    if v > 0.02 { return "右 \(Int((v * 100).rounded()))" }
    return "居中"
}

// MARK: - 中英文混排留白

private func isCJK(_ ch: Character) -> Bool {
    guard let v = ch.unicodeScalars.first?.value else { return false }
    if (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v) { return false }   // 全角标点不加空隙
    return v >= 0x2E80
}

private func isLatinAlnum(_ ch: Character) -> Bool {
    ch.isASCII && (ch.isLetter || ch.isNumber)
}

/// 在中文和英文字母、数字之间插入四分之一字宽的空格（U+2005）
func autospaced(_ s: String) -> String {
    var out = ""
    var prev: Character? = nil
    for ch in s {
        if let p = prev, (isCJK(p) && isLatinAlnum(ch)) || (isLatinAlnum(p) && isCJK(ch)) {
            out.append("\u{2005}")
        }
        out.append(ch)
        prev = ch
    }
    return out
}
