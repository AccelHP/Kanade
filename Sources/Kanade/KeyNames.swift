import AppKit

enum KeyNames {
    /// 默认快捷键：四排键盘，对应 32 个按钮
    static let defaults: [(code: UInt16, label: String)] = [
        (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"),
        (12, "Q"), (13, "W"), (14, "E"), (15, "R"), (17, "T"), (16, "Y"), (32, "U"), (34, "I"),
        (0, "A"), (1, "S"), (2, "D"), (3, "F"), (5, "G"), (4, "H"), (38, "J"), (40, "K"),
        (6, "Z"), (7, "X"), (8, "C"), (9, "V"), (11, "B"), (45, "N"), (46, "M"), (43, ",")
    ]

    static let special: [UInt16: String] = [
        49: "空格", 36: "回车", 51: "退格", 76: "小键盘回车",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        82: "小0", 83: "小1", 84: "小2", 85: "小3", 86: "小4",
        87: "小5", 88: "小6", 89: "小7", 91: "小8", 92: "小9"
    ]

    static func label(for event: NSEvent) -> String {
        if let s = special[event.keyCode] { return s }
        if let c = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            return c.uppercased()
        }
        return "键\(event.keyCode)"
    }
}
