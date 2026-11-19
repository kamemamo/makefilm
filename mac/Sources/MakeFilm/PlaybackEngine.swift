import AVFoundation

/// Wraps AVPlayer. While stopped/scrubbing the playhead is our own `target`
/// (so the strip responds instantly) and seeks chase it with zero tolerance.
@MainActor
final class PlaybackEngine {
    let player: AVPlayer = {
        let p = AVPlayer()
        p.actionAtItemEnd = .pause
        return p
    }()

    private(set) var duration: Double = 0
    private(set) var fps: Double = 24
    private var target: Double = 0
    private var seekInFlight = false
    private var pendingSeek: Double?

    var isRunning: Bool { player.rate != 0 }

    /// Current playhead in sequence seconds.
    var time: Double {
        if player.rate != 0 {
            let c = player.currentTime().seconds
            if c.isFinite { return clamp(c) }
        }
        return target
    }

    func setItem(_ item: AVPlayerItem?, duration: Double, fps: Double, at t: Double) {
        player.pause()
        player.replaceCurrentItem(with: item)
        self.duration = item == nil ? 0 : duration
        self.fps = fps > 0 ? fps : 24
        seekInFlight = false
        pendingSeek = nil
        target = 0
        scrub(to: t)
    }

    func clamp(_ t: Double) -> Double { min(max(t, 0), max(duration - 0.0005, 0)) }

    func scrub(to t: Double) {
        target = clamp(t)
        guard player.currentItem != nil else { return }
        pendingSeek = target
        chase()
    }

    private func chase() {
        guard !seekInFlight, let p = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        player.seek(to: cm(p), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                self.chase()
            }
        }
    }

    func play(rate: Float) {
        player.rate = rate
    }

    /// Stop and adopt wherever the player actually is.
    func pause() {
        let wasRunning = player.rate != 0
        let now = time
        player.pause()
        if wasRunning { target = now }
    }

    /// Called when the player stopped on its own (end of item).
    func adoptPlayerTime() {
        let c = player.currentTime().seconds
        if c.isFinite { target = clamp(c) }
    }

    func canPlay(rate: Double) -> Bool {
        guard let item = player.currentItem else { return false }
        if rate < -1 { return item.canPlayFastReverse }
        if rate < 0 { return item.canPlayReverse }
        if rate > 2 { return item.canPlayFastForward }
        return true
    }
}
