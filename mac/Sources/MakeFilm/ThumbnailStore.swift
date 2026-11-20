import AVFoundation
import CoreGraphics

/// Lazily generates small frames for the film strip and bin.
/// Requests are made every draw; the worker always picks the frame nearest the gate first.
@MainActor
final class ThumbnailStore {
    struct Key: Hashable { let media: UUID; let index: Int }

    /// Strip cells per second (thumbnails are made one per cell). May be fractional (29.97).
    var fps: Double = 12 {
        didSet { if oldValue != fps { reset() } }
    }
    /// Called when a frame requested by the bin/media list (a "keep" request) becomes available.
    var onKeepFulfilled: (() -> Void)?

    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var want: [UUID: Set<Int>] = [:]
    private var keep: [UUID: Set<Int>] = [:]
    private var failed: Set<Key> = []
    private var focus: [UUID: Int] = [:]
    private var generators: [UUID: AVAssetImageGenerator] = [:]
    private var maxIndex: [UUID: Int] = [:]
    private var working: Set<UUID> = []
    private let cap = 4000

    func register(_ m: MediaClip) {
        let g = AVAssetImageGenerator(asset: m.asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 240, height: 240)
        generators[m.id] = g
        maxIndex[m.id] = Int(((m.duration - 0.001) * fps).rounded(.down))
        applyTolerance()
    }

    private func applyTolerance() {
        let tol = cm(0.4 / fps)
        for g in generators.values {
            g.requestedTimeToleranceBefore = tol
            g.requestedTimeToleranceAfter = tol
        }
    }

    /// Forget every clip (used when another project is opened).
    func removeAll() {
        for g in generators.values { g.cancelAllCGImageGeneration() }
        generators.removeAll(); maxIndex.removeAll(); focus.removeAll(); keep.removeAll()
        reset()
    }

    func reset() {
        images.removeAll(); order.removeAll(); want.removeAll(); failed.removeAll()
        for id in generators.keys {
            if let g = generators[id] { g.cancelAllCGImageGeneration() }
        }
        applyTolerance()
        // maxIndex depends on fps; recompute lazily from the stored generators' assets is not possible
        // without duration, so callers re-register via `updateDurations`.
    }

    func updateMaxIndex(_ m: MediaClip) {
        maxIndex[m.id] = Int(((m.duration - 0.001) * fps).rounded(.down))
    }

    func index(for seconds: Double) -> Int { Int((seconds * fps + 1e-6).rounded(.down)) }

    // MARK: per-frame requests from the strip

    func beginFrame() {
        for k in want.keys { want[k]?.removeAll(keepingCapacity: true) }
    }

    func setFocus(_ media: UUID, _ index: Int) { focus[media] = index }

    /// Returns the cached image or queues it for generation (for this frame only).
    func request(_ media: UUID, _ index: Int) -> CGImage? {
        let key = Key(media: media, index: index)
        if let img = images[key] { return img }
        if !failed.contains(key) { want[media, default: []].insert(index) }
        return nil
    }

    func endFrame() {
        for id in generators.keys where !(want[id]?.isEmpty ?? true) || !(keep[id]?.isEmpty ?? true) {
            pump(id)
        }
    }

    /// Persistent request (bin, media list). Returns the image if cached.
    func keepImage(_ media: UUID, _ index: Int) -> CGImage? {
        let i = max(0, min(index, maxIndex[media] ?? index))
        if let img = images[Key(media: media, index: i)] { return img }
        keep[media, default: []].insert(i)
        pump(media)
        return nil
    }

    func peek(_ media: UUID, _ index: Int) -> CGImage? { images[Key(media: media, index: index)] }

    private func nextIndex(_ id: UUID) -> (Int, Bool)? {
        let f = focus[id] ?? 0
        var best: (Int, Bool)?
        var bestD = Int.max
        for (set, isKeep) in [(want[id] ?? [], false), (keep[id] ?? [], true)] {
            for i in set {
                let d = abs(i - f) + (isKeep ? 6 : 0)
                if d < bestD { bestD = d; best = (i, isKeep) }
            }
        }
        return best
    }

    private func pump(_ id: UUID) {
        guard !working.contains(id), let gen = generators[id] else { return }
        working.insert(id)
        let fpsAtStart = fps
        Task { @MainActor in
            defer { self.working.remove(id) }
            while self.fps == fpsAtStart, let (idx, isKeep) = self.nextIndex(id) {
                self.want[id]?.remove(idx)
                let key = Key(media: id, index: idx)
                if self.images[key] != nil {
                    if isKeep { self.keep[id]?.remove(idx) }
                    continue
                }
                let time = cm((Double(idx) + 0.5) / fpsAtStart)
                let img = try? await gen.image(at: time).image
                guard self.fps == fpsAtStart else { break }
                if let img {
                    self.store(key, img)
                } else {
                    self.failed.insert(key)
                }
                if self.keep[id]?.remove(idx) != nil { self.onKeepFulfilled?() }
            }
        }
    }

    private func store(_ key: Key, _ img: CGImage) {
        if images[key] == nil { order.append(key) }
        images[key] = img
        if order.count > cap {
            let drop = order.count - cap
            for k in order.prefix(drop) { images.removeValue(forKey: k) }
            order.removeFirst(drop)
        }
    }
}
