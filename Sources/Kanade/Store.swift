import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Combine

/// 总输出峰值表：瞬间上升、每秒回落 20 dB、峰值保持 1.5 秒、过载锁存
final class MeterModel: ObservableObject {
    static let floor: Double = -60

    @Published private(set) var level: [Double] = [MeterModel.floor, MeterModel.floor]
    @Published private(set) var hold: [Double] = [MeterModel.floor, MeterModel.floor]
    @Published private(set) var clipped = false

    private var holdTime: [TimeInterval] = [0, 0]
    private var lastTime: TimeInterval = 0
    private var clipTime: TimeInterval = 0
    var clipMode: ClipHoldMode = .manual
    private let releasePerSecond = 20.0
    private let holdSeconds = 1.5

    func update(_ l: Float, _ r: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastTime == 0 ? 0 : min(0.25, now - lastTime)
        lastTime = now
        var newLevel = level
        var newHold = hold
        var clip = false
        for (i, v) in [l, r].enumerated() {
            if v >= 0.9999 { clip = true }
            let db = v > 0 ? max(Self.floor, 20 * log10(Double(v))) : Self.floor
            // 瞬间上升，按时间匀速回落，最低回到刻度底部（完全熄灭）
            newLevel[i] = max(db, level[i] - releasePerSecond * dt, Self.floor)
            if newLevel[i] >= hold[i] {
                newHold[i] = newLevel[i]
                holdTime[i] = now
            } else if now - holdTime[i] > holdSeconds {
                newHold[i] = max(newLevel[i], hold[i] - releasePerSecond * dt, Self.floor)
            }
        }
        if newLevel != level { level = newLevel }
        if newHold != hold { hold = newHold }
        if clip { clipTime = now }
        let want: Bool
        switch clipMode {
        case .manual:
            want = clipped || clip
        case .auto3s:
            want = clip || (clipped && now - clipTime < 3)
        case .none:
            want = now - clipTime < 0.15
        }
        if want != clipped { clipped = want }
    }

    func resetClip() { clipped = false }
}

struct EditorTarget: Identifiable {
    let id: UUID
}

enum TextPrompt {
    case padName(UUID)
    case boardName(Int)
    case tag(UUID)

    var title: String {
        switch self {
        case .padName: return "重命名按钮"
        case .boardName: return "重命名页面"
        case .tag: return "自定义标签"
        }
    }
}

final class Store: ObservableObject {
    @Published var lib: Library
    @Published var editing = false {
        didSet { if !editing { selected = nil } }
    }
    @Published var selected: Int? = nil
    @Published var capturingPadID: UUID? = nil
    @Published var liveTick = 0
    @Published var devices: [OutputDevice] = []
    @Published var message: String? = nil
    @Published var editorTarget: EditorTarget? = nil
    @Published var prompt: TextPrompt? = nil {
        didSet {
            if (oldValue == nil) != (prompt == nil) {
                if prompt != nil { spaceKey.suspend() } else { spaceKey.resume() }
            }
        }
    }
    @Published var promptText = ""
    @Published var pendingDeleteBoard: Int? = nil
    @Published var midiLearn: MIDILearnTarget? = nil
    @Published var midiSources: [String] = []

    let meter = MeterModel()
    let engine = AudioEngine()
    let midi = MIDIManager()
    let settings = AppSettings()
    let spaceKey = SpaceHotKey()
    /// 主窗口（用来判断按键发生在哪个窗口）
    weak var mainWindow: NSWindow?
    /// 刚刚移动过的格子，外边框闪烁提示
    @Published var flashIDs: Set<UUID> = []
    private var settingsObserver: AnyCancellable?
    private var ccState: [UInt16: UInt8] = [:]
    private var tickPending = false
    private let audioDir: URL
    private let libraryURL: URL
    private var saveWork: DispatchWorkItem?
    private var monitor: Any?
    private var msgToken = 0
    /// 每页最近一次打开的时间，内存不够时先释放最久没打开的页
    private var boardVisited: [UUID: TimeInterval] = [:]

    /// Esc、[、]、Tab 留给全局操作
    private static let reserved: Set<UInt16> = [53, 33, 30, 48]
    /// 没有分配给按钮时照常交给系统的键
    private static let passthrough: Set<UInt16> = [48, 36, 49, 51, 123, 124, 125, 126]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kanade", isDirectory: true)
        audioDir = base.appendingPathComponent("Audio", isDirectory: true)
        libraryURL = base.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        var loaded = Library(boards: [Board(name: "第 1 页")])
        if let data = try? Data(contentsOf: libraryURL),
           let decoded = try? JSONDecoder().decode(Library.self, from: data),
           !decoded.boards.isEmpty {
            loaded = decoded
        }
        var missing = 0
        for b in loaded.boards.indices {
            var pads = loaded.boards[b].pads
            if pads.count < padsPerBoard {
                pads += Array(repeating: nil, count: padsPerBoard - pads.count)
            }
            if pads.count > padsPerBoard { pads = Array(pads.prefix(padsPerBoard)) }
            for i in pads.indices {
                if let p = pads[i],
                   !FileManager.default.fileExists(atPath: audioDir.appendingPathComponent(p.fileName).path) {
                    pads[i] = nil
                    missing += 1
                }
            }
            loaded.boards[b].pads = pads
        }
        if loaded.active < 0 || loaded.active >= loaded.boards.count { loaded.active = 0 }
        _lib = Published(initialValue: loaded)

