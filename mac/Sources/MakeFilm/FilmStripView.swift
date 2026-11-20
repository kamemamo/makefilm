import SwiftUI
import AppKit

/// The vertical 35mm strip. Frames run through a fixed gate in the middle,
/// like film threaded through a Moviola. Drag it like hand-cranking.
/// With `overview`, it is the narrow whole-reel strip shown beside a zoomed strip, with the zoomed
/// stretch outlined.
struct FilmStripView: NSViewRepresentable {
    let editor: Editor
    var overview = false
    func makeNSView(context: Context) -> FilmStripNSView {
        let v = FilmStripNSView()
        v.editor = editor
        v.overview = overview
        return v
    }
    func updateNSView(_ nsView: FilmStripNSView, context: Context) { nsView.editor = editor; nsView.overview = overview }
}

final class FilmStripNSView: NSView {
    weak var editor: Editor?
    var overview = false
    private var link: CADisplayLink?
    private let settle = MainActor.assumeIsolated { GateSettle() }

    // geometry from the last draw, used for hit-testing
    private var cellH: CGFloat = 60
    private var gateY: CGFloat = 0

    // drag state
    private var lastY: CGFloat = 0
    private var lastMoveT: TimeInterval = 0
    private var moved: CGFloat = 0
    private var vel: Double = 0
    private var scrollSnap: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.masksToBounds = true
        if window != nil, link == nil {
            let l = displayLink(target: self, selector: #selector(onFrame(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else if window == nil {
            link?.invalidate(); link = nil
        }
    }

    @objc private func onFrame(_ l: CADisplayLink) {
        if !overview { MainActor.assumeIsolated { editor?.tick(now: l.timestamp) } }
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    // MARK: drawing

    /// Width of the picture film at 1× (reel column 400pt, source column 250pt); zoom multiplies these.
    static let reelFilm1x: CGFloat = 164
    static let sourceFilm1x: CGFloat = 170

    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let handFont = NSFont(name: "Marker Felt Wide", size: 14)
        ?? NSFont(name: "Bradley Hand", size: 14) ?? .systemFont(ofSize: 13, weight: .semibold)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MainActor.assumeIsolated { drawStrip(ctx) }
    }

