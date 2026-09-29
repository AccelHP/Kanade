import Foundation
import AppKit

/// 运行记录（黑匣子）：~/Library/Logs/Kanade/kanade.log
/// 只记录程序的步骤和耗时，不包含音频内容。超过 1 MB 自动轮换。
enum Log {
    private static let queue = DispatchQueue(label: "kanade.log", qos: .utility)
    private static let lock = NSLock()
    private static var current = "启动"
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Kanade", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kanade.log")
    }()

    /// 最近一次记录的步骤（卡住时用来判断卡在哪里）
    static var lastStep: String {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    static func step(_ s: String) {
        lock.lock(); current = s; lock.unlock()
        write(s)
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber,
               size.intValue > 1_000_000 {
                let old = fileURL.deletingLastPathComponent().appendingPathComponent("kanade.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}

/// 后台监视器：界面超过 3 秒没有响应时记下最后的步骤，恢复后记下持续时间
final class MainThreadWatchdog {
    private let lock = NSLock()
    private var lastPong = ProcessInfo.processInfo.systemUptime

    func start() {
        let thread = Thread { [weak self] in
            var stallStart: TimeInterval? = nil
            while true {
                Thread.sleep(forTimeInterval: 1)
                guard let self else { return }
                DispatchQueue.main.async {
                    self.lock.lock()
                    self.lastPong = ProcessInfo.processInfo.systemUptime
                    self.lock.unlock()
                }
                self.lock.lock()
                let pong = self.lastPong
                self.lock.unlock()
                let now = ProcessInfo.processInfo.systemUptime
                let gap = now - pong
                if gap > 3, stallStart == nil {
                    stallStart = pong
                    Log.write("⚠️ 界面无响应已超过 3 秒，最后的步骤：\(Log.lastStep)")
                } else if gap < 1.5, let s = stallStart {
                    Log.write(String(format: "界面恢复响应，卡住了约 %.1f 秒", now - s))
                    stallStart = nil
                }
            }
        }
        thread.name = "kanade.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
