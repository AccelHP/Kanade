import AVFoundation
import AudioToolbox

// MARK: - 播放计划（按播放范围 / 循环范围预先截好的缓冲）

struct PlanKey: Equatable {
    let start: Double
    let end: Double
    let loop: Bool
    let loopIn: Double
    let loopOut: Double

    init(start: Double, end: Double, loop: Bool, loopIn: Double, loopOut: Double) {
        self.start = start
        self.end = end
        self.loop = loop
        self.loopIn = loopIn
        self.loopOut = loopOut
    }

    init(_ p: Pad) {
        self.init(start: p.regionStart, end: p.regionEnd, loop: p.loop,
                  loopIn: p.loop ? p.loopIn : 0, loopOut: p.loop ? p.loopOut : 0)
    }
}

final class PlayPlan {
    let key: PlanKey
    let main: AVAudioPCMBuffer?
    let intro: AVAudioPCMBuffer?
    let loopBuffer: AVAudioPCMBuffer?

    init(key: PlanKey, main: AVAudioPCMBuffer?, intro: AVAudioPCMBuffer?, loopBuffer: AVAudioPCMBuffer?) {
        self.key = key
        self.main = main
        self.intro = intro
        self.loopBuffer = loopBuffer
    }

    var introLength: Double { intro.map { Double($0.frameLength) / $0.format.sampleRate } ?? 0 }
    var loopLength: Double { loopBuffer.map { max(0.001, Double($0.frameLength) / $0.format.sampleRate) } ?? 0.001 }
}

struct VoiceProgress {
    let position: Double      // 在文件中的位置（秒）
    let fraction: Double      // 在播放范围中的比例
    let remaining: Double?    // 剩余时间，循环时为 nil
    let looping: Bool
    let fading: Bool
}

enum LoadStatus { case none, loading, ready, failed }

// MARK: - 固定的播放通道：播放器 → 均衡 → 变调 → 延迟 → 混响 → 声像/音量
// 启动时一次性搭好，运行中不再增删节点，避免音频图损坏

final class Slot {
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 3)
    let timePitch = AVAudioUnitTimePitch()
    let delay = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()
    let mixer = AVAudioMixerNode()
    var reverbPreset: ReverbPreset?
    var voice: Voice?
    var lastUsed: TimeInterval = 0

    var nodes: [AVAudioNode] { [player, eq, timePitch, delay, reverb, mixer] }
}

enum RampEnd { case none, stop, pause }

struct Ramp {
    let from: Float
    let to: Float
    let start: TimeInterval
    let duration: Double
    let then: RampEnd
}

final class Voice {
    let slot: Slot
    let padID: UUID
    let plan: PlayPlan
    let speed: Double
    var stopping = false
    var paused = false
    var pausedElapsed: Double? = nil
    var ramp: Ramp? = nil

    var player: AVAudioPlayerNode { slot.player }

    init(slot: Slot, padID: UUID, plan: PlayPlan, speed: Double) {
        self.slot = slot
        self.padID = padID
        self.plan = plan
        self.speed = speed
    }
}

// MARK: - 引擎

final class AudioEngine {
    /// 同时发声的上限；另有 4 条备用通道，让被挤掉的声音可以淡出而不是被切断
    static let maxVoices = 24
    static let slotCount = 28

    let engine = AVAudioEngine()
    let chainFormat: AVAudioFormat
    private var slots: [Slot] = []
    private var audio: [UUID: LoadedAudio] = [:]
    private var plans: [UUID: PlayPlan] = [:]
    private var loadGen: [UUID: Int] = [:]
    private var loadingMode: [UUID: ChannelMode] = [:]
    private var failed: Set<UUID> = []
    private var pendingOps: [UUID: Operation] = [:]
    private(set) var voices: [UUID: [Voice]] = [:]
    private var fadeTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private let planQueue = DispatchQueue(label: "kanade.plan", qos: .userInitiated)
    private let loadQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    var onChange: (() -> Void)?
    var onMeter: ((Float, Float) -> Void)?
    /// 开始 / 结束恢复音频输出时通知界面
    var onRecoverStart: (() -> Void)?
    var onRecoverEnd: ((Bool) -> Void)?
    private var recovering = false
    private var pendingPlay: (pad: Pad, time: TimeInterval)?
    var master: Double = 0.9 {
        didSet { engine.mainMixerNode.outputVolume = Float(master) }
    }

