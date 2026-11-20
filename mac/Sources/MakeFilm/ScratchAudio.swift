import AVFoundation
import QuartzCore

/// Scratch-style sound for hand-cranking, like rocking film over a Moviola's sound head.
///
/// The sequence's audio is decoded into memory. A read head follows the hand's position sample by
/// sample — forwards or backwards — so the pitch follows the speed, rocking plays the sound in
/// reverse, and the instant the hand stops the sound stops. Normal playback (the pedal) still goes
/// through AVPlayer; this only sounds while cranking.
final class ScratchAudio: @unchecked Sendable {
    static let sampleRate: Double = 32_000

    /// Shared with the audio render thread. Plain values written from the main thread and read
    /// once per render call — a torn read just makes one buffer follow a slightly old target.
    private struct State {
        var samples: UnsafeMutablePointer<Float>?   // interleaved stereo
        var frames: Int = 0
        var target: Double = 0                      // where the hand is (frames)
        var head: Double = 0                        // where the sound head is (frames)
        var vel: Double = 0                         // frames per frame (1 = normal speed)
        var amp: Float = 0
        var active = false
    }
    private let state = UnsafeMutablePointer<State>.allocate(capacity: 1)
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private(set) var isReady = false
    private var generation = 0

    init() {
        state.initialize(to: State())
        let st = state
        let sr = Self.sampleRate
        // How the head chases the hand: it aims to close the gap within ~40 ms, and its speed
        // settles with a ~8 ms time constant — quick enough to feel direct, smooth enough not to click.
        let chase = 1.0 / (0.040 * sr)
        let settle = 1.0 - exp(-1.0 / (0.008 * sr))
        let ampSettle: Float = Float(1.0 - exp(-1.0 / (0.004 * sr)))
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let s = st.pointee
            guard let data = s.samples, s.frames > 1 else {
                for i in 0..<Int(frameCount) { left[i] = 0; right[i] = 0 }
                return noErr
            }
            var head = s.head, vel = s.vel, amp = s.amp
            let target = s.target
            let last = Double(s.frames - 1)
            for i in 0..<Int(frameCount) {
                let want = s.active ? max(-12, min(12, (target - head) * chase)) : 0
                vel += (want - vel) * settle
                head = max(0, min(last, head + vel))
                // louder when moving, silent when still (no clicks: the level glides)
                let goal: Float = s.active ? min(1, Float(abs(vel)) * 1.6) : 0
                amp += (goal - amp) * ampSettle
                let p = Int(head), f = Float(head - Double(p))
                let q = min(p + 1, s.frames - 1)
                let l = data[p * 2] + (data[q * 2] - data[p * 2]) * f
                let r = data[p * 2 + 1] + (data[q * 2 + 1] - data[p * 2 + 1]) * f
                left[i] = l * amp
                right[i] = r * amp
            }
            st.pointee.head = head
            st.pointee.vel = vel
            st.pointee.amp = amp
            return noErr
        }
        engine.attach(node!)
        engine.connect(node!, to: engine.mainMixerNode, format: format)
    }

    // MARK: control (main thread)

    /// Begin a crank at time `t`: the head starts where the picture is.
    func begin(at t: Double) {
        guard isReady else { return }
        startEngineIfNeeded()
        let f = t * Self.sampleRate
        state.pointee.head = f
        state.pointee.target = f
        state.pointee.vel = 0
        state.pointee.active = true
    }

    /// The hand moved: the sound head follows.
    func follow(_ t: Double) {
        guard isReady else { return }
        let f = t * Self.sampleRate
        // a big jump (e.g. a click elsewhere) is a cut, not a scratch
        if abs(f - state.pointee.target) > Self.sampleRate * 1.5 { state.pointee.head = f; state.pointee.vel = 0 }
        state.pointee.target = f
    }

    /// The hand let go: the head glides to the target and the sound fades out by itself.
    func end() { state.pointee.active = false }

    // MARK: audio

    /// Replace the audio (call with nil when the sequence has none). `generation` ignores stale results.
    func setAudio(_ samples: [Float]?, generation g: Int) {
        guard g == generation else { return }
        let old = state.pointee.samples
        if let samples, samples.count >= 4 {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            p.initialize(from: samples, count: samples.count)
            state.pointee.active = false
            state.pointee.samples = p
            state.pointee.frames = samples.count / 2
            isReady = true
        } else {
            state.pointee.active = false
            state.pointee.samples = nil
            state.pointee.frames = 0
            isReady = false
        }
        // free the old buffer once the render thread can no longer be reading it
        if let old { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { old.deallocate() } }
    }

    /// Start a new decode; results from earlier ones are dropped.
    func nextGeneration() -> Int {
        generation += 1
        isReady = false
        state.pointee.active = false
        return generation
    }

    /// Render offline instead of to the speakers (used to check the sound in tests).
    func renderOffline(seconds: Double, chunk: AVAudioFrameCount = 256, onChunk: (Double) -> Void) -> [Float] {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        engine.stop()
        try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        try? engine.start()
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk)!
        var out = [Float]()
        var t = 0.0
        while t < seconds {
            onChunk(t)
            _ = try? engine.renderOffline(chunk, to: buf)
            let n = Int(buf.frameLength)
            if let l = buf.floatChannelData?[0] { out.append(contentsOf: UnsafeBufferPointer(start: l, count: n)) }
            t += Double(n) / Self.sampleRate
        }
        return out
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    /// Decode an asset's audio (all audio tracks, mixed with `audioMix`) to interleaved stereo at 32 kHz.
    static func decode(_ asset: AVAsset, audioMix: AVAudioMix?, maxSeconds: Double = 1800) async -> [Float]? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let duration = try? await asset.load(.duration).seconds, duration < maxSeconds,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        out.audioMix = audioMix
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var all = [Float]()
        all.reserveCapacity(Int(duration * sampleRate * 2) + 1024)
        while let sb = out.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            let start = all.count
            all.append(contentsOf: repeatElement(0, count: n))
            _ = all.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: raw.baseAddress! + start * 4)
            }
        }
        return reader.status == .completed ? all : nil
    }
}
