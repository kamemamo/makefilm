import Foundation

/// Trimming a cut already in the reel: drag a splice on the strip (or [ ] { } at the gate) to make the
/// cut before it shorter or longer at its tail — or, with ⌥, the cut after it at its head. It ripples:
/// everything after the splice, picture and music alike, moves up or back by the change.
extension Editor {
    struct TrimDrag {
        let index: Int                 // the outgoing cut; the splice is at its end
        let head: Bool                 // false: the outgoing cut's tail, true: the incoming cut's head
        let reel: [Segment]
        let music: [MusicClip]
        let spliceAt: Double           // reel time of the splice before trimming
        var frames = 0                 // + longer, − shorter
    }

    /// Reel times of the splices (the joins between cuts).
    var spliceTimes: [Double] {
        var acc = 0.0
        return reel.dropLast().map { acc += $0.length; return acc }
    }

    func beginTrim(splice i: Int, head: Bool) {
        guard mode == .reel, i >= 0, i + 1 < reel.count else { return }
        stop()
        pushUndo()
        trimDrag = TrimDrag(index: i, head: head, reel: reel, music: music,
                            spliceAt: reel.prefix(i + 1).reduce(0) { $0 + $1.length })
    }

    /// The pointer has moved `d` seconds of reel time from where the drag began (toward later = longer).
    func updateTrim(by d: Double) {
        guard var t = trimDrag else { return }
        let seg = t.reel[t.head ? t.index + 1 : t.index]
        let fps = clip(seg.mediaID)?.fps ?? engine.fps
        let n = Int((d * fps).rounded())
        guard n != t.frames else { return }
        t.frames = applyTrim(t, frames: n)
        trimDrag = t
        toast(L(t.head ? "後ろのカットの頭 %+ld コマ" : "前のカットのお尻 %+ld コマ", t.frames))
    }

    func endTrim() {
        guard let t = trimDrag else { return }
        trimDrag = nil
        if t.frames == 0 { _ = undoStack.popLast(); return }
        // Put the edit in the gate: the last frame of the outgoing cut, or the first of the incoming one.
        let at = reel.prefix(t.index + 1).reduce(0) { $0 + $1.length }
        let fd = 1 / (clip(reel[t.head ? t.index + 1 : t.index].mediaID)?.fps ?? engine.fps)
        reelChanged(keepingTime: t.head ? at + fd / 2 : max(0, at - fd / 2))
    }

    /// [ ] trim the tail of the cut before the splice nearest the gate, { } the head of the cut after it.
    func trimAtGate(head: Bool, frames n: Int) {
        guard mode == .reel else { return }
        let splices = spliceTimes
        guard let i = splices.indices.min(by: { abs(splices[$0] - time) < abs(splices[$1] - time) }) else {
            toast(L("継ぎ目がありません")); return
        }
        beginTrim(splice: i, head: head)
        guard let t = trimDrag else { return }
        trimDrag?.frames = applyTrim(t, frames: n)
        if trimDrag?.frames == 0 { toast(L("これ以上動かせません")) }
        else { toast(L(head ? "後ろのカットの頭 %+ld コマ" : "前のカットのお尻 %+ld コマ", trimDrag!.frames)) }
        endTrim()
    }

    /// Apply `n` frames (from the state at the start of the drag) and return how many actually fit:
    /// a cut keeps at least one frame and can't reach past the ends of its material.
    private func applyTrim(_ t: TrimDrag, frames n: Int) -> Int {
        var r = t.reel
        let k = t.head ? t.index + 1 : t.index
        let seg = r[k]
        guard let m = clip(seg.mediaID) else { return 0 }
        let fd = 1 / m.fps
        var change: Double
        var got: Int
        if t.head {
            let room = Int(((seg.start) * m.fps + 1e-6).rounded(.down))              // frames before the head
            let spare = Int(((seg.end - seg.start) * m.fps + 1e-6).rounded(.down)) - 1
            got = max(-spare, min(room, n))
            r[k].start = seg.start - Double(got) * fd
            change = seg.start - r[k].start
        } else {
            let room = Int(((m.duration - seg.end) * m.fps + 1e-6).rounded(.down))   // frames after the tail
            let spare = Int(((seg.end - seg.start) * m.fps + 1e-6).rounded(.down)) - 1
            got = max(-spare, min(room, n))
            r[k].end = seg.end + Double(got) * fd
            change = r[k].end - seg.end
        }
        reel = r
        // the music after the splice moves with the picture
        music = t.music.map { c in
            var c = c
            if c.at >= t.spliceAt - 1e-6 { c.at = max(0, c.at + change) }
            return c
        }
        return got
    }
}
