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

    var isRunning: Bool { player.rate != 0 && !cranking }

    // Hand-cranking with sound: the hand moves `target`; the player runs after it at the hand's speed.
    private(set) var cranking = false
    private var crankLast: Double = 0
    private var crankVel: Double = 0

    /// Current playhead in sequence seconds.
    var time: Double {
        if cranking { return target }
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
        if cranking { cranking = false; crankVel = 0; player.pause() }
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
        if cranking { cranking = false; crankVel = 0 }
        player.rate = rate
    }

    /// Move the playhead by hand; `crankTick` makes the player follow at the same speed, so it sounds.
    func crank(to t: Double) {
        if !cranking { cranking = true; crankLast = target; crankVel = 0 }
        target = clamp(t)
    }

    /// Called every display frame while cranking. Forward motion plays (pitch follows speed, like a
    /// Moviola); backwards or barely moving is silent and the picture just follows. `idle` ends it.
    func crankTick(dt: Double, idle: Bool) {
        guard cranking, dt > 0 else { return }
        let v = (target - crankLast) / dt
        crankLast = target
        crankVel = crankVel * 0.7 + v * 0.3
        if idle { endCrank(); return }
        let rate = Float(min(3, crankVel))
        if rate > 0.1 {
            let cur = player.currentTime().seconds
            if player.rate == 0 || !cur.isFinite || abs(cur - target) > 0.2 {
                player.seek(to: cm(target), toleranceBefore: cm(0.02), toleranceAfter: cm(0.02))
            }
            player.rate = rate
        } else {
            if player.rate != 0 { player.pause() }
            pendingSeek = target
            chase()
        }
    }

    /// Stop cranking and settle exactly on the target frame.
    func endCrank() {
        guard cranking else { return }
        cranking = false
        crankVel = 0
        player.pause()
        pendingSeek = target
        chase()
    }

    /// Stop and adopt wherever the player actually is.
    func pause() {
        if cranking { endCrank(); return }
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
