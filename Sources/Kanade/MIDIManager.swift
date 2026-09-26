import CoreMIDI
import Foundation

struct MIDIMessage {
    let kind: MIDITrigger.Kind
    let channel: UInt8
    let number: UInt8
    let value: UInt8
}

/// 接收所有 MIDI 输入设备的消息；设备插拔后自动重新连接
final class MIDIManager {
    var onMessage: ((MIDIMessage) -> Void)?
    var onSourcesChanged: (() -> Void)?
    private(set) var sourceNames: [String] = []

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []
    private var runningStatus: UInt8 = 0      // 只在 MIDI 线程里使用

    init() {
        let status = MIDIClientCreateWithBlock("Kanade" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAllSources() }
            }
        }
        guard status == noErr else { return }
        let portStatus = MIDIInputPortCreateWithBlock(client, "Kanade Input" as CFString, &inPort) { [weak self] list, _ in
            self?.handle(list)
        }
        guard portStatus == noErr else { return }
        connectAllSources()
    }

    func connectAllSources() {
        var names: [String] = []
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let src = MIDIGetSource(i)
            if !connected.contains(src) {
                MIDIPortConnectSource(inPort, src, nil)
                connected.insert(src)
            }
            names.append(Self.name(of: src))
        }
        sourceNames = names
        onSourcesChanged?()
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() {
            return s as String
        }
        return "MIDI 设备"
    }

    private func handle(_ list: UnsafePointer<MIDIPacketList>) {
        let count = Int(list.pointee.numPackets)
        guard count > 0 else { return }
        let offset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet) ?? 4
        var p = UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(to: MIDIPacket.self)
        var messages: [MIDIMessage] = []
        for _ in 0..<count {
            let length = min(Int(p.pointee.length), 256)
            let bytes: [UInt8] = withUnsafeBytes(of: p.pointee.data) { Array($0.prefix(length)) }
            messages += parse(bytes)
            p = UnsafePointer(MIDIPacketNext(p))
        }
        if !messages.isEmpty {
            DispatchQueue.main.async { [weak self] in
                for m in messages { self?.onMessage?(m) }
            }
        }
    }

    /// 解析音符开和控制器消息（支持 running status，忽略其他消息）
    private func parse(_ bytes: [UInt8]) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b >= 0xF8 { i += 1; continue }              // 实时消息
            if b >= 0xF0 {                                 // 系统消息：跳过它的数据
                runningStatus = 0
                i += 1
                while i < bytes.count && bytes[i] < 0x80 { i += 1 }
                continue
            }
            var status = runningStatus
            if b >= 0x80 {
                status = b
                runningStatus = b
                i += 1
            }
            guard status >= 0x80 else { i += 1; continue }
            let type = status & 0xF0
            let channel = status & 0x0F
            let needed = (type == 0xC0 || type == 0xD0) ? 1 : 2
            guard i + needed <= bytes.count else { break }
            let d1 = bytes[i]
            let d2: UInt8 = needed == 2 ? bytes[i + 1] : 0
            i += needed
            switch type {
            case 0x90:
                out.append(MIDIMessage(kind: .note, channel: channel, number: d1, value: d2))
            case 0xB0:
                out.append(MIDIMessage(kind: .cc, channel: channel, number: d1, value: d2))
            default:
                break
            }
        }
        return out
    }
}
