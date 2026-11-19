import AVFoundation
import CoreGraphics

/// 35mm print geometry in millimetres (Academy frame, 4-perf, optical soundtrack).
/// Everything that draws film (strip, viewer) scales these by "pixels per mm".
enum Film35 {
    static let width: CGFloat = 35
    static let pitch: CGFloat = 19              // one frame = 4 perforations
    static let perfPitch: CGFloat = 4.75
    static let perfW: CGFloat = 2.794           // KS perforation: wider than tall
    static let perfH: CGFloat = 1.981
    static let perfCorner: CGFloat = 0.5
    static let perfLeftX: CGFloat = 2.01        // from the film edge
    static let perfRightX: CGFloat = 35 - 2.01 - 2.794
    static let trackX: CGFloat = 5.56           // optical soundtrack, between left perfs and picture
    static let trackW: CGFloat = 2.03
    static let picX: CGFloat = 7.8              // Academy picture area (sits right of centre)
    static let picW: CGFloat = 21.0
    static let picH: CGFloat = 15.2
    static var picTop: CGFloat { (pitch - picH) / 2 }   // thick frame lines above and below
}

/// Peak levels of a clip's audio, used to draw the variable-area soundtrack.
final class AudioEnvelope: @unchecked Sendable {
    static let binsPerSecond: Double = 240
    /// One array per channel (1 or 2), values 0…1, already shaped for display.
    let channels: [[Float]]

    init(channels: [[Float]]) { self.channels = channels }

    /// Loudest level of channel `ch` between two source times.
    func level(_ ch: Int, from a: Double, to b: Double) -> Float {
        let lane = channels[min(ch, channels.count - 1)]
        guard !lane.isEmpty else { return 0 }
        var i0 = Int(a * Self.binsPerSecond), i1 = Int(b * Self.binsPerSecond)
        if i1 < i0 { swap(&i0, &i1) }
        i0 = max(0, i0); i1 = min(lane.count - 1, max(i1, i0))
        guard i0 < lane.count else { return 0 }
        var m: Float = 0
        for i in i0...i1 where lane[i] > m { m = lane[i] }
        return m
    }

    /// Reads the audio once (resampled to 24 kHz) and keeps a peak per 1/240 s.
    static func make(asset: AVAsset, track: AVAssetTrack) async -> AudioEnvelope? {
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
        var peaks = Array(repeating: [Float](), count: nch)
        var cur = [Float](repeating: 0, count: nch)
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
                for c in 0..<nch { let v = abs(buf[i + c]); if v > cur[c] { cur[c] = v } }
                i += nch; n += 1
                if n == perBin {
                    for c in 0..<nch { peaks[c].append(cur[c]); cur[c] = 0 }
                    n = 0
                }
            }
        }
        if n > 0 { for c in 0..<nch { peaks[c].append(cur[c]) } }
        guard reader.status == .completed || reader.status == .reading else { return nil }

        // Normalise to the clip's loudest peak and lift quiet passages so speech stays visible.
        let top = max(peaks.joined().max() ?? 0, 0.05)
        let shaped = peaks.map { lane in lane.map { min(1, pow($0 / top, 0.6)) } }
        return AudioEnvelope(channels: shaped)
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

infix operator |>: AdditionPrecedence
private func |> <A, B>(a: A, f: (A) -> B) -> B { f(a) }

extension Editor {
    /// Level for a lane of the soundtrack at a span of sequence time (nil outside the material).
    func soundLevel(lane: Int, from t0: Double, to t1: Double) -> Float? {
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
