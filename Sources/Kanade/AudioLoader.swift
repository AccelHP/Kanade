import AVFoundation

struct WavePeaks {
    let left: [Float]
    let right: [Float]
    var count: Int { left.count }
}

struct LoadedAudio {
    let buffer: AVAudioPCMBuffer      // 统一转成双声道 Float32
    let peaks: WavePeaks
    let mode: ChannelMode
}

enum AudioLoadError: Error { case empty, format }

enum AudioLoader {
    static let peakBins = 6000

    /// 读取整个文件，按声道设置处理成双声道，并统一转换成引擎的采样率
    static func load(url: URL, mode: ChannelMode, sampleRate: Double) throws -> LoadedAudio {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let src = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else {
            throw AudioLoadError.empty
        }
        try file.read(into: src)
        let n = Int(src.frameLength)
        guard n > 0,
              let outFmt = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 2),
              let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: src.frameLength),
              let s = src.floatChannelData,
              let o = out.floatChannelData else {
            throw AudioLoadError.format
        }
        out.frameLength = src.frameLength
        let chs = Int(fmt.channelCount)
        let inL = s[0]
        let inR = chs > 1 ? s[1] : s[0]
        let outL = o[0]
        let outR = o[1]
        switch mode {
        case .stereo:
            for i in 0..<n { outL[i] = inL[i]; outR[i] = inR[i] }
        case .mono:
            for i in 0..<n { let m = (inL[i] + inR[i]) * 0.5; outL[i] = m; outR[i] = m }
        case .left:
            for i in 0..<n { outL[i] = inL[i]; outR[i] = inL[i] }
        case .right:
            for i in 0..<n { outL[i] = inR[i]; outR[i] = inR[i] }
        }
        guard let final = resample(out, to: sampleRate) else { throw AudioLoadError.format }
        return LoadedAudio(buffer: final, peaks: peaks(final), mode: mode)
    }

    /// 采样率转换（双声道 → 双声道）
    static func resample(_ buf: AVAudioPCMBuffer, to sampleRate: Double) -> AVAudioPCMBuffer? {
        if abs(buf.format.sampleRate - sampleRate) < 0.5 { return buf }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let conv = AVAudioConverter(from: buf.format, to: fmt) else { return nil }
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let cap = AVAudioFrameCount(Double(buf.frameLength) * sampleRate / buf.format.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buf
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }

    static func peaks(_ b: AVAudioPCMBuffer) -> WavePeaks {
        guard let d = b.floatChannelData else { return WavePeaks(left: [], right: []) }
        let n = Int(b.frameLength)
        guard n > 0 else { return WavePeaks(left: [], right: []) }
        let p0 = d[0]
        let p1 = b.format.channelCount > 1 ? d[1] : d[0]
        let bins = min(peakBins, n)
        var l = [Float](repeating: 0, count: bins)
        var r = [Float](repeating: 0, count: bins)
        let per = Double(n) / Double(bins)
        for k in 0..<bins {
            let a = Int(Double(k) * per)
            let e = min(n, max(a + 1, Int(Double(k + 1) * per)))
            var ml: Float = 0
            var mr: Float = 0
            var i = a
            while i < e {
                let x = abs(p0[i]); if x > ml { ml = x }
                let y = abs(p1[i]); if y > mr { mr = y }
                i += 1
            }
            l[k] = ml
            r[k] = mr
        }
        return WavePeaks(left: l, right: r)
    }

    /// 截取一段，生成新的缓冲
    static func slice(_ b: AVAudioPCMBuffer, from: AVAudioFramePosition, to: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let total = Int(b.frameLength)
        let start = max(0, min(Int(from), total))
        let end = max(start, min(Int(to), total))
        let len = end - start
        guard len > 0,
              let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(len)),
              let s = b.floatChannelData,
              let o = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(len)
        for c in 0..<Int(b.format.channelCount) {
            let sp = s[c] + start
            let op = o[c]
            for i in 0..<len { op[i] = sp[i] }
        }
        return out
    }
}
