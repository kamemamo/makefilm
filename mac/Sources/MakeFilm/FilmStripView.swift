import SwiftUI
import AppKit

/// The vertical 35mm strip. Frames run through a fixed gate in the middle,
/// like film threaded through a Moviola. Drag it like hand-cranking.
struct FilmStripView: NSViewRepresentable {
    let editor: Editor
    func makeNSView(context: Context) -> FilmStripNSView {
        let v = FilmStripNSView()
        v.editor = editor
        return v
    }
    func updateNSView(_ nsView: FilmStripNSView, context: Context) { nsView.editor = editor }
}

final class FilmStripNSView: NSView {
    weak var editor: Editor?
    private var link: CADisplayLink?

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
        MainActor.assumeIsolated {
            editor?.tick(now: l.timestamp)
        }
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    // MARK: drawing

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
        let F = Double(ed.stripFPS)
        let dir = CGFloat(ed.direction)
        let asp = CGFloat(ed.aspect)
        let filmW = min(W - 80, 180)
        let fx = (36 + max(0, (W - 80 - filmW) / 2)).rounded()
        let perfM = filmW * 0.15, imgW = filmW - perfM * 2, imgH = imgW / asp
        let gap = max(5, imgH * 0.07)
        cellH = imgH + gap
        gateY = (H / 2).rounded()
        let p = ed.time * F
        let totalFrames = Int((D * F - 1e-6).rounded(.up))
        let yOf: (Double) -> CGFloat = { [cellH, gateY] t in gateY - dir * CGFloat(t * F - p) * cellH }
        let thumbs = ed.thumbs
        thumbs.beginFrame()

        // film base
        ctx.setFillColor(.hex(0x2B1A0D)); ctx.fill(CGRect(x: fx, y: 0, width: filmW, height: H))
        ctx.setFillColor(.hex(0xFFBE78, 0.05))
        ctx.fill(CGRect(x: fx + 2, y: 0, width: 1, height: H))
        ctx.fill(CGRect(x: fx + filmW - 3, y: 0, width: 1, height: H))

        let half = Int((H / 2 / cellH).rounded(.up)) + 1, pre = 24
        let kc = Int(p.rounded(.down))
        let ahead = ed.speed == 0 ? 0 : (ed.speed > 0 ? 1 : -1)
        var bestD = Double.infinity
        let ph = cellH / 4 * 0.52, pw = perfM * 0.46
        let rulerAttrs: [NSAttributedString.Key: Any] = [.font: Self.monoFont, .foregroundColor: NSColor(white: 0.5, alpha: 1)]