        engine.master = loaded.master
        // 一次操作里的多次状态变化合并成一次界面刷新
        engine.onChange = { [weak self] in
            guard let self, !self.tickPending else { return }
            self.tickPending = true
            DispatchQueue.main.async {
                self.tickPending = false
                self.liveTick &+= 1
            }
        }
        let meterRef = meter
        engine.onMeter = { l, r in meterRef.update(l, r) }

        devices = AudioDevices.outputs()
        if let uid = loaded.outputDeviceUID {
            if let d = devices.first(where: { $0.uid == uid }) {
                engine.setOutputDevice(d.deviceID)
            } else {
                lib.outputDeviceUID = nil
            }
        }
        loadBoards()

        // 键位固定在格子上：旧数据里的自定义键、被清除的键一律恢复成所在位置的默认键
        for b in lib.boards.indices { normalizeKeys(board: b) }

        // 个性化设置变化时刷新界面
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.meter.clipMode = self.settings.clipHold
                self.objectWillChange.send()
            }
        }
        meter.clipMode = settings.clipHold
        settings.applyTheme()

        // Kanade 内部全局的空格键
        SpaceHotKey.onPress = { [weak self] in self?.handleSpace() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.spaceKey.setActive(true)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.spaceKey.setActive(false)
        }
        if NSApp.isActive { spaceKey.setActive(true) }

        midi.onMessage = { [weak self] m in self?.handleMIDI(m) }
        midi.onSourcesChanged = { [weak self] in self?.midiSources = self?.midi.sourceNames ?? [] }
        midiSources = midi.sourceNames

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.saveNow()
        }
        if missing > 0 { flash("有 \(missing) 个音频文件找不到了，对应的按钮已清空。") }
    }

    // MARK: 读取

    var pads: [Pad?] { lib.boards[lib.active].pads }
    var boardName: String { boardDisplayName(lib.active) }

    /// 页面显示名：没改过名字的按当前位置自动编号（删掉前面的页，后面的自动前推）
    func boardDisplayName(_ i: Int) -> String {
        guard lib.boards.indices.contains(i) else { return "" }
        return lib.boards[i].hasDefaultName ? "第 \(i + 1) 页" : lib.boards[i].name
    }
    var usedCount: Int { pads.compactMap { $0 }.count }
    var liveCount: Int { engine.liveCount }
    var pausedCount: Int { engine.pausedCount }

    func pad(_ i: Int) -> Pad? { lib.boards[lib.active].pads[i] }

    /// 格子对应的键位（固定不变）
    func defaultKeyLabel(for i: Int) -> String? {
        guard KeyNames.defaults.indices.contains(i) else { return nil }
        return KeyNames.defaults[i].label
    }

    func locate(_ id: UUID) -> (board: Int, index: Int)? {
        for b in lib.boards.indices {
            if let i = lib.boards[b].pads.firstIndex(where: { $0?.id == id }) { return (b, i) }
        }
        return nil
    }

    func padByID(_ id: UUID) -> Pad? {
        guard let loc = locate(id) else { return nil }
        return lib.boards[loc.board].pads[loc.index]
    }

    func url(for pad: Pad) -> URL { audioDir.appendingPathComponent(pad.fileName) }

    func boardLive(_ b: Int) -> Bool {
        lib.boards[b].pads.contains { p in
            if let p { return engine.hasVoices(p.id) }
            return false
        }
    }

    // MARK: 保存

    func save() {
        saveWork?.cancel()
        let snapshot = lib
        let url = libraryURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        if let data = try? JSONEncoder().encode(lib) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    // MARK: 载入音频

    /// 载入所有页面的音频：当前页优先，其他页在后台依次载入。切换页面时不再释放。
    func loadBoards() {
        let active = lib.active
        boardVisited[lib.boards[active].id] = ProcessInfo.processInfo.systemUptime
        let current = pads.compactMap { $0 }
        for p in current { request(p, priority: .veryHigh) }
        engine.prioritize(current.map { $0.id })
        for b in lib.boards.indices where b != active {
            for p in lib.boards[b].pads.compactMap({ $0 }) { request(p, priority: .normal) }
        }
    }

    private func request(_ p: Pad, priority: Operation.QueuePriority) {
        switch engine.status(p.id) {
        case .ready, .loading:
            return
        case .none, .failed:
            ensureLoaded(p, priority: priority)
        }
    }

    func ensureLoaded(_ p: Pad, force: Bool = false, priority: Operation.QueuePriority = .veryHigh) {
        engine.load(p, url: url(for: p), force: force, priority: priority) { [weak self] ok in
            guard let self else { return }
            if ok {
                if let latest = self.padByID(p.id) {
                    self.engine.applySettings(latest)
                    self.engine.preparePlan(latest)
                }
                self.enforceMemoryBudget()
            } else {
                self.flash("无法载入“\(p.displayName)”。")
            }
            self.liveTick &+= 1
        }
    }

    /// 已载入的音频超过电脑内存的三分之一时，释放最久没打开的页面（当前页和正在播放的不动）
    private func enforceMemoryBudget() {
        let budget = Int64(ProcessInfo.processInfo.physicalMemory / 3)
        var total = engine.loadedBytes
        guard total > budget else { return }
        let activeID = lib.boards[lib.active].id
        let order = lib.boards
            .filter { $0.id != activeID }
            .sorted { (boardVisited[$0.id] ?? 0) < (boardVisited[$1.id] ?? 0) }
        for b in order {
            for p in b.pads.compactMap({ $0 }) where engine.isLoaded(p.id) && !engine.hasVoices(p.id) {
                total -= engine.bytes(p.id)
                engine.unload(p.id)
                if total <= budget { return }
            }
        }
    }

    func reload(id: UUID) {
        guard let p = padByID(id) else { return }
        ensureLoaded(p, force: true)
    }

    // MARK: 播放

    func trigger(index i: Int) {
        guard let p = pad(i) else { return }
        play(p)
    }

    func triggerByID(_ id: UUID) {
        guard let p = padByID(id) else { return }
        play(p)
    }

    private func play(_ p: Pad) {
        guard engine.isLoaded(p.id) else {
            ensureLoaded(p)
            flash("“\(p.displayName)”还在载入，请稍等一下。")
            return
        }
        if !engine.trigger(p) { flash("音频输出无法启动，请检查输出设备。") }
    }

    func stopPad(_ id: UUID) {
        guard let p = padByID(id) else { return }
        engine.stop(id, fade: p.fade)
    }

    func preview(_ id: UUID, from t: Double) {
        guard let p = padByID(id) else { return }
        engine.preview(p, from: t)
    }

    func stopAll(hard: Bool) {
        engine.stopAll(fade: hard ? 0 : settings.stopFade)
    }

    func togglePauseAll() { engine.togglePauseAll() }
    func pausePad(_ id: UUID) { engine.pause(id) }
    func resumePad(_ id: UUID) { engine.resume(id) }

    /// 鼠标按下按钮
    func tap(_ i: Int) {
        if pad(i) == nil {
            requestPanel(for: i, replace: false)
            return
        }
        if editing {
            selected = i
            return
        }
        trigger(index: i)
    }

    func setMaster(_ v: Double) {
        lib.master = v
        engine.master = v
        save()
    }

    func setDevice(_ uid: String?) {
        guard uid != lib.outputDeviceUID else { return }
        lib.outputDeviceUID = uid
        let dev = uid.flatMap { u in devices.first(where: { $0.uid == u })?.deviceID }
        engine.setOutputDevice(dev)
        save()
    }

    var outputName: String {
        if let uid = lib.outputDeviceUID, let d = devices.first(where: { $0.uid == uid }) { return d.name }
        return "系统默认输出"
    }

    func refreshDevices() {
        devices = AudioDevices.outputs()
        if let uid = lib.outputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            setDevice(nil)
            flash("之前选的输出设备不在了，已改回系统默认。")
        }
    }

    // MARK: 页面

    func switchBoard(to i: Int) {
        guard i != lib.active, lib.boards.indices.contains(i) else { return }
        lib.active = i
        selected = nil
        capturingPadID = nil
        loadBoards()
        save()
    }

    func switchBoard(by delta: Int) {
        let n = lib.boards.count
        guard n > 1 else { return }
        switchBoard(to: (lib.active + delta + n) % n)
    }

    func addBoard() {
        lib.boards.append(Board(name: ""))
        lib.active = lib.boards.count - 1
        selected = nil
        save()
    }

    func renameBoard(_ b: Int, _ name: String) {
        guard lib.boards.indices.contains(b) else { return }
        lib.boards[b].name = name
        save()
    }

    func requestDeleteBoard(_ b: Int) {
        guard lib.boards.count > 1 else {
            flash("至少要保留一页。")
            return
        }
        pendingDeleteBoard = b
    }

    func confirmDeleteBoard() {
        guard let b = pendingDeleteBoard, lib.boards.count > 1, lib.boards.indices.contains(b) else { return }
        pendingDeleteBoard = nil
        for p in lib.boards[b].pads.compactMap({ $0 }) {
            engine.unload(p.id, force: true)
            try? FileManager.default.removeItem(at: url(for: p))
        }
        lib.boards.remove(at: b)
        if lib.active >= lib.boards.count || lib.active > b { lib.active = max(0, lib.active - 1) }
        selected = nil
        loadBoards()
        save()
    }

    // MARK: 编辑按钮

    func editPad(board b: Int, index i: Int, _ change: (inout Pad) -> Void) {
        guard var p = lib.boards[b].pads[i] else { return }
        let before = p
        change(&p)
        guard p != before else { return }
        lib.boards[b].pads[i] = p
        engine.applySettings(p)
        if p.channelMode != before.channelMode {
            ensureLoaded(p, force: true)
        } else if PlanKey(p) != PlanKey(before) {
            engine.preparePlan(p)
        }
        save()
    }

    func editPad(_ i: Int, _ change: (inout Pad) -> Void) {
        editPad(board: lib.active, index: i, change)
    }

    func editPad(id: UUID, _ change: (inout Pad) -> Void) {
        guard let loc = locate(id) else { return }
        editPad(board: loc.board, index: loc.index, change)
    }

    func padBinding<T>(_ i: Int, _ kp: WritableKeyPath<Pad, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { [weak self] in self?.pad(i)?[keyPath: kp] ?? fallback },
            set: { [weak self] v in self?.editPad(i) { $0[keyPath: kp] = v } }
        )
    }

    func padBinding<T>(id: UUID, _ kp: WritableKeyPath<Pad, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { [weak self] in self?.padByID(id)?[keyPath: kp] ?? fallback },
            set: { [weak self] v in self?.editPad(id: id) { $0[keyPath: kp] = v } }
        )
    }

    func padNameBinding(id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.padByID(id)?.name ?? "" },
            set: { [weak self] v in self?.editPad(id: id) { $0.name = v; $0.nameEdited = true } }
        )
    }

    /// 批量设置当前页的“再按一次”；shortOnly 为 true 时只改 15 秒以内的格子
    func setModeForBoard(_ mode: PressMode, shortOnly: Bool) {
        let b = lib.active
        var n = 0
        for i in 0..<padsPerBoard {
            guard let p = lib.boards[b].pads[i] else { continue }
            if shortOnly && p.duration >= 15 { continue }
            if p.mode != mode {
                lib.boards[b].pads[i]?.mode = mode
                n += 1
            }
        }
        save()
        flash(n > 0 ? "已修改 \(n) 个格子。" : "没有需要修改的格子。")
    }

    /// 自动增益：把峰值放大到 −1 dBFS（最多 +18 dB）
    func autoGain(id: UUID) {
        guard let peaks = engine.peaks(id) else {
            flash("音频还在载入，请稍后再试。")
            return
        }
        let peak = max(peaks.left.max() ?? 0, peaks.right.max() ?? 0)
        guard peak > 0.00001 else {
            flash("这段音频几乎没有声音。")
            return
        }
        let gain = min(18, max(0, -1 - 20 * log10(Double(peak))))
        editPad(id: id) { $0.gainDB = (gain * 2).rounded() / 2 }
        if gain < 0.25 {
            flash("这段音频已经接近满格，不需要再放大。")
        } else {
            flash(String(format: "已放大 %.1f dB。", gain))
        }
    }

    func setTag(id: UUID, _ tag: String?) {
        let t = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        editPad(id: id) { $0.tag = (t?.isEmpty ?? true) ? nil : t }
    }

    func clearPad(id: UUID) {
        guard let loc = locate(id), let p = lib.boards[loc.board].pads[loc.index] else { return }
        engine.unload(p.id, force: true)
        try? FileManager.default.removeItem(at: url(for: p))
        lib.boards[loc.board].pads[loc.index] = nil
        if loc.board == lib.active && selected == loc.index { selected = nil }
        if editorTarget?.id == id { editorTarget = nil }
        save()
    }

    func swap(_ a: Int, _ b: Int) {
        guard a != b, (0..<padsPerBoard).contains(a), (0..<padsPerBoard).contains(b) else { return }
        movePads(board: lib.active, a, b)
        if selected == a { selected = b } else if selected == b { selected = a }
        save()
    }

    /// 互换两个格子里的音频：键位留在格子上，颜色跟着行走，并闪烁提示
    private func movePads(board bd: Int, _ a: Int, _ b: Int) {
        lib.boards[bd].pads.swapAt(a, b)
        retargetColor(board: bd, from: a, to: b)
        retargetColor(board: bd, from: b, to: a)
        normalizeKeys(board: bd)
        let ids = [lib.boards[bd].pads[a]?.id, lib.boards[bd].pads[b]?.id].compactMap { $0 }
        flashMoved(ids)
    }

    /// 用的是原来那一行默认颜色的，换成新一行的默认颜色；手动改过颜色的保持不变
    private func retargetColor(board bd: Int, from old: Int, to new: Int) {
        guard var p = lib.boards[bd].pads[new] else { return }
        if paletteIndex(p.colorIndex) == old / 8 {
            p.colorIndex = new / 8
            lib.boards[bd].pads[new] = p
        }
    }

    /// 让每个格子的键位都等于它所在位置的默认键
    private func normalizeKeys(board bd: Int) {
        for i in 0..<min(padsPerBoard, lib.boards[bd].pads.count) where lib.boards[bd].pads[i] != nil {
            let def = KeyNames.defaults[i]
            if lib.boards[bd].pads[i]?.keyCode != def.code || lib.boards[bd].pads[i]?.keyLabel != def.label {
                lib.boards[bd].pads[i]?.keyCode = def.code
                lib.boards[bd].pads[i]?.keyLabel = def.label
            }
        }
    }

    private func flashMoved(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        flashIDs.formUnion(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.flashIDs.subtract(ids)
        }
    }

    func openEditor(_ i: Int) {
        guard let p = pad(i) else { return }
        ensureLoaded(p)
        editorTarget = EditorTarget(id: p.id)
        if settings.editorAutoPlay && engine.isLoaded(p.id) && !engine.hasVoices(p.id) {
            trigger(index: i)
        }
    }

    // MARK: 文字输入（重命名 / 自定义标签）

    func beginRename(id: UUID) {
        guard let p = padByID(id) else { return }
        promptText = p.name
        prompt = .padName(id)
    }

    func beginBoardRename(_ b: Int) {
        guard lib.boards.indices.contains(b) else { return }
        promptText = lib.boards[b].hasDefaultName ? "" : lib.boards[b].name
        prompt = .boardName(b)
    }

    func beginTag(id: UUID) {
        guard let p = padByID(id) else { return }
        promptText = p.tag ?? ""
        prompt = .tag(id)
    }

    func commitPrompt() {
        guard let p = prompt else { return }
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch p {
        case .padName(let id):
            editPad(id: id) { $0.name = text; $0.nameEdited = true }
        case .boardName(let b):
            renameBoard(b, text)
        case .tag(let id):
            setTag(id: id, text)
        }
        prompt = nil
    }

    // MARK: 移动到其他键位（键位固定在格子上，移动的是音频）

    func beginKeyCapture(id: UUID) {
        midiLearn = nil
        capturingPadID = id
    }

    private func setKey(_ code: UInt16, label: String) {
        guard let id = capturingPadID, let loc = locate(id) else { return }
        guard let t = defaultIndex(for: code) else {
            flash("只能移动到格子对应的键位上。")
            return
        }
        let b = loc.board
        let i = loc.index
        guard t != i else { return }
        movePads(board: b, i, t)
        if b == lib.active {
            if selected == i { selected = t } else if selected == t { selected = i }
        }
        if let name = lib.boards[b].pads[t]?.displayName {
            flash("“\(name)”已移到 \(KeyNames.defaults[t].label) 键的位置。")
        }
        save()
    }

    private func defaultIndex(for code: UInt16) -> Int? {
        KeyNames.defaults.firstIndex { $0.code == code }
    }

    // MARK: 添加音频

    func requestPanel(for i: Int, replace: Bool) {
        DispatchQueue.main.async { self.openPanel(for: i, replace: replace) }
    }

    private func openPanel(for i: Int, replace: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = !replace
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = replace ? "选择新的音频文件" : "选择音频文件（可以多选）"
        spaceKey.suspend()
        let result = panel.runModal()
        spaceKey.resume()
        if result == .OK {
            addFiles(replace ? Array(panel.urls.prefix(1)) : panel.urls, at: i)
        }
    }

    private func isAudio(_ url: URL) -> Bool {
        if let t = UTType(filenameExtension: url.pathExtension) { return t.conforms(to: .audio) }
        return false
    }

    func addFiles(_ urls: [URL], at start: Int) {
        let files = urls.filter { isAudio($0) }
        guard !files.isEmpty else {
            flash("请选择音频文件，比如 MP3、WAV、AIFF 或 M4A。")
            return
        }
        let b = lib.active
        let current = lib.boards[b].pads
        var slots = [start]
        for j in (start + 1)..<padsPerBoard where slots.count < files.count && current[j] == nil {
            slots.append(j)
        }
        for j in 0..<start where slots.count < files.count && current[j] == nil {
            slots.append(j)
        }
        var ok = 0
        for (k, slot) in slots.enumerated() where assign(files[k], to: slot, board: b) { ok += 1 }
        if files.count > slots.count {
            flash("这一页放不下了，有 \(files.count - slots.count) 个文件没有添加。新建一页后再拖进去。")
        } else if ok > 1 {
            flash("已添加 \(ok) 个音频。")
        }
    }

    @discardableResult
    private func assign(_ src: URL, to i: Int, board b: Int) -> Bool {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }

        let ext = src.pathExtension.lowercased()
        let stored = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let dest = audioDir.appendingPathComponent(stored)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            flash("复制“\(src.lastPathComponent)”失败。")
            return false
        }
        guard let f = try? AVAudioFile(forReading: dest), f.length > 0 else {
            try? FileManager.default.removeItem(at: dest)
            flash("无法读取“\(src.lastPathComponent)”，请换成 MP3、WAV、AIFF 或 M4A。")
            return false
        }
        let duration = Double(f.length) / f.processingFormat.sampleRate

        var pad: Pad
        if let old = lib.boards[b].pads[i] {
            engine.unload(old.id, force: true)
            try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(old.fileName))
            pad = old
            pad.fileName = stored
            pad.originalName = src.lastPathComponent
            pad.startTime = 0
            pad.endTime = nil
            pad.loopStart = nil
            pad.loopEnd = nil
        } else {
            let def = KeyNames.defaults[i]
            let used = lib.boards[b].pads.contains { $0?.keyCode == def.code }
            pad = Pad(fileName: stored,
                      originalName: src.lastPathComponent,
                      name: "",
                      colorIndex: i / 8,
                      keyCode: used ? nil : def.code,
                      keyLabel: used ? nil : def.label)
        }
        pad.duration = duration
        if lib.boards[b].pads[i] == nil {
            // 新格子：15 秒以内的短音效默认“从头重播”，连点就连响；较长的音乐默认“停止”
            pad.mode = settings.defaultMode(forDuration: duration)
        }
        if !pad.nameEdited { pad.name = src.deletingPathExtension().lastPathComponent }
        lib.boards[b].pads[i] = pad
        ensureLoaded(pad, force: true)
        save()
        return true
    }

    /// 处理拖放：Finder 拖来的文件，或编辑模式下拖动按钮交换位置
    func handleDrop(_ providers: [NSItemProvider], at i: Int) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        if !fileProviders.isEmpty {
            var urls = [URL?](repeating: nil, count: fileProviders.count)
            let lock = NSLock()
            let group = DispatchGroup()
            for (k, p) in fileProviders.enumerated() {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var u: URL?
                    if let d = item as? Data { u = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let url = item as? URL { u = url }
                    lock.lock()
                    urls[k] = u
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                self?.addFiles(urls.compactMap { $0 }, at: i)
            }
            return true
        }
        if editing, let p = providers.first, p.canLoadObject(ofClass: NSString.self) {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? NSString else { return }
                let str = s as String
                let prefix = "kanade-pad:"
                guard str.hasPrefix(prefix), let from = Int(str.dropFirst(prefix.count)) else { return }
                DispatchQueue.main.async { [weak self] in self?.swap(from, i) }
            }
            return true
        }
        return false
    }

    // MARK: 键盘

    func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e) ? nil : e
        }
    }

    /// 空格：Kanade 内部全局。编辑窗口里按设置决定是全部暂停，还是试听正在编辑的格子
    func handleSpace() {
        if prompt != nil { return }
        if let target = editorTarget, settings.editorSpace == .previewCurrent {
            let id = target.id
            if engine.isPaused(id) {
                resumePad(id)
            } else if engine.isLive(id) {
                stopPad(id)
            } else {
                triggerByID(id)
            }
            return
        }
        togglePauseAll()
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        if NSApp.modalWindow != nil { return false }
        if prompt != nil { return false }
        if midiLearn != nil && e.keyCode == 53 {
            midiLearn = nil
            return true
        }
        let mods = e.modifierFlags.intersection([.command, .control, .option])

        if capturingPadID != nil {
            if e.keyCode == 53 { capturingPadID = nil; return true }
            if !mods.isEmpty { return false }
            setKey(e.keyCode, label: KeyNames.label(for: e))
            capturingPadID = nil
            return true
        }

        let key = NSApp.keyWindow
        // 主窗口引用还没取到时，把不是弹出窗口的前台窗口当作主窗口
        let inMain = key != nil && (mainWindow == nil ? key?.sheetParent == nil : key === mainWindow)
        let inEditor = editorTarget != nil && key != nil && key?.sheetParent === mainWindow
        if let r = key?.firstResponder, r is NSText {
            // 正在输入文字时不抢按键（播放页里没有需要打字的地方，直接交给格子）
            if !inMain || editing { return false }
            key?.makeFirstResponder(nil)
        }
        if !mods.isEmpty { return false }

        // 空格：快捷键注册失败时的后备处理
        if e.keyCode == 49 && (inMain || inEditor) {
            if !e.isARepeat { handleSpace() }
            return true
        }

        if inEditor {
            // 编辑窗口里：Esc 交给窗口（关闭），格子键照常播放
            if e.keyCode == 53 { return false }
            if let i = pads.firstIndex(where: { $0?.keyCode == e.keyCode }) {
                if !e.isARepeat { trigger(index: i) }
                return true
            }
            return false
        }

        guard inMain else { return false }

        switch e.keyCode {
        case 53: stopAll(hard: e.modifierFlags.contains(.shift)); return true
        case 33: switchBoard(by: -1); return true
        case 30: switchBoard(by: 1); return true
        case 48:
            // Tab 下一页，Shift+Tab 上一页（到头后循环）
            if !e.isARepeat { switchBoard(by: e.modifierFlags.contains(.shift) ? -1 : 1) }
            return true
        default: break
        }

        if let i = pads.firstIndex(where: { $0?.keyCode == e.keyCode }) {
            if !e.isARepeat { trigger(index: i) }
            return true
        }
        // 吞掉其他单键，避免系统提示音
        return !Store.passthrough.contains(e.keyCode)
    }

    // MARK: MIDI

    private func handleMIDI(_ m: MIDIMessage) {
        let pressed: Bool
        switch m.kind {
        case .note:
            pressed = m.value > 0
        case .cc:
            // 控制器按钮按下时一般发 127、松开发 0：只在越过中点向上时触发一次
            let key = (UInt16(m.channel) << 8) | UInt16(m.number)
            let prev = ccState[key] ?? 0
            ccState[key] = m.value
            pressed = m.value >= 64 && prev < 64
        }
        guard pressed else { return }
        let t = MIDITrigger(kind: m.kind, channel: m.channel, number: m.number)
        if let target = midiLearn {
            assignMIDI(t, to: target)
            midiLearn = nil
            return
        }
        if prompt != nil { return }
        if let g = lib.midiGlobal?.first(where: { $0.value == t }), let action = GlobalMIDIAction(rawValue: g.key) {
            perform(action)
            return
        }
        if let i = pads.firstIndex(where: { $0?.midi == t }) {
            trigger(index: i)
        }
    }

    private func perform(_ a: GlobalMIDIAction) {
        switch a {
        case .stopAll: stopAll(hard: false)
        case .pauseAll: togglePauseAll()
        case .nextBoard: switchBoard(by: 1)
        case .prevBoard: switchBoard(by: -1)
        }
    }

    func beginMIDILearn(_ target: MIDILearnTarget) {
        capturingPadID = nil
        midiLearn = target
        if midiSources.isEmpty { flash("没有检测到 MIDI 设备，请先连接设备。") }
    }

    private func assignMIDI(_ t: MIDITrigger, to target: MIDILearnTarget) {
        switch target {
        case .pad(let id):
            guard let loc = locate(id) else { return }
            let b = loc.board
            for j in 0..<padsPerBoard where j != loc.index && lib.boards[b].pads[j]?.midi == t {
                lib.boards[b].pads[j]?.midi = nil
            }
            lib.boards[b].pads[loc.index]?.midi = t
            if let g = lib.midiGlobal { lib.midiGlobal = g.filter { $0.value != t } }
            if let name = lib.boards[b].pads[loc.index]?.displayName {
                flash("已把\(t.label)分配给“\(name)”。")
            }
        case .global(let a):
            var g = (lib.midiGlobal ?? [:]).filter { $0.value != t }
            g[a.rawValue] = t
            lib.midiGlobal = g
            for b in lib.boards.indices {
                for j in 0..<padsPerBoard where lib.boards[b].pads[j]?.midi == t {
                    lib.boards[b].pads[j]?.midi = nil
                }
            }
            flash("已把\(t.label)分配给“\(a.label)”。")
        }
        save()
    }

    func clearMIDI(id: UUID) {
        editPad(id: id) { $0.midi = nil }
    }

    func clearGlobalMIDI() {
        lib.midiGlobal = nil
        save()
    }

    func globalMIDILabel(_ a: GlobalMIDIAction) -> String? {
        lib.midiGlobal?[a.rawValue]?.shortLabel
    }

    var midiLearnDescription: String? {
        guard let target = midiLearn else { return nil }
        switch target {
        case .pad(let id):
            return "在 MIDI 设备上按下要分配给“\(padByID(id)?.displayName ?? "")”的键或按钮"
        case .global(let a):
            return "在 MIDI 设备上按下要分配给“\(a.label)”的键或按钮"
        }
    }

    // MARK: 备份导入导出

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// 导出为 zip：包含设置（kanade-backup.json）和用到的全部音频
    func exportBackup(currentPageOnly: Bool) {
        saveNow()
        let boards = currentPageOnly ? [lib.boards[lib.active]] : lib.boards
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: Date())
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        let pageName = boardName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = currentPageOnly ? "Kanade-\(pageName)-\(date).zip" : "Kanade-备份-\(date).zip"
        panel.message = currentPageOnly ? "导出当前页（包含音频）" : "导出全部页面（包含音频）"
        spaceKey.suspend()
        let result = panel.runModal()
        spaceKey.resume()
        guard result == .OK, let dest = panel.url else { return }

        let manifest = BackupManifest(appVersion: appVersion, exported: Date(), boards: boards,
                                      midiGlobal: currentPageOnly ? nil : lib.midiGlobal)
        let files = boards.flatMap { $0.pads.compactMap { $0?.fileName } }
        let dir = audioDir
        flash("正在导出…")
        DispatchQueue.global(qos: .userInitiated).async {
            let error = Store.writeBackup(manifest: manifest, files: files, audioDir: dir, to: dest)
            DispatchQueue.main.async {
                if let error {
                    self.flash("导出失败：\(error)")
                } else {
                    self.flash("已导出到“\(dest.lastPathComponent)”。")
                }
            }
        }
    }

    private static func writeBackup(manifest: BackupManifest, files: [String], audioDir: URL, to dest: URL) -> String? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("kanade-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Kanade备份", isDirectory: true)
        let audioOut = root.appendingPathComponent("Audio", isDirectory: true)
        do {
            try fm.createDirectory(at: audioOut, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(manifest).write(to: root.appendingPathComponent("kanade-backup.json"))
            for name in Set(files) {
                let src = audioDir.appendingPathComponent(name)
                let out = audioOut.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                // 优先用硬链接，不占额外空间；失败再复制
                if (try? fm.linkItem(at: src, to: out)) == nil {
                    try fm.copyItem(at: src, to: out)
                }
            }
            try? fm.removeItem(at: dest)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, dest.path]
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? nil : "压缩文件时出错。"
        } catch {
            return error.localizedDescription
        }
    }

    private enum ImportResult {
        case ok(boards: [Board], midiGlobal: [String: MIDITrigger]?, audioCount: Int)
        case failed(String)
    }

    /// 导入备份：作为新页面添加，不会覆盖现有页面
    func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.message = "选择 Kanade 导出的备份文件（.zip）"
        spaceKey.suspend()
        let result = panel.runModal()
        spaceKey.resume()
        guard result == .OK, let src = panel.url else { return }
        let dir = audioDir
        flash("正在导入…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Store.readBackup(from: src, audioDir: dir)
            DispatchQueue.main.async {
                switch result {
                case .failed(let message):
                    self.flash(message)
                case .ok(let boards, let midiGlobal, let audioCount):
                    guard !boards.isEmpty else {
                        self.flash("备份里没有可以导入的页面。")
                        return
                    }
                    self.lib.boards.append(contentsOf: boards)
                    for b in self.lib.boards.indices { self.normalizeKeys(board: b) }
                    // 全局 MIDI 设置：只补上当前还没设置的项目
                    if let imported = midiGlobal {
                        var g = self.lib.midiGlobal ?? [:]
                        let used = Set(g.values)
                        for (k, v) in imported where g[k] == nil && !used.contains(v) { g[k] = v }
                        self.lib.midiGlobal = g
                    }
                    self.lib.active = self.lib.boards.count - boards.count
                    self.selected = nil
                    self.save()
                    self.loadBoards()
                    self.flash("已导入 \(boards.count) 页，共 \(audioCount) 个音频。")
                }
            }
        }
    }

    private static func readBackup(from src: URL, audioDir: URL) -> ImportResult {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("kanade-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", src.path, tmp.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return .failed("无法解压这个文件。") }
        } catch {
            return .failed("无法解压这个文件。")
        }
        let files = fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        guard let manifestURL = files.first(where: { $0.lastPathComponent == "kanade-backup.json" }) else {
            return .failed("这个文件不是 Kanade 的备份。")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? dec.decode(BackupManifest.self, from: data),
              manifest.app == "Kanade" else {
            return .failed("这个文件不是 Kanade 的备份，或者已经损坏。")
        }
        let audioIn = manifestURL.deletingLastPathComponent().appendingPathComponent("Audio", isDirectory: true)
        var boards: [Board] = []
        var count = 0
        for var b in manifest.boards {
            b.id = UUID()
            var pads = b.pads
            if pads.count < padsPerBoard { pads += Array(repeating: nil, count: padsPerBoard - pads.count) }
            if pads.count > padsPerBoard { pads = Array(pads.prefix(padsPerBoard)) }
            for i in pads.indices {
                guard var pad = pads[i] else { continue }
                // 只取文件名本身，防止路径穿越
                let name = (pad.fileName as NSString).lastPathComponent
                let srcFile = audioIn.appendingPathComponent(name)
                guard !name.isEmpty, fm.fileExists(atPath: srcFile.path) else {
                    pads[i] = nil
                    continue
                }
                let ext = (name as NSString).pathExtension
                let newName = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
                let dest = audioDir.appendingPathComponent(newName)
                if (try? fm.moveItem(at: srcFile, to: dest)) == nil {
                    guard (try? fm.copyItem(at: srcFile, to: dest)) != nil else {
                        pads[i] = nil
                        continue
                    }
                }
                pad.id = UUID()
                pad.fileName = newName
                pads[i] = pad
                count += 1
            }
            b.pads = pads
            boards.append(b)
        }
        return .ok(boards: boards, midiGlobal: manifest.midiGlobal, audioCount: count)
    }

    // MARK: 提示

    func flash(_ text: String) {
        message = text
        msgToken += 1
        let token = msgToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.msgToken == token { self?.message = nil }
        }
    }
}
