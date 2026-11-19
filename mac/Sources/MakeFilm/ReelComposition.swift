import AVFoundation

/// Builds one continuous AVComposition from the reel so playback and export are seamless.
struct ReelComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let duration: Double
    let fps: Double
    /// Volume and fades of the sound-reel tracks (nil when there is no music).
    let audioMix: AVAudioMix?

    static func build(_ segments: [Segment], clips: [UUID: MediaClip],
                      music: [MusicClip] = [], sources: [UUID: AudioSource] = [:]) -> ReelComposition? {
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

        // Sound reel: each music clip on its own track (they may overlap), cut off at the end of the picture.
        let reelEnd = cursor
        var params: [AVAudioMixInputParameters] = []
        for c in music {
            guard let src = sources[c.sourceID], c.at < reelEnd.seconds,
                  let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let len = min(c.length, reelEnd.seconds - c.at)
            guard len > 0.01 else { comp.removeTrack(t); continue }
            let range = CMTimeRange(start: cm(c.start), duration: cm(len))
            do { try t.insertTimeRange(range, of: src.track, at: cm(c.at)) } catch { comp.removeTrack(t); continue }
            let p = AVMutableAudioMixInputParameters(track: t)
            p.setVolume(Float(c.gain), at: .zero)
            if c.fadeIn > 0 {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(c.gain),
                                timeRange: CMTimeRange(start: cm(c.at), duration: cm(min(c.fadeIn, len))))
            }
            if c.fadeOut > 0 && c.fadeOut < c.length + 0.001 {
                let fadeStart = c.at + c.length - c.fadeOut
                if fadeStart < reelEnd.seconds {
                    p.setVolumeRamp(fromStartVolume: Float(c.gain), toEndVolume: 0,
                                    timeRange: CMTimeRange(start: cm(fadeStart), duration: cm(c.fadeOut)))
                }
            }
            params.append(p)
        }
        let mix: AVAudioMix? = params.isEmpty ? nil : {
            let m = AVMutableAudioMix(); m.inputParameters = params; return m
        }()

        let vc = AVMutableVideoComposition()
        vc.renderSize = render
        vc.frameDuration = CMTime(seconds: 1 / first.fps, preferredTimescale: 600_000)
        vc.instructions = instructions
        return ReelComposition(composition: comp, videoComposition: vc,
                               duration: cursor.seconds, fps: first.fps, audioMix: mix)
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
