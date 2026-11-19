import Foundation
import AVFoundation

struct LoadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A source clip loaded from disk.
struct MediaClip: Identifiable {
    var id = UUID()
    let url: URL
    let name: String
    let asset: AVURLAsset
    let duration: Double
    let fps: Double
    /// Size as displayed (preferredTransform applied).
    let displaySize: CGSize
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?

    var markIn: Double?
    var markOut: Double?
    var lastTime: Double = 0

    var aspect: Double { Double(displaySize.width / max(displaySize.height, 1)) }

    static func load(url: URL, id: UUID = UUID()) async throws -> MediaClip {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw LoadError(message: L("映像トラックがありません"))
        }
        let (size, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return MediaClip(id: id, url: url, name: url.lastPathComponent, asset: asset,
                         duration: duration, fps: rate > 0 ? Double(rate) : 24,
                         displaySize: CGSize(width: abs(rect.width), height: abs(rect.height)),
                         naturalSize: size, preferredTransform: transform,
                         videoTrack: video, audioTrack: audio)
    }
}

/// One splice of film in the reel: a range of a source clip.
struct Segment: Identifiable, Codable, Hashable {
    var id = UUID()
    var mediaID: UUID
    var start: Double
    var end: Double
    var length: Double { end - start }
}

enum EditMode { case source, reel }

struct Located {
    let index: Int
    let segment: Segment
    /// Sequence time where this segment begins.
    let start: Double
    /// Corresponding time inside the source clip.
    let src: Double
}

func locate(_ t: Double, in segments: [Segment]) -> Located? {
    guard !segments.isEmpty else { return nil }
    var acc = 0.0
    for (i, s) in segments.enumerated() {
        if t < acc + s.length || i == segments.count - 1 {
            let off = min(max(t - acc, 0), max(s.length - 1e-4, 0))
            return Located(index: i, segment: s, start: acc, src: s.start + off)
        }
        acc += s.length
    }
    return nil
}

func cm(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 90_000) }
