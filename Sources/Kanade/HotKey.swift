import Carbon
import AppKit

/// Kanade 内部全局的空格键：只在 Kanade 处于前台时注册，
/// 这样右键菜单打开、编辑窗口或设置窗口在前面时也能暂停 / 继续。
/// 需要输入文字（重命名、存储文件）时会暂时关闭，避免空格打不出来。
final class SpaceHotKey {
    static var onPress: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var wantActive = false
    private var suspendCount = 0

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            SpaceHotKey.onPress?()
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Kanade 进入 / 离开前台时调用
    func setActive(_ on: Bool) {
        wantActive = on
        update()
    }

    /// 需要输入文字时暂停使用空格快捷键（可嵌套）
    func suspend() {
        suspendCount += 1
        update()
    }

    func resume() {
        suspendCount = max(0, suspendCount - 1)
        update()
    }

    var isRegistered: Bool { ref != nil }

    private func update() {
        let shouldRegister = wantActive && suspendCount == 0
        if shouldRegister, ref == nil {
            let id = EventHotKeyID(signature: OSType(0x4B4E4445), id: 1)   // 'KNDE'
            var newRef: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(kVK_Space), 0, id, GetApplicationEventTarget(), 0, &newRef) == noErr {
                ref = newRef
            }
        } else if !shouldRegister, let r = ref {
            UnregisterEventHotKey(r)
            ref = nil
        }
    }
}