    @MainActor
    private func drawStrip(_ ctx: CGContext) {
        let W = bounds.width, H = bounds.height
        ctx.setFillColor(.hex(0x0F110F)); ctx.fill(bounds)
        guard let ed = editor else { return }

        let segs = ed.segments
        let D = segs.reduce(0) { $0 + $1.length }
        ed.syncStripRate()
        let F = ed.stripRate
        let dir = CGFloat(ed.direction)
        // real 35mm proportions (see Film35): 3-perf frame spacing, optical soundtrack
        // In the reel, a sound reel (magnetic film with the music) runs right beside the picture.
        let soundReel = ed.mode == .reel
        let zoom = CGFloat(ed.stripZoom)
        let g = ed.film
        let filmW: CGFloat, fx: CGFloat
        if overview {
            // narrow: no ruler on the left, room on the right for the lines out to the zoomed strip
            filmW = soundReel ? (W - 8 - 4 - 18) / 2 : W - 8 - 18
            fx = 8
            soundX = soundReel ? fx + filmW + 4 : -1
        } else {
            // Zoomed, the picture film grows by the zoom; the window gives it room (see ContentView).
            // If it still doesn't fit, the sound reel beside it narrows first, then the zoom gives way:
            // the frame is never cut, so it always keeps the material's shape.
            if soundReel {
                let room = W - 36 - 14 - 22
                filmW = min(Self.reelFilm1x * zoom, max(room / 2, room - 56))
                soundW = min(Self.reelFilm1x, room - filmW)
                fx = 36
            } else {
                filmW = min(Self.sourceFilm1x * zoom, W - 80)
                fx = (36 + max(0, (W - 80 - filmW) / 2)).rounded()
            }
            soundX = soundReel ? fx + filmW + 14 : -1
        }
        let mm = filmW / g.width
        if overview || !soundReel { soundW = soundReel ? filmW : 0 }
        cellH = Film35.pitch * mm
        if !overview { ed.zoomedCellH = cellH }
        let picX = fx + g.picX * mm, picW = g.picW * mm, picH = g.picH * mm
        gateY = (H / 2).rounded()
        // Follow the hand while cranking or playing; at rest, park the frame squarely in the gate.
        let rawP = ed.time * F
        let atRest = ed.speed == 0 && !ed.dragging && ed.fling == 0 && CACurrentMediaTime() - ed.lastCrankAt > 0.25
        // Dragged or running, the film follows exactly. Otherwise (coming to rest, snapping to a frame,
        // stepping, between scroll-wheel ticks) it glides there instead of jumping.
        let driven = ed.dragging || ed.fling != 0 || ed.speed != 0
        // Playing, the strip moves intermittently like the gate (hold, then pull down a frame), so the
        // frames stand still long enough to be seen instead of streaming past.
        let target = atRest ? (rawP + 1e-6).rounded(.down) + 0.5
            : ed.speed != 0 && !ed.dragging ? Pulldown.position(rawP, forward: ed.speed > 0) : rawP
        let p = settle.position(target: target, moving: driven)
        let totalFrames = Int((D * F - 1e-6).rounded(.up))
        let yOf: (Double) -> CGFloat = { [cellH, gateY] t in gateY - dir * CGFloat(t * F - p) * cellH }
        let thumbs = ed.thumbs
        thumbs.beginFrame()
        // Big frames (zoomed in) come from the sharp store, sized to the pixels they cover;
        // the small frame stands in until the sharp one arrives.
        let needPx = picW * (window?.backingScaleFactor ?? 2)
        let hi: ThumbnailStore? = !overview && needPx > 300 ? ed.thumbsHi : nil
        if let hi {
            hi.maxPixel = [480, 640, 960, 1280, 1600].first { $0 >= needPx } ?? 1600
            hi.beginFrame()
        }

        // film base
        ctx.setFillColor(.hex(0x2B1A0D)); ctx.fill(CGRect(x: fx, y: 0, width: filmW, height: H))
        ctx.setFillColor(.hex(0xFFBE78, 0.05))
        ctx.fill(CGRect(x: fx + 2, y: 0, width: 1, height: H))
        ctx.fill(CGRect(x: fx + filmW - 3, y: 0, width: 1, height: H))

        let half = Int((H / 2 / cellH).rounded(.up)) + 1, pre = 24
        let kc = Int(p.rounded(.down))
        let ahead = ed.speed == 0 ? 0 : (ed.speed > 0 ? 1 : -1)
        var bestD = Double.infinity
        let ph = Film35.perfH * mm, pw = Film35.perfW * mm, pr = Film35.perfCorner * mm
        let rulerAttrs: [NSAttributedString.Key: Any] = [.font: Self.monoFont, .foregroundColor: NSColor(white: 0.5, alpha: 1)]

        for k in (kc - half - pre)...(kc + half + pre) {
            let yc = gateY - dir * (CGFloat(k) + 0.5 - CGFloat(p)) * cellH
            let y0 = yc - cellH / 2
            let visible = y0 < H && y0 + cellH > 0
            let inRange = D > 0 && k >= 0 && k < totalFrames

            if !visible {
                if overview { continue }
                // prefetch a little beyond the screen, in the direction of travel
                if inRange && (ahead == 0 || (k - kc).signum() == ahead),
                   let l = locate((Double(k) + 0.5) / F, in: segs) {
                    _ = thumbs.request(l.segment.mediaID, thumbs.index(for: l.src))
                    if let hi, abs(k - kc) <= half + 3 { _ = hi.request(l.segment.mediaID, hi.index(for: l.src)) }
                }
                continue
            }

            // perforations: 3 per frame each side (3-perf 35mm)
            ctx.setFillColor(.hex(0x0F110F))
            for j in 0..<(Film35.perforated ? Film35.perfsPerFrame : 0) {
                let py = y0 + (CGFloat(j) + 0.5) * Film35.perfPitch * mm - ph / 2
                ctx.addPath(CGPath(roundedRect: CGRect(x: fx + Film35.perfLeftX * mm, y: py, width: pw, height: ph),
                                   cornerWidth: pr, cornerHeight: pr, transform: nil))
                ctx.addPath(CGPath(roundedRect: CGRect(x: fx + Film35.perfRightX * mm, y: py, width: pw, height: ph),
                                   cornerWidth: pr, cornerHeight: pr, transform: nil))
            }
            ctx.fillPath()

            let frame = CGRect(x: picX, y: y0 + Film35.picTop * mm, width: picW, height: picH)
            if inRange, let l = locate((Double(k) + 0.5) / F, in: segs) {
                let idx = thumbs.index(for: l.src)
                let d = abs(Double(k) + 0.5 - p)
                if d < bestD { bestD = d; thumbs.setFocus(l.segment.mediaID, idx); hi?.setFocus(l.segment.mediaID, idx) }
                ctx.setFillColor(.hex(0x000000)); ctx.fill(frame)
                if let img = hi?.request(l.segment.mediaID, idx) ?? thumbs.request(l.segment.mediaID, idx) {
                    drawImage(ctx, img, fill: frame)
                } else {
                    ctx.setFillColor(.hex(0x1A120A)); ctx.fill(frame)
                }
            } else {
                // leader
                ctx.setFillColor(.hex(0x3D2B18)); ctx.fill(frame)
                ctx.setStrokeColor(.hex(0x000000, 0.25)); ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: frame.minX, y: frame.minY)); ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
                ctx.move(to: CGPoint(x: frame.maxX, y: frame.minY)); ctx.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
                ctx.strokePath()
            }

