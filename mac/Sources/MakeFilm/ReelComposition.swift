import AVFoundation

/// Builds one continuous AVComposition from the reel so playback and export are seamless.
struct ReelComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let duration: Double
    let fps: Double

    static func build(_ segments: [Segment], clips: [UUID: MediaClip]) -> ReelComposition? {
        guard let first = segments.first.flatMap({ clips[$0.mediaID] }) else { return nil }
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        // Even dimensions keep the encoders happy.
        let render = CGSize(width: (first.displaySize.width / 2).rounded() * 2,
                            height: (first.displaySize.height / 2).rounded() * 2)
        var cursor = CMTime.zero
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var hasAudio = false

        for seg in segments {
            guard let m = clips[seg.mediaID] else { continue }
            let range = CMTimeRange(start: cm(seg.start), end: cm(seg.end))
            do {
                try vTrack.insertTimeRange(range, of: m.videoTrack, at: cursor)
            } catch { continue }
            if let a = m.audioTrack {
                if (try? aTrack.insertTimeRange(range, of: a, at: cursor)) != nil { hasAudio = true }
            }
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
            layer.setTransform(fitTransform(m, into: render), at: cursor)
            ins.layerInstructions = [layer]
            instructions.append(ins)
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { return nil }
        if !hasAudio { comp.removeTrack(aTrack) }

        let vc = AVMutableVideoComposition()
        vc.renderSize = render
        vc.frameDuration = CMTime(seconds: 1 / first.fps, preferredTimescale: 600_000)
        vc.instructions = instructions
        return ReelComposition(composition: comp, videoComposition: vc,
                               duration: cursor.seconds, fps: first.fps)
    }

    /// Orient the clip, then letterbox it into the render size.
    private static func fitTransform(_ m: MediaClip, into render: CGSize) -> CGAffineTransform {
        let t = m.preferredTransform
        let rect = CGRect(origin: .zero, size: m.naturalSize).applying(t)
        var out = t.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let s = min(render.width / rect.width, render.height / rect.height)
        out = out.concatenating(CGAffineTransform(scaleX: s, y: s))
        out = out.concatenating(CGAffineTransform(translationX: (render.width - rect.width * s) / 2,
                                                  y: (render.height - rect.height * s) / 2))
        return out
    }
}