        for k in (kc - half - pre)...(kc + half + pre) {
            let yc = gateY - dir * (CGFloat(k) + 0.5 - CGFloat(p)) * cellH
            let y0 = yc - cellH / 2
            let visible = y0 < H && y0 + cellH > 0
            let inRange = D > 0 && k >= 0 && k < totalFrames

            if !visible {
                // prefetch a little beyond the screen, in the direction of travel
                if inRange && (ahead == 0 || (k - kc).signum() == ahead),
                   let l = locate((Double(k) + 0.5) / F, in: segs) {
                    _ = thumbs.request(l.segment.mediaID, thumbs.index(for: l.src))
                }
                continue
            }

            // perforations: 4 per frame each side (35mm)
            ctx.setFillColor(.hex(0x0F110F))
            for j in 0..<4 {
                let py = y0 + (CGFloat(j) + 0.5) * cellH / 4 - ph / 2
                ctx.addPath(CGPath(roundedRect: CGRect(x: fx + perfM * 0.27, y: py, width: pw, height: ph),
                                   cornerWidth: 2, cornerHeight: 2, transform: nil))
                ctx.addPath(CGPath(roundedRect: CGRect(x: fx + filmW - perfM * 0.27 - pw, y: py, width: pw, height: ph),
                                   cornerWidth: 2, cornerHeight: 2, transform: nil))
            }
            ctx.fillPath()

            let frame = CGRect(x: fx + perfM, y: y0 + gap / 2, width: imgW, height: imgH)
            if inRange, let l = locate((Double(k) + 0.5) / F, in: segs) {
                let idx = thumbs.index(for: l.src)
                let d = abs(Double(k) + 0.5 - p)
                if d < bestD { bestD = d; thumbs.setFocus(l.segment.mediaID, idx) }
                ctx.setFillColor(.hex(0x000000)); ctx.fill(frame)
                if let img = thumbs.request(l.segment.mediaID, idx) {
                    drawImage(ctx, img, contain: frame)
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
            if inRange && k % Int(F) == 0 {
                let yb = yOf(Double(k) / F)
                let s = k / Int(F)
                let label = String(format: "%d:%02d", s / 60, s % 60) as NSString
                let sz = label.size(withAttributes: rulerAttrs)
                label.draw(at: CGPoint(x: fx - 8 - sz.width, y: yb - sz.height / 2), withAttributes: rulerAttrs)
                ctx.setFillColor(.hex(0x7D8676)); ctx.fill(CGRect(x: fx - 5, y: yb - 0.5, width: 4, height: 1))
            }
        }
        thumbs.endFrame()

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
            let ya = yOf(m.markIn ?? 0), yb = yOf(m.markOut ?? m.duration)
            ctx.setAlpha(0.85); ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: fx + filmW + 7, y: ya)); ctx.addLine(to: CGPoint(x: fx + filmW + 7, y: yb)); ctx.strokePath()
            ctx.setAlpha(1)
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.handFont, .foregroundColor: NSColor(cgColor: grease)!]
            func mark(_ t: Double, _ label: String, _ off: CGFloat) {
                let y = yOf(t); guard y > -20 && y < H + 20 else { return }
                ctx.setLineWidth(2.5)
                var x: CGFloat = 0
                while x <= filmW + 10 {
                    let yy = y + sin(x * 0.45 + CGFloat(t) * 7) * 1.6
                    x == 0 ? ctx.move(to: CGPoint(x: fx - 5 + x, y: yy)) : ctx.addLine(to: CGPoint(x: fx - 5 + x, y: yy))
                    x += 6
                }
                ctx.strokePath()
                let s = label as NSString, sz = s.size(withAttributes: attrs)
                s.draw(at: CGPoint(x: fx + filmW + 11, y: y + off * dir - sz.height / 2), withAttributes: attrs)
            }
            if let a = m.markIn { mark(a, "IN", 12) }
            if let b = m.markOut { mark(b, "OUT", -12) }
        }

        // the gate: lit aperture with corner brackets
        let cx = fx + filmW / 2
        if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [CGColor.hex(0xFFE1A0, 0.12), CGColor.hex(0xFFE1A0, 0)] as CFArray,
                                 locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: fx - 20, y: gateY - cellH, width: filmW + 40, height: cellH * 2))
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: gateY), startRadius: 4,
                                   endCenter: CGPoint(x: cx, y: gateY), endRadius: filmW * 0.9, options: [])
            ctx.restoreGState()
        }
        let c: CGFloat = 10
        let g0 = CGPoint(x: fx + perfM - 4, y: gateY - imgH / 2 - 4)
        let g1 = CGPoint(x: fx + perfM + imgW + 4, y: gateY + imgH / 2 + 4)
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
        let arrow = (dir > 0 ? "▼" : "▲") as NSString
        arrow.draw(at: CGPoint(x: W - 18, y: 6), withAttributes: rulerAttrs)
    }

    /// Aspect-fit a CGImage into a rect of this flipped view.
    private func drawImage(_ ctx: CGContext, _ img: CGImage, contain r: CGRect) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = min(r.width / iw, r.height / ih)
        let dw = iw * s, dh = ih * s
        let dst = CGRect(x: r.midX - dw / 2, y: r.midY - dh / 2, width: dw, height: dh)
        ctx.saveGState()
        ctx.translateBy(x: dst.minX, y: dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(origin: .zero, size: dst.size))
        ctx.restoreGState()
    }

    // MARK: hand-cranking

    private var F: Double { Double(MainActor.assumeIsolated { editor?.stripFPS ?? 12 }) }
    private var dirD: Double { Double(MainActor.assumeIsolated { editor?.direction ?? 1 }) }

    override func mouseDown(with e: NSEvent) {
        MainActor.assumeIsolated { editor?.beginDrag() }
        NSCursor.closedHand.push()
        lastY = convert(e.locationInWindow, from: nil).y
        moved = 0; vel = 0; lastMoveT = e.timestamp
    }

    override func mouseDragged(with e: NSEvent) {
        let y = convert(e.locationInWindow, from: nil).y
        let dy = y - lastY
        lastY = y
        moved += abs(dy)
        let d = dirD * Double(dy / cellH) / F
        MainActor.assumeIsolated { editor?.scrub(by: d) }
        let dt = max(e.timestamp - lastMoveT, 0.001)
        lastMoveT = e.timestamp
        vel = vel * 0.6 + (d / dt) * 0.4
    }

    override func mouseUp(with e: NSEvent) {
        NSCursor.pop()
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
