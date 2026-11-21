import Foundation

/// Trimming cuts already in the reel by moving a splice on the strip.
///
/// - Drag a splice (or ] [ at the gate): **roll** — the splice moves, so the cut before it gets longer
///   by exactly what the cut after it loses (or the other way). Nothing else in the reel moves.
/// - ⌥-drag (or } {): **the cut before only** — its tail gets longer or shorter, and the picture after
///   the splice moves up or back by the change.
/// - ⇧-drag: **the cut after only** — its head gets longer or shorter, rippling the same way.
/// The music on the sound reel always stays where it is: trimming moves only the picture against it.
extension Editor {
    enum TrimKind { case roll, tail, head }

    struct TrimDrag {
        let index: Int                 // the cut before the splice; the cut after it is index + 1
        let kind: TrimKind
        let reel: [Segment]
        let spliceAt: Double           // reel time of the splice before trimming
        var before = 0                 // frames the cut before gained (−: lost)
        var after = 0                  // frames the cut after gained (−: lost)
    }

    /// Reel times of the splices (the joins between cuts).
    var spliceTimes: [Double] {
        var acc = 0.0
        return reel.dropLast().map { acc += $0.length; return acc }
    }

    func beginTrim(splice i: Int, kind: TrimKind) {
        guard mode == .reel, i >= 0, i + 1 < reel.count else { return }
        stop()
        pushUndo()
        trimDrag = TrimDrag(index: i, kind: kind, reel: reel,
                            spliceAt: reel.prefix(i + 1).reduce(0) { $0 + $1.length })
    }

    /// The pointer has moved `d` seconds of reel time from where the drag began (+ = toward later).
    func updateTrim(by d: Double) {
        guard let t = trimDrag else { return }
        let fps = clip(t.reel[t.kind == .head ? t.index + 1 : t.index].mediaID)?.fps ?? engine.fps
        applyTrim(frames: Int((d * fps).rounded()))
        toast(trimSummary)
    }

    func endTrim() {
        guard let t = trimDrag else { return }
        trimDrag = nil
        if t.before == 0 && t.after == 0 { _ = undoStack.popLast(); return }
        // Put the edit in the gate: the first frame after the splice (for a tail-only trim, the last
        // frame before it, which is the frame that changed).
        let at = reel.prefix(t.index + 1).reduce(0) { $0 + $1.length }
        let fd = 1 / (clip(reel[t.index].mediaID)?.fps ?? engine.fps)
        reelChanged(keepingTime: t.kind == .tail ? max(0, at - fd / 2) : at + fd / 2)
        toast(trimSummary(t))
    }

    /// ] [ roll the splice nearest the gate a frame later / earlier; } { lengthen / shorten the cut
    /// before it (rippling).
    func trimAtGate(kind: TrimKind, frames n: Int) {
        guard mode == .reel else { return }
        let splices = spliceTimes
        guard let i = splices.indices.min(by: { abs(splices[$0] - time) < abs(splices[$1] - time) }) else {
            toast(L("継ぎ目がありません")); return
        }
        beginTrim(splice: i, kind: kind)
        applyTrim(frames: n)
        if let t = trimDrag, t.before == 0 && t.after == 0 { toast(L("これ以上動かせません")) }
        endTrim()
    }

    /// "#2 +3 コマ・#3 −3 コマ": what each cut gained or lost.
    var trimSummary: String { trimDrag.map(trimSummary) ?? "" }

    private func trimSummary(_ t: TrimDrag) -> String {
        var parts: [String] = []
        if t.kind != .head { parts.append(L("#%ld %+ld コマ", t.index + 1, t.before)) }
        if t.kind != .tail { parts.append(L("#%ld %+ld コマ", t.index + 2, t.after)) }
        return parts.joined(separator: "・")
    }

    /// Apply `n` frames (from the state at the start of the drag; + moves the splice / the picture
    /// later). Clamped so every cut keeps a frame and none reaches past the ends of its material.
    private func applyTrim(frames n: Int) {
        guard var t = trimDrag else { return }
        var r = t.reel
        let a = r[t.index], b = r[t.index + 1]
        guard let ma = clip(a.mediaID), let mb = clip(b.mediaID) else { return }
        func frames(_ s: Double, _ m: MediaClip) -> Int { Int((s * m.fps + 1e-6).rounded(.down)) }
        let aAfter = frames(ma.duration - a.end, ma), aSpare = frames(a.length, ma) - 1   // room past a's tail / frames a can lose
        let bBefore = frames(b.start, mb), bSpare = frames(b.length, mb) - 1              // room before b's head / frames b can lose
        switch t.kind {
        case .roll:
            // the splice moves n frames: a gains what b loses
            let k = max(-min(aSpare, bBefore), min(n, min(aAfter, bSpare)))
            let dt = Double(k) / ma.fps
            r[t.index].end = a.end + dt
            r[t.index + 1].start = b.start + (dt * mb.fps).rounded() / mb.fps
            t.before = k; t.after = -Int((dt * mb.fps).rounded())
        case .tail:
            let k = max(-aSpare, min(n, aAfter))
            r[t.index].end = a.end + Double(k) / ma.fps
            t.before = k; t.after = 0
        case .head:
            // + : the picture after the splice slides later, showing earlier frames → longer
            let k = max(-bSpare, min(n, bBefore))
            r[t.index + 1].start = b.start - Double(k) / mb.fps
            t.before = 0; t.after = k
        }
        reel = r                       // the music stays put
        trimDrag = t
    }
}
