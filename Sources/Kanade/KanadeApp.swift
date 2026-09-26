import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct KanadeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Kanade", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1380, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .importExport) {
                Button("导入备份…") { store.importBackup() }
                Divider()
                Button("导出全部页面…") { store.exportBackup(currentPageOnly: false) }
                Button("导出当前页…") { store.exportBackup(currentPageOnly: true) }
            }
            CommandMenu("MIDI") {
                let devices: String = store.midiSources.isEmpty
                    ? "未检测到 MIDI 设备"
                    : "已连接：" + store.midiSources.joined(separator: "、")
                Text(devices)
                Divider()
                ForEach(GlobalMIDIAction.allCases) { a in
                    let title: String = "学习：" + a.label + (store.globalMIDILabel(a).map { "（当前 \($0)）" } ?? "")
                    Button(title) { store.beginMIDILearn(.global(a)) }
                }
                Divider()
                Button("清除全部全局 MIDI 设置") { store.clearGlobalMIDI() }
            }
            CommandMenu("播放") {
                Button("全部暂停 / 继续（空格）") { store.togglePauseAll() }
                Divider()
                Button("全部停止（淡出）") { store.stopAll(hard: false) }
                Button("全部立即停止") { store.stopAll(hard: true) }
                Divider()
                Button("上一页（⇧Tab 或 [）") { store.switchBoard(by: -1) }
                Button("下一页（Tab 或 ]）") { store.switchBoard(by: 1) }
                Button("新建页面") { store.addBoard() }
                Divider()
                Toggle("编辑模式", isOn: $store.editing)
                    .keyboardShortcut("e", modifiers: .command)
            }
        }
    }
}
