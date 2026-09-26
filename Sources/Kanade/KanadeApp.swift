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