            // seconds ruler
            let perSecond = max(1, Int(F.rounded()))
            if !overview && inRange && k % perSecond == 0 {
                let yb = yOf(Double(k) / F)
                let s = k / perSecond
                let label = String(format: "%d:%02d", s / 60, s % 60) as NSString
                let sz = label.size(withAttributes: rulerAttrs)
                let rx = fx
                label.draw(at: CGPoint(x: rx - 8 - sz.width, y: yb - sz.height / 2), withAttributes: rulerAttrs)
                ctx.setFillColor(.hex(0x7D8676)); ctx.fill(CGRect(x: rx - 5, y: yb - 0.5, width: 4, height: 1))
            }
        }
        thumbs.endFrame()
        hi?.endFrame()

        // optical soundtrack: two bilateral variable-area tracks between the left perfs and the picture
        do {
            let tx = fx + Film35.trackX * mm, tw = Film35.trackW * mm
            ctx.setFillColor(.hex(0x0B0D0B)); ctx.fill(CGRect(x: tx, y: 0, width: tw, height: H))
            let laneGap = 0.12 * mm, laneW = (tw - laneGap) / 2
            let step: CGFloat = 2
            let span = Double(step / cellH) / F                  // seconds covered by one step
            let timeAt: (CGFloat) -> Double = { [cellH, gateY] y in (p - Double((y - gateY) / (dir * cellH))) / F }
            ctx.setFillColor(.hex(0xEDE6D3, 0.92))
            for lane in 0..<2 {
                let cx = tx + laneW / 2 + CGFloat(lane) * (laneW + laneGap)
                let path = soundtrackPath(centerX: cx, halfWidth: laneW / 2 * 0.95, y0: 0, y1: H, step: step) { y in
                    let t = timeAt(y)
                    return ed.soundLevel(lane: lane, from: t - span / 2, to: t + span / 2) ?? 0
                }
                ctx.addPath(path); ctx.fillPath()
            }
        }

        if D > 0 {   // head and tail of the material
            ctx.setFillColor(.hex(0xE3A548, 0.6))
            for t in [0, D] {
                let y = yOf(t)
                if y > -2 && y < H + 2 { ctx.fill(CGRect(x: fx, y: y - 1, width: filmW, height: 2)) }
            }
        }

        // splice tape where reel segments join
        if ed.mode == .reel {
            var acc = 0.0
            for s in ed.reel.dropLast() {
                acc += s.length
                let y = yOf(acc)
                if y < -cellH || y > H + cellH { continue }
                let th = min(cellH * 0.6, 40)
                let tape = CGRect(x: fx - 3, y: y - th / 2, width: filmW + 6, height: th)
                ctx.setFillColor(.hex(0xE6F0FF, 0.16)); ctx.fill(tape)
                ctx.setStrokeColor(.hex(0xE6F0FF, 0.35)); ctx.setLineWidth(1); ctx.stroke(tape.insetBy(dx: 0.5, dy: 0.5))
                ctx.setFillColor(.hex(0x9FE0FF)); ctx.fill(CGRect(x: fx, y: y - 0.75, width: filmW, height: 1.5))
            }
        }

        // grease-pencil marks on the source
        if ed.mode == .source, let m = ed.currentMedia, m.markIn != nil || m.markOut != nil {
            let grease = CGColor.hex(0xF6EEB4)
            ctx.setStrokeColor(grease); ctx.setLineCap(.round)
            // Marks sit on the frame lines of the strip: IN on the line before its frame (against the
            // previous material), OUT on the line after its frame (against what follows). The edit
            // points themselves stay frame-accurate; this is only where the pencil goes.
            let lineBefore: (Double) -> Double = { t in (t * F + 1e-6).rounded(.down) / F }
            let lineAfter: (Double) -> Double = { t in (t * F - 1e-6).rounded(.up) / F }
            let inLine = m.markIn.map(lineBefore), outLine = m.markOut.map(lineAfter)

            // With both marks the line spans IN–OUT. With only one, it is "being drawn": it runs from
            // that mark to the frame line past the gate frame and grows as you crank the film.
            let lineX = fx + filmW + 7
            let pending = m.markIn == nil || m.markOut == nil
            let ya: CGFloat, yb: CGFloat
            if let a = inLine, let b = outLine {
                ya = yOf(a); yb = yOf(b)
            } else {
                let anchor = inLine ?? outLine ?? 0
                let t = ed.time
                let k = (t * F + 1e-6).rounded(.down)
                let head = t >= anchor ? (k + 1) / F : k / F
                ya = yOf(anchor); yb = yOf(min(max(head, 0), m.duration))
            }
            ctx.setAlpha(pending ? 0.6 : 0.85); ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: lineX, y: ya)); ctx.addLine(to: CGPoint(x: lineX, y: yb)); ctx.strokePath()
            if pending && abs(yb - ya) > 1 {
                // the pencil tip
                ctx.setAlpha(0.95); ctx.setFillColor(grease)
                ctx.fillEllipse(in: CGRect(x: lineX - 3, y: yb - 3, width: 6, height: 6))
            }
            ctx.setAlpha(1)
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.handFont, .foregroundColor: NSColor(cgColor: grease)!]
            func mark(_ t: Double, _ label: String, _ off: CGFloat) {
                let y = yOf(t); guard y > -20 && y < H + 20 else { return }
                ctx.setLineWidth(2.5)
                var x: CGFloat = 0
                while x <= filmW + 10 {
                    let yy = y + sin(x * 0.45 + CGFloat(t) * 7) * 1.2
                    x == 0 ? ctx.move(to: CGPoint(x: fx - 5 + x, y: yy)) : ctx.addLine(to: CGPoint(x: fx - 5 + x, y: yy))
                    x += 6
                }
                ctx.strokePath()
                let s = label as NSString, sz = s.size(withAttributes: attrs)
                s.draw(at: CGPoint(x: fx + filmW + 11, y: y + off * dir - sz.height / 2), withAttributes: attrs)
            }
            if let a = inLine { mark(a, overview ? "" : "IN", 12) }
            if let b = outLine { mark(b, overview ? "" : "OUT", -12) }
        }

        if soundReel { drawSoundReel(ctx, ed: ed, x: soundX, w: soundW, mm: soundW / 35, H: H, p: p, dir: dir, F: F, yOf: yOf) }

        // the gate: lit aperture with corner brackets
        let cx = fx + filmW / 2
        if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [CGColor.hex(0xFFE1A0, 0.12), CGColor.hex(0xFFE1A0, 0)] as CFArray,
                                 locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: fx - 20, y: gateY - cellH, width: filmW + 40, height: cellH * 2))
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: gateY), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: gateY), endRadius: filmW * 0.9, options: [])
            ctx.restoreGState()
        }
        let c: CGFloat = overview ? 5 : 10
        let g0 = CGPoint(x: picX - 4, y: gateY - picH / 2 - 4)
        let g1 = CGPoint(x: picX + picW + 4, y: gateY + picH / 2 + 4)
        ctx.setStrokeColor(.hex(0xE3A548)); ctx.setLineWidth(2); ctx.setLineCap(.butt)
        ctx.addLines(between: [CGPoint(x: g0.x, y: g0.y + c), g0, CGPoint(x: g0.x + c, y: g0.y)])
        ctx.addLines(between: [CGPoint(x: g1.x - c, y: g0.y), CGPoint(x: g1.x, y: g0.y), CGPoint(x: g1.x, y: g0.y + c)])
        ctx.addLines(between: [CGPoint(x: g0.x, y: g1.y - c), CGPoint(x: g0.x, y: g1.y), CGPoint(x: g0.x + c, y: g1.y)])
        ctx.addLines(between: [CGPoint(x: g1.x - c, y: g1.y), g1, CGPoint(x: g1.x, y: g1.y - c)])
        ctx.strokePath()
        ctx.setFillColor(.hex(0xE3A548))
        ctx.addLines(between: [CGPoint(x: 4, y: gateY - 6), CGPoint(x: 12, y: gateY), CGPoint(x: 4, y: gateY + 6)])
        ctx.fillPath()

        // fade into darkness at top and bottom
        if let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [CGColor.hex(0x0F110F, 0.92), CGColor.hex(0x0F110F, 0)] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H * 0.12), options: [])
            ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.88), options: [])
        }
        if overview {
            drawZoomWindow(ctx, ed: ed, x0: fx - 3, x1: (soundReel ? soundX + soundW : fx + filmW) + 3, W: W, H: H)
        } else {
            let arrow = (dir > 0 ? "▼" : "▲") as NSString
            arrow.draw(at: CGPoint(x: W - 18, y: 6), withAttributes: rulerAttrs)
        }
    }

    /// On the overview: outline the stretch the zoomed strip shows, dim the rest, and run lines from
    /// the outline out to the zoomed strip's top and bottom, like a magnifier callout.
    @MainActor
    private func drawZoomWindow(_ ctx: CGContext, ed: Editor, x0: CGFloat, x1: CGFloat, W: CGFloat, H: CGFloat) {
        guard ed.zoomedCellH > 0 else { return }
        let half = H / 2 * cellH / ed.zoomedCellH
        let box = CGRect(x: x0, y: gateY - half, width: x1 - x0, height: half * 2)
        ctx.setFillColor(.hex(0x0F110F, 0.5))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: max(0, box.minY)))
        ctx.fill(CGRect(x: 0, y: box.maxY, width: W, height: max(0, H - box.maxY)))
        let accent = CGColor.hex(0xE3A548)
        ctx.setStrokeColor(accent); ctx.setLineWidth(2)
        ctx.stroke(box.insetBy(dx: 1, dy: 1))
        ctx.saveGState()
        ctx.setStrokeColor(.hex(0xE3A548, 0.7)); ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.move(to: CGPoint(x: box.maxX, y: box.minY + 1)); ctx.addLine(to: CGPoint(x: W, y: 0))
        ctx.move(to: CGPoint(x: box.maxX, y: box.maxY - 1)); ctx.addLine(to: CGPoint(x: W, y: H))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Fill a rect of this flipped view with a CGImage, cropping what overflows (no black bars).
    private func drawImage(_ ctx: CGContext, _ img: CGImage, fill r: CGRect) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = max(r.width / iw, r.height / ih)
        let dw = iw * s, dh = ih * s
        let dst = CGRect(x: r.midX - dw / 2, y: r.midY - dh / 2, width: dw, height: dh)
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: dst.minX, y: dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(origin: .zero, size: dst.size))
        ctx.restoreGState()
    }

    // MARK: sound reel

    private var soundX: CGFloat = -1
    private var soundW: CGFloat = 0
    private var musicDrag: UUID?
    private var musicUndoPushed = false

    /// Magnetic sound tape beside the picture (oxide coat, no perforations), the music as a waveform,
    /// grease-pencil lines at each clip's head and tail. The selected clip is outlined.
    @MainActor
    private func drawSoundReel(_ ctx: CGContext, ed: Editor, x sx: CGFloat, w: CGFloat, mm: CGFloat, H: CGFloat,
                               p: Double, dir: CGFloat, F: Double, yOf: (Double) -> CGFloat) {
        // magnetic tape: no perforations, just the oxide coat with a faint sheen along the edges
        ctx.setFillColor(.hex(0x4A2B15)); ctx.fill(CGRect(x: sx, y: 0, width: w, height: H))
        ctx.setFillColor(.hex(0x5A3418)); ctx.fill(CGRect(x: sx + 1.5 * mm, y: 0, width: w - 3 * mm, height: H))
        ctx.setFillColor(.hex(0xFFD9A8, 0.06))
        ctx.fill(CGRect(x: sx + 1, y: 0, width: 1, height: H))
        ctx.fill(CGRect(x: sx + w - 2, y: 0, width: 1, height: H))

        let cx = sx + w / 2, halfW = 13 * mm
        let step: CGFloat = 2, span = Double(step / cellH) / F
        let timeAt: (CGFloat) -> Double = { [cellH, gateY] y in (p - Double((y - gateY) / (dir * cellH))) / F }
        let grease = CGColor.hex(0xF6EEB4)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                                         .foregroundColor: NSColor(cgColor: grease)!]
        for c in ed.music {
            var ya = yOf(c.at), yb = yOf(c.endAt)
            if ya > yb { swap(&ya, &yb) }
            guard yb > 0, ya < H else { continue }
            let y0 = max(0, ya), y1 = min(H, yb)
            let env = ed.envelopes[c.sourceID]
            // like an audio editor: a peak per pixel row, negative to the left and positive to the right,
            // so the waveform comes out spiky rather than as a smooth outline
            let rowSpan = Double(1 / cellH) / F
            let path = waveformPath(centerX: cx, halfWidth: halfW, y0: y0, y1: y1, step: 1) { y in
                let t = timeAt(y)
                guard let env else { return (0.03, 0.03) }
                let a = c.start + (t - rowSpan / 2 - c.at), b = c.start + (t + rowSpan / 2 - c.at)
                let g = Float(min(1.2, c.volume(atReel: t)))
                return (env.level(1, from: a, to: b) * g, env.level(0, from: a, to: b) * g)
            }
            ctx.setFillColor(.hex(0xEDE6D3, 0.88)); ctx.addPath(path); ctx.fillPath()

            if c.id == ed.selectedMusicID {
                ctx.setStrokeColor(.hex(0xE3A548)); ctx.setLineWidth(2)
                ctx.stroke(CGRect(x: sx + 2 * mm, y: y0, width: w - 4 * mm, height: y1 - y0))
            }
            // head and tail in grease pencil, name at the head
            ctx.setStrokeColor(grease); ctx.setLineWidth(2); ctx.setLineCap(.round)
            for y in [yOf(c.at), yOf(c.endAt)] where y > -4 && y < H + 4 {
                var x: CGFloat = 0
                while x <= w + 6 {
                    let yy = y + sin(x * 0.5 + CGFloat(c.at) * 5) * 1.2
                    x == 0 ? ctx.move(to: CGPoint(x: sx - 3 + x, y: yy)) : ctx.addLine(to: CGPoint(x: sx - 3 + x, y: yy))
                    x += 5
                }
                ctx.strokePath()
            }
            let headY = yOf(c.at)
            if !overview, headY > -20 && headY < H + 20, let name = ed.source(c.sourceID)?.name {
                let s = ("♪ " + (name as NSString).deletingPathExtension) as NSString
                let sz = s.size(withAttributes: labelAttrs)
                let y = headY - dir * 9 - sz.height / 2
                ctx.saveGState()
                ctx.clip(to: CGRect(x: sx + 2.5 * mm, y: 0, width: w - 5 * mm, height: H))
                s.draw(at: CGPoint(x: sx + 3 * mm, y: y), withAttributes: labelAttrs)
                ctx.restoreGState()
            }
        }
        // the gate line runs across the sound film too
        ctx.setFillColor(.hex(0xE3A548, 0.8))
        ctx.fill(CGRect(x: sx - 2, y: gateY - cellH / 2 - 1, width: 6, height: 2))
        ctx.fill(CGRect(x: sx + w - 4, y: gateY - cellH / 2 - 1, width: 6, height: 2))
        ctx.fill(CGRect(x: sx - 2, y: gateY + cellH / 2 - 1, width: 6, height: 2))
        ctx.fill(CGRect(x: sx + w - 4, y: gateY + cellH / 2 - 1, width: 6, height: 2))
    }

    // MARK: hand-cranking

    private var F: Double { MainActor.assumeIsolated { editor?.stripRate ?? 12 } }
    private var dirD: Double { Double(MainActor.assumeIsolated { editor?.direction ?? 1 }) }

    override func mouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        // On the sound reel, grabbing a music clip slides it against the picture.
        if soundX >= 0, pt.x >= soundX, pt.x <= soundX + soundW {
            let fps = F, dir = dirD, ch = Double(cellH), gy = Double(gateY)
            let hit: UUID? = MainActor.assumeIsolated {
                guard let ed = editor else { return nil }
                let t = (ed.time * fps - dir * (Double(pt.y) - gy) / ch) / fps
                let c = ed.musicClip(atReel: t)
                ed.selectedMusicID = c?.id
                return c?.id
            }
            if let hit {
                musicDrag = hit; musicUndoPushed = false
                NSCursor.closedHand.push()
                lastY = pt.y; moved = 0
                return
            }
        }
        // grabbing the picture (or empty tape) puts the music selection down, so Delete acts on the picture again
        MainActor.assumeIsolated { editor?.selectedMusicID = nil; editor?.beginDrag() }
        NSCursor.closedHand.push()
        lastY = convert(e.locationInWindow, from: nil).y
        moved = 0; vel = 0; lastMoveT = e.timestamp
    }

    override func mouseDragged(with e: NSEvent) {
        let y = convert(e.locationInWindow, from: nil).y
        let dy = y - lastY
        lastY = y
        moved += abs(dy)
        if let id = musicDrag {
            let d = dirD * Double(dy / cellH) / F
            let first = !musicUndoPushed && moved >= 3
            if first { musicUndoPushed = true }
            MainActor.assumeIsolated {
                if first { editor?.beginMusicMove() }
                if musicUndoPushed { editor?.slideMusic(id, by: d) }
            }
            return
        }
        let d = dirD * Double(dy / cellH) / F
        MainActor.assumeIsolated { editor?.scrub(by: d) }
        let dt = max(e.timestamp - lastMoveT, 0.001)
        lastMoveT = e.timestamp
        vel = vel * 0.6 + (d / dt) * 0.4
    }

    override func mouseUp(with e: NSEvent) {
        NSCursor.pop()
        if let id = musicDrag {
            musicDrag = nil
            if musicUndoPushed { MainActor.assumeIsolated { editor?.commitMusicMove(id) } }
            return
        }
        let y = convert(e.locationInWindow, from: nil).y
        let fps = F, dir = dirD, ch = Double(cellH), gy = Double(gateY)
        let flick = e.timestamp - lastMoveT < 0.08 ? vel : nil
        let clicked = moved < 4
        MainActor.assumeIsolated {
            guard let ed = editor else { return }
            if clicked {
                ed.endDrag(fling: nil)
                let k = (ed.time * fps - dir * (Double(y) - gy) / ch).rounded(.down)
                ed.jump(to: (k + 0.5) / fps)
            } else {
                ed.endDrag(fling: flick)
            }
        }
    }

    /// Pinch to zoom the strip; it settles on the nearest step when the fingers lift.
    override func magnify(with e: NSEvent) {
        MainActor.assumeIsolated {
            guard let ed = editor else { return }
            ed.setZoom(ed.stripZoom * (1 + Double(e.magnification)), animated: false)
            if e.phase == .ended || e.phase == .cancelled { ed.settleZoom() }
        }
    }

    override func scrollWheel(with e: NSEvent) {
        let dy = e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 12)
        let d = dirD * Double(dy / cellH) / F
        MainActor.assumeIsolated {
            editor?.fling = 0
            editor?.scrub(by: d)
        }
        scrollSnap?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.editor?.snap() } }
        scrollSnap = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }
}
