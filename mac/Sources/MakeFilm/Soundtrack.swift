import AVFoundation
import CoreGraphics
import QuartzCore

/// 35mm film geometry in millimetres: frames spaced as 3-perf pull-down (pictures almost edge to edge),
/// optical soundtrack. `perforated` = false leaves the perforations off: the soundtrack widens into
/// the left edge and the picture takes the material's own shape (see `FilmGeometry`).
/// Everything that draws film (strip, viewer) scales these by "pixels per mm".
enum Film35 {
    static let perforated = false
    static let frameLine: CGFloat = 0.7
    static let perfPitch: CGFloat = 4.75
    static let perfsPerFrame = 3                // frame spacing, also with no perforations drawn
    static let pitch: CGFloat = perfPitch * CGFloat(perfsPerFrame)   // 14.25: one frame = 3 perforations
    static let perfW: CGFloat = 2.794           // KS perforation: wider than tall
    static let perfH: CGFloat = 1.981
    static let perfCorner: CGFloat = 0.5
    static let perfLeftX: CGFloat = 2.01        // from the film edge
    static let perfRightX: CGFloat = 35 - 2.01 - 2.794
    static var picH: CGFloat { pitch - frameLine }   // 13.55: fills the pitch but for a thin frame line
    static var picTop: CGFloat { (pitch - picH) / 2 }   // thin frame lines (0.7 mm) between frames
    // With perforations: the track between the left perfs and the picture.
    // Without: a wider track near the left edge.
    static let trackX: CGFloat = perforated ? 5.56 : 1.6
    static let trackW: CGFloat = perforated ? 2.03 : 3.0
    /// Where the edge print (timecode) runs, outside everything else on the left.
    static let edgePrintX: CGFloat = perforated ? perfLeftX * 0.45 : 0.75
}

/// The across-the-film layout for a picture shape. Without perforations the picture is exactly the
/// material's aspect (13.55 mm tall, as wide as that makes it) and the film is trimmed on the right
/// to a frame line's worth of base, so the film's width follows the material too.
struct FilmGeometry {
    let aspect: CGFloat                         // picture width / height
    init(aspect: CGFloat) { self.aspect = min(max(aspect, 0.3), 3.5) }

    var picH: CGFloat { Film35.picH }
    var picW: CGFloat { Film35.perforated ? 21.0 : picH * aspect }
    var picX: CGFloat { Film35.perforated ? 7.8 : Film35.trackX + Film35.trackW + 0.85 }
    var width: CGFloat { Film35.perforated ? 35 : picX + picW + Film35.frameLine }
}

/// Eases the film into the gate when it comes to rest, instead of jumping the last fraction of a
/// frame. While the film is moving it follows exactly; at rest it glides to the frame's centre
/// (about 0.15 s), like a film settling on the register pin. Far jumps (a click elsewhere) cut.
@MainActor
final class GateSettle {
    private var shown: Double?
    private var lastT: CFTimeInterval = 0
    static let tau = 0.045                       // seconds; ~0.15 s to settle

    /// `target`: where the film should be (cells); `moving`: the hand or the motor is driving it.
    func position(target: Double, moving: Bool, now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        let dt = lastT == 0 ? 0 : min(now - lastT, 0.1)
        lastT = now
        guard let s = shown, !moving, abs(target - s) < 3 else { shown = target; return target }
        let next = s + (target - s) * (1 - exp(-dt / Self.tau))
        shown = abs(target - next) < 0.002 ? target : next
        return shown!
    }
}

/// Peak levels of a clip's audio, used to draw the variable-area soundtrack and the sound reel.
final class AudioEnvelope: @unchecked Sendable {
    let binsPerSecond: Double
    /// One array per lane, values 0…1, already shaped for display. Per channel (1 or 2) — or, for a
    /// `detailed` envelope, the positive and the negative peaks of the mix, for an editor-style waveform.
    let channels: [[Float]]

    init(channels: [[Float]], binsPerSecond: Double = 240) {
        self.channels = channels
        self.binsPerSecond = binsPerSecond
    }

    /// Loudest level of channel `ch` between two source times.
    func level(_ ch: Int, from a: Double, to b: Double) -> Float {
        let lane = channels[min(ch, channels.count - 1)]
        guard !lane.isEmpty else { return 0 }
        var i0 = Int(a * binsPerSecond), i1 = Int(b * binsPerSecond)
        if i1 < i0 { swap(&i0, &i1) }
        i0 = max(0, i0); i1 = min(lane.count - 1, max(i1, i0))
        guard i0 < lane.count else { return 0 }
        var m: Float = 0
        for i in i0...i1 where lane[i] > m { m = lane[i] }
        return m
    }

