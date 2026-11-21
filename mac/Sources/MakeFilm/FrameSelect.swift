import Foundation

/// Picking frames on the strip and taking them out of the reel: tick the box on a frame (drag across
/// boxes to tick a run, ⇧-click to tick everything up to it), then ⌫ deletes the ticked frames.
/// The cuts close up behind them; frames taken from the middle of a cut leave a splice there.
/// The music stays where it is.
extension Editor {
    /// Strip cells (at `stripRate`) that are ticked.
    var hasFrameSelection: Bool { !frameSelection.isEmpty }

    func setFrame(_ k: Int, selected on: Bool) {
        if on { frameSelection.insert(k) } else { frameSelection.remove(k) }
    }

    /// ⇧-click: tick every frame from the last one ticked to `k`.
    func extendFrameSelection(to k: Int) {
        guard let a = frameAnchor else { frameSelection.insert(k); frameAnchor = k; return }
        for i in min(a, k)...max(a, k) { frameSelection.insert(i) }
    }

    func clearFrameSelection() {
        frameSelection.removeAll()
        frameAnchor = nil
    }

    /// ⌫ with frames ticked: take them out of the reel.
    func deleteSelectedFrames() {
        guard mode == .reel, !frameSelection.isEmpty else { return }
        stop()
        let F = stripRate
        // contiguous runs of ticked cells, as reel time ranges, last first so earlier times hold
        var runs: [(Int, Int)] = []
        for k in frameSelection.sorted() {
            if let last = runs.last, last.1 + 1 == k { runs[runs.count - 1].1 = k } else { runs.append((k, k)) }
        }
        let count = frameSelection.count
        pushUndo()
        for (a, b) in runs.reversed() { removeReelRange(Double(a) / F, Double(b + 1) / F) }
        clearFrameSelection()
        reelChanged(keepingTime: min(Double(runs[0].0) / F, max(0, reelDuration - 0.001)))
        toast(L("%ld コマを削除しました", count))
    }

    /// Cut the stretch [t0, t1) of reel time out of the reel, to the frames of each clip.
    private func removeReelRange(_ t0: Double, _ t1: Double) {
        var out: [Segment] = []
        var acc = 0.0
        for s in reel {
            let a = acc, b = acc + s.length
            acc = b
            guard b > t0 + 1e-6, a < t1 - 1e-6, let m = clip(s.mediaID) else { out.append(s); continue }
            let fd = 1 / m.fps
            let cutA = ((s.start + max(t0, a) - a) * m.fps).rounded() / m.fps
            let cutB = ((s.start + min(t1, b) - a) * m.fps).rounded() / m.fps
            if cutA - s.start >= fd * 0.99 { var h = s; h.id = UUID(); h.end = cutA; out.append(h) }
            if s.end - cutB >= fd * 0.99 { var t = s; t.id = UUID(); t.start = cutB; out.append(t) }
        }
        reel = out
    }
}
