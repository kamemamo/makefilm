import AVFoundation
import QuartzCore

/// Wraps AVPlayer. While stopped/scrubbing the playhead is our own `target`
/// (so the strip responds instantly) and seeks chase it with zero tolerance.
@MainActor
final class PlaybackEngine {
    let player: AVPlayer = {
        let p = AVPlayer()
        p.actionAtItemEnd = .pause
        return p
    }()

    /// Player position as last reported by a periodic observer. Asking `currentTime()` right after
    /// the player starts can block the main thread for up to a second, so cranking reads this instead.
    private var observedTime: Double = 0
    private var timeObserver: Any?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.observedTime = t.seconds }
        }
    }

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
    private var coasting = false
    private var lastInputAt: CFTimeInterval = 0
    private var lastCrankTickAt: CFTimeInterval = 0
    private var crankWatchdog: Timer?
    private func now() -> CFTimeInterval { CACurrentMediaTime() }

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
        if cranking { cranking = false; coasting = false; crankVel = 0; player.pause() }
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
        if !cranking {
            cranking = true; coasting = false; crankLast = target; crankVel = 0; lastInputAt = now(); lastCrankTickAt = now()
            // If frame updates stop (window hidden or on another Space), don't leave the player running.
            crankWatchdog?.invalidate()
            crankWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.cranking && self.now() - self.lastCrankTickAt > 0.3 { self.endCrank() }
                }
            }
        }
        target = clamp(t)
    }

    /// Called every display frame while cranking. Forward motion plays (pitch follows speed, like a
    /// Moviola); backwards or barely moving is silent and the picture just follows.
    ///
    /// Tuned for Bluetooth headphones, which hear audio 0.2–0.3 s late and lose it on every pause/seek:
    /// - while the hand moves, the player keeps running and catches up by changing speed, not by seeking
    ///   (it only re-seeks if it falls more than half a second behind);
    /// - when the hand stops (`idle`), the film coasts to a halt over about 0.4 s instead of cutting off,
    ///   and the picture coasts with it.
    func crankTick(dt: Double, idle: Bool) {
        guard cranking, dt > 0 else { return }
        lastCrankTickAt = now()
        if idle && !coasting { coasting = true }
        if !idle && coasting { coasting = false }

        if coasting {
            // ease the speed down; the playhead follows the player so nothing jumps at the end
            crankVel *= pow(0.9, dt * 60)          // ~0.4 s from normal speed to a stop
            if player.rate > 0, observedTime.isFinite {
                target = clamp(max(target, observedTime)); crankLast = target
            }
            if crankVel < 0.08 || player.rate <= 0 { endCrank(); return }
            player.rate = Float(crankVel)
            return
        }

        // Scroll and drag events arrive in bursts: only update the speed when the hand actually moved,
        // and hold it in between so playback (and the sound) doesn't stutter to a stop.
        if abs(target - crankLast) > 1e-6 {
            let v = (target - crankLast) / max(dt, now() - lastInputAt)
            crankVel = crankVel == 0 ? v : crankVel * 0.6 + v * 0.4
            crankLast = target
            lastInputAt = now()
        }
        if crankVel > 0.1 {
            let cur = observedTime
            if player.rate == 0 || !cur.isFinite || abs(cur - target) > 0.5 {
                player.seek(to: cm(target), toleranceBefore: cm(0.04), toleranceAfter: cm(0.04))
                observedTime = target
                player.rate = Float(min(3, crankVel))
            } else {
                // steer: run a little faster or slower to close the gap, keeping the sound continuous
                let steer = (target - cur) * 1.5
                player.rate = Float(min(3, max(0.15, crankVel + steer)))
            }
        } else {
            if player.rate != 0 { player.pause() }
            pendingSeek = target
            chase()
        }
    }

    /// Stop cranking and settle exactly on the target frame.
    func endCrank() {
        crankWatchdog?.invalidate(); crankWatchdog = nil
        guard cranking else { return }
        cranking = false
        coasting = false
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