    /// Reads the audio once (resampled to 24 kHz) and keeps a peak per 1/240 s.
    /// `detailed`: a peak per 1/4000 s, positive and negative apart, kept nearly linear — the spiky
    /// waveform of an audio editor, drawn on the sound reel.
    static func make(asset: AVAsset, track: AVAssetTrack, detailed: Bool = false) async -> AudioEnvelope? {
        let binsPerSecond: Double = detailed ? 4000 : 240
        var sourceChannels = 2
        if let fd = try? await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            sourceChannels = max(1, Int(asbd.mChannelsPerFrame))
        }
        let nch = min(sourceChannels, 2)
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: nch,
        ]
        if sourceChannels > 2 {   // fold surround down to stereo
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }

        let perBin = Int(24_000 / binsPerSecond)
        let lanes = detailed ? 2 : nch
        var peaks = Array(repeating: [Float](), count: lanes)
        var cur = [Float](repeating: 0, count: lanes)
        var n = 0
        var buf = [Float]()
        while let sb = out.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let bytes = CMBlockBufferGetDataLength(bb)
            buf.removeAll(keepingCapacity: true)
            buf.append(contentsOf: repeatElement(0, count: bytes / 4))
            _ = buf.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            var i = 0
            while i + nch <= buf.count {
                if detailed {
                    for c in 0..<nch {
                        let v = buf[i + c]
                        if v > cur[0] { cur[0] = v }
                        if -v > cur[1] { cur[1] = -v }
                    }
                } else {
                    for c in 0..<nch { let v = abs(buf[i + c]); if v > cur[c] { cur[c] = v } }
                }
                i += nch; n += 1
                if n == perBin {
                    for c in 0..<lanes { peaks[c].append(cur[c]); cur[c] = 0 }
                    n = 0
                }
            }
        }
        if n > 0 { for c in 0..<lanes { peaks[c].append(cur[c]) } }
        guard reader.status == .completed || reader.status == .reading else { return nil }

        // Normalise to the clip's loudest peak and lift quiet passages so speech stays visible.
        // (The detailed waveform stays close to linear, so peaks stand out as spikes.)
        let top = max(peaks.joined().max() ?? 0, 0.05)
        let curve: Float = detailed ? 0.85 : 0.6
        let shaped = peaks.map { lane in lane.map { min(1, pow($0 / top, curve)) } }
        return AudioEnvelope(channels: shaped, binsPerSecond: binsPerSecond)
    }
}

/// Closed shape of a bilateral (mirror-image) variable-area track between y0 and y1.
/// `level(y)` returns 0…1; silence leaves a hairline, as on a real print.
func soundtrackPath(centerX: CGFloat, halfWidth: CGFloat, y0: CGFloat, y1: CGFloat, step: CGFloat,
                    level: (CGFloat) -> Float) -> CGPath {
    var ys: [CGFloat] = []
    var y = y0
    while y < y1 { ys.append(y); y += step }
    ys.append(y1)
    let w = ys.map { max(0.35, CGFloat($0 |> level) * halfWidth) }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: centerX - w[0], y: ys[0]))
    for i in 1..<ys.count { path.addLine(to: CGPoint(x: centerX - w[i], y: ys[i])) }
    for i in stride(from: ys.count - 1, through: 0, by: -1) { path.addLine(to: CGPoint(x: centerX + w[i], y: ys[i])) }
    path.closeSubpath()
    return path
}

/// Closed shape of an editor-style waveform between y0 and y1: `level(y)` gives the (left, right)
/// extents 0…1 — negative peaks to the left of the centre line, positive to the right.
func waveformPath(centerX: CGFloat, halfWidth: CGFloat, y0: CGFloat, y1: CGFloat, step: CGFloat,
                  level: (CGFloat) -> (Float, Float)) -> CGPath {
    var ys: [CGFloat] = []
    var y = y0
    while y < y1 { ys.append(y); y += step }
    ys.append(y1)
    let w = ys.map { level($0) }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: centerX - max(0.5, CGFloat(w[0].0) * halfWidth), y: ys[0]))
    for i in 1..<ys.count { path.addLine(to: CGPoint(x: centerX - max(0.5, CGFloat(w[i].0) * halfWidth), y: ys[i])) }
    for i in stride(from: ys.count - 1, through: 0, by: -1) {
        path.addLine(to: CGPoint(x: centerX + max(0.5, CGFloat(w[i].1) * halfWidth), y: ys[i]))
    }
    path.closeSubpath()
    return path
}

infix operator |>: AdditionPrecedence
private func |> <A, B>(a: A, f: (A) -> B) -> B { f(a) }

extension Editor {
    /// Level for a lane of the optical soundtrack at a span of sequence time (nil where there is no sound).
    /// In the reel the print carries the mix, as a release print would: the picture's own sound
    /// together with the music on the sound reel.
    func soundLevel(lane: Int, from t0: Double, to t1: Double) -> Float? {
        let picture = pictureSoundLevel(lane: lane, from: t0, to: t1)
        guard mode == .reel, let m = musicLevel(from: t0, to: t1) else { return picture }
        let music = pow(m, 0.6 / 0.85)          // the music waveform is near-linear; match the track's curve
        return max(picture ?? 0, music)
    }

    private func pictureSoundLevel(lane: Int, from t0: Double, to t1: Double) -> Float? {
        let segs = segments
        let D = segs.reduce(0) { $0 + $1.length }
        let mid = (t0 + t1) / 2
        guard mid >= 0, mid < D, let l = locate(mid, in: segs), let env = envelopes[l.segment.mediaID] else { return nil }
        let half = abs(t1 - t0) / 2
        let a = max(l.segment.start, l.src - half), b = min(l.segment.end, l.src + half)
        return env.level(lane, from: a, to: b)
    }

    /// Analyse a clip's audio in the background; the soundtrack appears when it is done.
    func loadEnvelope(for m: MediaClip) {
        guard let track = m.audioTrack, envelopes[m.id] == nil else { return }
        let asset = m.asset, id = m.id
        Task.detached(priority: .utility) {
            let env = await AudioEnvelope.make(asset: asset, track: track)
            await MainActor.run { if let env { self.envelopes[id] = env } }
        }
    }
}