    /// 所有接触声音硬件的操作都放在这个队列里，避免开机或唤醒后设备响应慢时卡住界面
    private let control = DispatchQueue(label: "kanade.audio.control", qos: .userInitiated)

    init() {
        // 内部统一用 48 kHz，启动时不去查询硬件（和设备采样率不同时由混音器自动转换）
        chainFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let main = engine.mainMixerNode
        main.outputVolume = 0.9
        for _ in 0..<Self.slotCount {
            let s = Slot()
            for n in s.nodes { engine.attach(n) }
            engine.connect(s.player, to: s.eq, format: chainFormat)
            engine.connect(s.eq, to: s.timePitch, format: chainFormat)
            engine.connect(s.timePitch, to: s.delay, format: chainFormat)
            engine.connect(s.delay, to: s.reverb, format: chainFormat)
            engine.connect(s.reverb, to: s.mixer, format: chainFormat)
            engine.connect(s.mixer, to: main, format: chainFormat)
            configure(s)
            slots.append(s)
        }
        installMeter()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigChange()
        }
        // 这里不启动引擎：由 boot() 在后台完成
    }

    /// 在后台查询输出设备、切换到保存的设备并启动引擎，完成后回到主线程
    func boot(deviceUID: String?, completion: @escaping (_ devices: [OutputDevice], _ ok: Bool) -> Void) {
        control.async {
            Log.step("查询声音输出设备")
            let list = AudioDevices.outputs()
            Log.write("找到 \(list.count) 个输出设备")
            if let uid = deviceUID, let d = list.first(where: { $0.uid == uid }) {
                Log.step("切换到保存的输出设备：\(d.name)")
                self.applyDevice(d.deviceID)
            }
            self.reconnectOutput()
            Log.step("启动音频引擎")
            let ok = self.startNow()
            Log.step(ok ? "音频引擎已启动" : "音频引擎启动失败")
            DispatchQueue.main.async {
                completion(list, ok)
                self.onChange?()
            }
        }
    }

    /// 只在 control 队列里调用
    private func startNow() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            Log.write("音频引擎启动出错：\(error.localizedDescription)")
            return false
        }
    }

    /// 只在 control 队列里调用：切换输出设备并重新连接
    private func applyDevice(_ id: AudioDeviceID) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var dev = id
        engine.stop()
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        reconnectOutput()
    }

    /// 只在 control 队列里调用：按输出设备“当前”的格式重新连接总混音器和输出
    /// （设备唤醒或重新配置后，旧的连接格式可能已经不对，会导致有播放显示但没声音）
    private func reconnectOutput() {
        let hw = engine.outputNode.outputFormat(forBus: 0)
        Log.write(String(format: "输出设备格式：%.0f Hz，%d 声道", hw.sampleRate, Int(hw.channelCount)))
        guard hw.sampleRate > 0,
              let f = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: 2) else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: f)
        installMeter()
    }

    /// 只在 control 队列里调用：停止、重新连接、再启动
    private func rebuildAndStart() -> Bool {
        engine.stop()
        reconnectOutput()
        return startNow()
    }

    /// 在后台恢复音频输出（不会卡住界面）。完成后补播 2 秒内按下的格子
    func recoverOutput(then pad: Pad? = nil) {
        if let pad { pendingPlay = (pad, ProcessInfo.processInfo.systemUptime) }
        guard !recovering else { return }
        recovering = true
        for s in slots {
            s.player.stop()
            s.voice = nil
        }
        voices.removeAll()
        fadeTimer?.invalidate()
        fadeTimer = nil
        onRecoverStart?()
        Log.step("开始恢复音频输出")
        control.async {
            let ok = self.rebuildAndStart()
            DispatchQueue.main.async {
                self.recovering = false
                Log.step(ok ? "音频输出恢复成功" : "音频输出恢复失败")
                self.onRecoverEnd?(ok)
                if ok, let p = self.pendingPlay,
                   ProcessInfo.processInfo.systemUptime - p.time < 2 {
                    self.pendingPlay = nil
                    _ = self.trigger(p.pad)
                }
                self.pendingPlay = nil
                self.onChange?()
            }
        }
    }

    var isRecovering: Bool { recovering }
    var isRunning: Bool { engine.isRunning }

    private func configure(_ s: Slot) {
        let bands = s.eq.bands
        bands[0].filterType = .lowShelf
        bands[0].frequency = 120
        bands[0].bypass = false
        bands[1].filterType = .parametric
        bands[1].frequency = 1000
        bands[1].bandwidth = 1.2
        bands[1].bypass = false
        bands[2].filterType = .highShelf
        bands[2].frequency = 8000
        bands[2].bypass = false
        // 均衡器本身保持工作，用它的总增益实现放大；三个频段在关闭均衡时单独旁路
        s.eq.bypass = false
        for b in bands { b.bypass = true }
        s.eq.globalGain = 0
        s.timePitch.bypass = true
        s.delay.bypass = true
        s.reverb.loadFactoryPreset(.mediumHall)
        s.reverbPreset = .mediumHall
        s.reverb.bypass = true
    }

    /// 引擎是否可以直接播放；没在运行时在后台恢复，并返回 false（不会卡住界面）
    private func ensureRunning(then pad: Pad?) -> Bool {
        if engine.isRunning && !recovering { return true }
        recoverOutput(then: pad)
        return false
    }

    private func installMeter() {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let d = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            let chs = Int(buf.format.channelCount)
            guard n > 0, chs > 0 else { return }
            var l: Float = 0
            var r: Float = 0
            let p0 = d[0]
            for i in 0..<n { let v = abs(p0[i]); if v > l { l = v } }
            if chs > 1 {
                let p1 = d[1]
                for i in 0..<n { let v = abs(p1[i]); if v > r { r = v } }
            } else {
                r = l
            }
            let fl = l, fr = r
            DispatchQueue.main.async { self?.onMeter?(fl, fr) }
        }
    }

    private func handleConfigChange() {
        Log.write("音频设备配置发生变化，重新启动音频引擎")
        for s in slots {
            s.player.stop()
            s.voice = nil
        }
        voices.removeAll()
        fadeTimer?.invalidate()
        fadeTimer = nil
        control.async {
            let ok = self.rebuildAndStart()
            Log.write(ok ? "音频引擎已重新启动" : "音频引擎重新启动失败")
            DispatchQueue.main.async { self.onChange?() }
        }
        onChange?()
    }

    // MARK: 状态查询

    func isLoaded(_ id: UUID) -> Bool { audio[id] != nil }
    func peaks(_ id: UUID) -> WavePeaks? { audio[id]?.peaks }
    func buffer(_ id: UUID) -> AVAudioPCMBuffer? { audio[id]?.buffer }
    func hasVoices(_ id: UUID) -> Bool { voices[id] != nil }
    /// 正在发声（没有在淡出、也没有暂停）
    func isLive(_ id: UUID) -> Bool { voices[id]?.contains { !$0.stopping && !$0.paused } ?? false }
    /// 已暂停，并且没有其他正在发声的
    func isPaused(_ id: UUID) -> Bool {
        guard let list = voices[id], !isLive(id) else { return false }
        return list.contains { $0.paused && !$0.stopping }
    }
    var liveCount: Int { voices.keys.filter { isLive($0) }.count }
    var pausedCount: Int { voices.keys.filter { isPaused($0) }.count }

    func status(_ id: UUID) -> LoadStatus {
        if audio[id] != nil { return .ready }
        if loadingMode[id] != nil { return .loading }
        if failed.contains(id) { return .failed }
        return .none
    }

    // MARK: 载入 / 卸载

    func load(_ pad: Pad, url: URL, force: Bool,
              priority: Operation.QueuePriority = .normal,
              completion: @escaping (Bool) -> Void) {
        let id = pad.id
        let mode = pad.channelMode
        if !force {
            if let a = audio[id], a.mode == mode {
                completion(true)
                return
            }
            if loadingMode[id] == mode {
                // 已经在载入同样的内容：只调整优先级
                if priority.rawValue > (pendingOps[id]?.queuePriority.rawValue ?? Int.max) {
                    pendingOps[id]?.queuePriority = priority
                }
                return
            }
        }
        pendingOps[id]?.cancel()
        let gen = (loadGen[id] ?? 0) + 1
        loadGen[id] = gen
        loadingMode[id] = mode
        failed.remove(id)
        onChange?()
        let sr = chainFormat.sampleRate
        let op = BlockOperation {
            let result = try? AudioLoader.load(url: url, mode: mode, sampleRate: sr)
            DispatchQueue.main.async {
                guard self.loadGen[id] == gen else { return }
                self.pendingOps[id] = nil
                self.loadingMode[id] = nil
                guard let result else {
                    self.failed.insert(id)
                    self.onChange?()
                    completion(false)
                    return
                }
                self.audio[id] = result
                self.plans[id] = nil
                self.onChange?()
                completion(true)
                if self.loadingMode.isEmpty {
                    Log.step(String(format: "音频全部载入完成：%d 个，占用约 %.0f MB",
                                    self.audio.count, Double(self.loadedBytes) / 1_048_576))
                }
            }
        }
        op.queuePriority = priority
        pendingOps[id] = op
        loadQueue.addOperation(op)
    }

    /// 把这些格子的载入排到最前面（切换到还没载完的页面时用）
    func prioritize(_ ids: [UUID]) {
        for id in ids { pendingOps[id]?.queuePriority = .veryHigh }
    }

    /// 已载入音频占用的内存（字节）
    var loadedBytes: Int64 { audio.keys.reduce(0) { $0 + bytes($1) } }

    func bytes(_ id: UUID) -> Int64 {
        guard let b = audio[id]?.buffer else { return 0 }
        return Int64(b.frameLength) * Int64(b.format.channelCount) * 4
    }

    /// 只释放内存，不改动音频图
    func unload(_ id: UUID, force: Bool = false) {
        if hasVoices(id) {
            if force { hardStop(id) } else { return }
        }
        loadGen[id] = (loadGen[id] ?? 0) + 1
        pendingOps[id]?.cancel()
        pendingOps[id] = nil
        loadingMode[id] = nil
        failed.remove(id)
        audio[id] = nil
        plans[id] = nil
    }

    /// 在后台预先截好播放用的缓冲，按下时无需等待
    func preparePlan(_ pad: Pad) {
        guard let a = audio[pad.id] else { return }
        let key = PlanKey(pad)
        if plans[pad.id]?.key == key { return }
        let buffer = a.buffer
        let id = pad.id
        planQueue.async {
            let plan = AudioEngine.makePlan(key, buffer)
            DispatchQueue.main.async {
                if self.audio[id]?.buffer === buffer { self.plans[id] = plan }
            }
        }
    }

    static func makePlan(_ key: PlanKey, _ b: AVAudioPCMBuffer) -> PlayPlan {
        let sr = b.format.sampleRate
        let total = Double(b.frameLength) / sr
        func frame(_ t: Double) -> AVAudioFramePosition {
            AVAudioFramePosition((min(max(t, 0), total) * sr).rounded())
        }
        if key.loop {
            let intro = key.loopIn - key.start > 0.005
                ? AudioLoader.slice(b, from: frame(key.start), to: frame(key.loopIn)) : nil
            let loopB = AudioLoader.slice(b, from: frame(key.loopIn), to: frame(key.loopOut))
            return PlayPlan(key: key, main: nil, intro: intro, loopBuffer: loopB)
        }
        let whole = key.start < 0.0005 && key.end >= total - 0.0005
        let main = whole ? b : AudioLoader.slice(b, from: frame(key.start), to: frame(key.end))
        return PlayPlan(key: key, main: main, intro: nil, loopBuffer: nil)
    }

    // MARK: 设置

    func applySettings(_ pad: Pad) {
        for v in voices[pad.id] ?? [] { apply(pad, to: v.slot) }
    }

    private func apply(_ pad: Pad, to s: Slot) {
        s.mixer.outputVolume = Float(pad.volume)
        s.mixer.pan = Float(pad.pan)
        let fx = pad.fx

        s.eq.bypass = false
        s.eq.globalGain = Float(min(18, max(0, pad.gainDB)))
        let bands = s.eq.bands
        for b in bands { b.bypass = !fx.eqOn }
        bands[0].gain = Float(fx.eqLow)
        bands[1].gain = Float(fx.eqMid)
        bands[2].gain = Float(fx.eqHigh)

        s.timePitch.bypass = !fx.pitchOn
        s.timePitch.pitch = Float(fx.pitch * 100)
        s.timePitch.rate = Float(fx.speed)

        s.delay.bypass = !fx.delayOn
        s.delay.delayTime = fx.delayTime
        s.delay.feedback = Float(fx.delayFeedback)
        s.delay.wetDryMix = Float(fx.delayMix)

        s.reverb.bypass = !fx.reverbOn
        if s.reverbPreset != fx.reverbPreset {
            s.reverb.loadFactoryPreset(Self.avPreset(fx.reverbPreset))
            s.reverbPreset = fx.reverbPreset
        }
        s.reverb.wetDryMix = Float(fx.reverbMix)
    }

    private static func avPreset(_ p: ReverbPreset) -> AVAudioUnitReverbPreset {
        switch p {
        case .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeRoom: return .largeRoom
        case .mediumHall: return .mediumHall
        case .largeHall: return .largeHall
        case .plate: return .plate
        case .cathedral: return .cathedral
        }
    }

    /// 取一条空闲通道；都在用时，先挤掉正在淡出的，再挤掉最早开始的
    private func takeSlot() -> Slot {
        if let s = slots.filter({ $0.voice == nil }).min(by: { $0.lastUsed < $1.lastUsed }) {
            return s
        }
        let fading = slots.filter { $0.voice?.stopping == true }
        let playing = slots.filter { $0.voice?.paused == false }
        let pool = !fading.isEmpty ? fading : (!playing.isEmpty ? playing : slots)
        let s = pool.min(by: { $0.lastUsed < $1.lastUsed }) ?? slots[0]
        if let v = s.voice {
            s.player.stop()
            remove(v)
        }
        return s
    }

    // MARK: 播放

    /// 返回 false 表示音频输出无法启动
    @discardableResult
    func trigger(_ pad: Pad) -> Bool {
        guard let a = audio[pad.id] else { return true }
        guard ensureRunning(then: pad) else { return true }
        if isPaused(pad.id) {
            if pad.mode == .restart {
                stop(pad.id, fade: 0)
            } else {
                resume(pad.id)
                return true
            }
        }
        if isLive(pad.id) {
            switch pad.mode {
            case .toggle:
                stop(pad.id, fade: pad.fade)
                return true
            case .pause:
                pause(pad.id)
                return true
            case .restart:
                stop(pad.id, fade: 0.02)
            case .overlap:
                break
            }
        }
        if pad.exclusive {
            for id in Array(voices.keys) where id != pad.id {
                stop(id, fade: max(pad.fade, 0.15))
            }
        }
        let key = PlanKey(pad)
        let plan: PlayPlan
        if let p = plans[pad.id], p.key == key {
            plan = p
        } else {
            plan = Self.makePlan(key, a.buffer)
            plans[pad.id] = plan
        }
        startVoice(pad, plan: plan)
        return true
    }

    /// 从指定位置试听到播放范围结尾
    func preview(_ pad: Pad, from t: Double) {
        guard let a = audio[pad.id], ensureRunning(then: nil) else { return }
        for v in voices[pad.id] ?? [] where !v.stopping { beginFade(v, 0.03) }
        let end = pad.regionEnd
        guard end - t > 0.02 else { return }
        let key = PlanKey(start: max(0, t), end: end, loop: false, loopIn: 0, loopOut: 0)
        startVoice(pad, plan: Self.makePlan(key, a.buffer))
    }

    private func matches(_ b: AVAudioPCMBuffer?) -> Bool {
        guard let b else { return true }
        return b.format.channelCount == chainFormat.channelCount
            && abs(b.format.sampleRate - chainFormat.sampleRate) < 0.5
    }

    /// 已经有 24 个声音时，让最早开始的那个淡出（都在暂停时才挤掉暂停的）
    private func enforceVoiceLimit() {
        let active = slots.compactMap { $0.voice }.filter { !$0.stopping }
        guard active.count >= Self.maxVoices else { return }
        let playing = active.filter { !$0.paused }
        let pool = playing.isEmpty ? active : playing
        guard let oldest = pool.min(by: { $0.slot.lastUsed < $1.slot.lastUsed }) else { return }
        if oldest.paused {
            oldest.player.stop()
            remove(oldest)
        } else {
            beginFade(oldest, 0.4)
        }
    }

    private func startVoice(_ pad: Pad, plan: PlayPlan) {
        guard matches(plan.main), matches(plan.intro), matches(plan.loopBuffer),
              plan.main != nil || plan.loopBuffer != nil else { return }
        enforceVoiceLimit()
        let slot = takeSlot()
        apply(pad, to: slot)
        let player = slot.player
        // 播放器在上一次播放结束时已经复位；只有还在运行的才需要停一下
        if player.isPlaying { player.stop() }
        player.volume = 1
        let voice = Voice(slot: slot, padID: pad.id, plan: plan,
                          speed: pad.fx.pitchOn ? max(0.1, pad.fx.speed) : 1)
        slot.voice = voice
        slot.lastUsed = ProcessInfo.processInfo.systemUptime
        if let loopBuf = plan.loopBuffer {
            if let intro = plan.intro {
                player.scheduleBuffer(intro, at: nil, options: [], completionHandler: nil)
            }
            player.scheduleBuffer(loopBuf, at: nil, options: .loops, completionHandler: nil)
        } else if let main = plan.main {
            player.scheduleBuffer(main, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self, weak voice] _ in
                DispatchQueue.main.async {
                    guard let self, let voice else { return }
                    self.finished(voice)
                }
            }
        }
        voices[pad.id, default: []].append(voice)
        player.play()
        onChange?()
    }

    func stop(_ id: UUID, fade: Double) {
        for v in voices[id] ?? [] where !v.stopping {
            if v.paused {
                // 暂停中的声音已经没有音量，直接停掉
                v.player.stop()
                remove(v)
            } else {
                beginFade(v, fade)
            }
        }
        onChange?()
    }

    func stopAll(fade: Double) {
        for id in Array(voices.keys) { stop(id, fade: fade) }
    }

    func hardStop(_ id: UUID) {
        for v in voices[id] ?? [] {
            v.player.stop()
            if v.slot.voice === v { v.slot.voice = nil }
        }
        voices[id] = nil
        onChange?()
    }

    // MARK: 暂停 / 继续

    func pause(_ id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        for v in voices[id] ?? [] where !v.stopping && !v.paused {
            v.paused = true
            v.ramp = Ramp(from: v.player.volume, to: 0, start: now, duration: 0.12, then: .pause)
        }
        startFadeTimer()
        onChange?()
    }

    func resume(_ id: UUID) {
        guard ensureRunning(then: nil) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for v in voices[id] ?? [] where !v.stopping && v.paused {
            v.paused = false
            v.pausedElapsed = nil
            if !v.player.isPlaying { v.player.play() }
            v.ramp = Ramp(from: v.player.volume, to: 1, start: now, duration: 0.08, then: .none)
        }
        startFadeTimer()
        onChange?()
    }

    /// 有声音在播放就全部暂停；否则把暂停的全部继续
    func togglePauseAll() {
        let live = voices.keys.filter { isLive($0) }
        if !live.isEmpty {
            for id in live { pause(id) }
        } else {
            for id in voices.keys.filter({ isPaused($0) }) { resume(id) }
        }
    }

    private func beginFade(_ v: Voice, _ fade: Double) {
        v.stopping = true
        v.ramp = Ramp(from: v.player.volume, to: 0, start: ProcessInfo.processInfo.systemUptime,
                      duration: max(fade, 0.02), then: .stop)
        startFadeTimer()
    }

    private func startFadeTimer() {
        guard fadeTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.fadeTick()
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func fadeTick() {
        let now = ProcessInfo.processInfo.systemUptime
        var done: [Voice] = []
        var active = false
        for list in voices.values {
            for v in list {
                guard let r = v.ramp else { continue }
                let p = min(1, (now - r.start) / max(r.duration, 0.001))
                let k = r.to < r.from ? 1 - cos(p * Double.pi / 2) : sin(p * Double.pi / 2)
                v.player.volume = r.from + (r.to - r.from) * Float(k)
                if p < 1 {
                    active = true
                    continue
                }
                v.ramp = nil
                switch r.then {
                case .stop:
                    done.append(v)
                case .pause:
                    v.pausedElapsed = rawElapsed(v)
                    v.player.pause()
                case .none:
                    break
                }
            }
        }
        for v in done {
            v.player.stop()
            remove(v)
        }
        if !active {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
        if !done.isEmpty { onChange?() }
    }

    private func remove(_ v: Voice) {
        if v.slot.voice === v { v.slot.voice = nil }
        guard var list = voices[v.padID] else { return }
        list.removeAll { $0 === v }
        voices[v.padID] = list.isEmpty ? nil : list
        onChange?()
    }

    private func finished(_ v: Voice) {
        guard voices[v.padID]?.contains(where: { $0 === v }) == true else { return }
        // 在播放结束时顺手复位播放器，下次按键就不用等这一步
        if v.slot.voice === v { v.player.stop() }
        remove(v)
    }

    func progress(_ id: UUID) -> VoiceProgress? {
        guard let v = voices[id]?.last else { return nil }
        let plan = v.plan
        let el = (v.paused ? v.pausedElapsed : nil) ?? rawElapsed(v)
        let key = plan.key
        let span = max(0.001, key.end - key.start)
        if plan.loopBuffer != nil {
            let pos: Double
            if el < plan.introLength {
                pos = key.start + el
            } else {
                pos = key.loopIn + (el - plan.introLength).truncatingRemainder(dividingBy: plan.loopLength)
            }
            return VoiceProgress(position: pos, fraction: (pos - key.start) / span,
                                 remaining: max(0, key.loopOut - pos) / v.speed, looping: true, fading: v.stopping)
        }
        let pos = min(key.start + el, key.end)
        return VoiceProgress(position: pos, fraction: (pos - key.start) / span,
                             remaining: max(0, key.end - pos) / v.speed, looping: false, fading: v.stopping)
    }

    private func rawElapsed(_ v: Voice) -> Double {
        if let nt = v.player.lastRenderTime, nt.isSampleTimeValid,
           let pt = v.player.playerTime(forNodeTime: nt) {
            return max(0, Double(pt.sampleTime) / pt.sampleRate)
        }
        return 0
    }

    // MARK: 输出设备

    /// 用户在菜单里切换输出设备时调用（主线程）
    func setOutputDevice(_ deviceID: AudioDeviceID?) {
        for id in Array(voices.keys) { hardStop(id) }
        control.async {
            guard let dev = deviceID ?? AudioDevices.defaultOutputID() else { return }
            Log.step("切换输出设备")
            self.applyDevice(dev)
            let ok = self.startNow()
            Log.step(ok ? "输出设备切换完成" : "输出设备切换后引擎启动失败")
            DispatchQueue.main.async { self.onChange?() }
        }
        onChange?()
    }
}
