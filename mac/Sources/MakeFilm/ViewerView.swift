import SwiftUI
import AVFoundation
import AppKit

/// AVPlayerLayer host.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.playerLayer.player = player
        return v
    }
    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill     // the picture fills the frame, like the strip
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// The Moviola's viewing hood. The picture is the gate on one continuous piece of 35mm print film,
/// drawn to real proportions: perforations at both edges (3 per frame), the optical soundtrack beside
/// the picture, and the neighbouring frames peeking out above and below.
struct ViewerView: View {
    let editor: Editor

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x232A23), Theme.bg], center: .center, startRadius: 0, endRadius: 600)
            if editor.media.isEmpty {
                EmptyStateView(editor: editor)
            } else {
                GeometryReader { geo in
                    let L = FilmLayout(available: CGSize(width: geo.size.width - 28, height: geo.size.height - 28))
                    ZStack(alignment: .topLeading) {
                        FilmSurroundView(editor: editor, layout: L)
                            .allowsHitTesting(false)
                        ZStack {
                            PlayerLayerView(player: editor.engine.player)
                            // ground-glass vignette
                            RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center,
                                           startRadius: L.pic.width * 0.25, endRadius: L.pic.width * 0.7)
                            GateFlicker(editor: editor)
                        }
                        .allowsHitTesting(false)
                        .frame(width: L.pic.width, height: L.pic.height)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .offset(x: L.pic.minX, y: L.pic.minY)
                        // scroll anywhere on the film to crank it
                        ScrubOverlay(editor: editor)
                            .frame(width: L.film.width, height: L.film.height)
                    }
                    .frame(width: L.film.width, height: L.film.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(LinearGradient(colors: [Color(hex: 0x2F372E), Color(hex: 0x1D231C)],
                                                 startPoint: .top, endPoint: .bottom))
                            .shadow(color: .black.opacity(0.55), radius: 25, y: 14)
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .padding(28)
            }
        }
    }
}

/// Size of the film piece shown in the hood: the gate frame plus a little of the frames around it.
struct FilmLayout {
    static let peek: CGFloat = 0.22          // fraction of a frame pitch showing above and below

    let mm: CGFloat                          // pixels per millimetre of film
    let film: CGSize
    let pic: CGRect                          // the gate's picture area, in film coordinates
    var frameH: CGFloat { Film35.pitch * mm }

    init(available: CGSize) {
        let heightMM = Film35.pitch * (1 + 2 * Self.peek)
        mm = max(3, min(available.width / Film35.width, available.height / heightMM))
        film = CGSize(width: (Film35.width * mm).rounded(), height: (heightMM * mm).rounded())
        pic = CGRect(x: (Film35.picX * mm).rounded(), y: ((film.height - Film35.picH * mm) / 2).rounded(),
                     width: (Film35.picW * mm).rounded(), height: (Film35.picH * mm).rounded())
    }
}

/// Everything on the film outside the gate: perforations, frame lines, neighbouring frames, edge numbers
/// and the optical soundtrack. Stopped, the current frame sits squarely in the gate; while running it
/// advances a frame at a time with a quick pull-down, the way a projector's claw does.
struct FilmSurroundView: View {
    let editor: Editor
    let layout: FilmLayout

    var body: some View {
        TimelineView(.animation) { tl in
            // Using the tick's date makes every frame a new drawing, so moving film and
            // newly generated neighbour frames show up immediately.
            let tick = tl.date
            Canvas { gc, size in draw(gc, size, tick) }
        }
        .frame(width: layout.film.width, height: layout.film.height)
    }

    /// Film position in strip frames (cells); cell c is centred in the gate at c + 0.5.
    private func position() -> Double {
        let p = editor.time * Double(editor.stripFPS)
        // Stopped or hand-cranked: the frame under the playhead sits squarely in the gate.
        guard editor.speed != 0 else { return (p + 1e-6).rounded(.down) + 0.5 }
        let forward = editor.speed > 0
        let c = forward ? p.rounded(.down) : p.rounded(.up) - 1
        let frac = forward ? p - c : (c + 1) - p             // 0…1 through the current cell, in travel direction
        let hold = 0.55
        let k = frac < hold ? 0 : { let x = (frac - hold) / (1 - hold); return x * x * (3 - 2 * x) }()
        return forward ? c + 0.5 + k : c + 0.5 - k
    }

    private func draw(_ gc: GraphicsContext, _ size: CGSize, _ tick: Date) {
        let L = layout, mm = L.mm
        let F = Double(editor.stripFPS)
        let dir = CGFloat(editor.direction)
        let d = CGFloat(position())
        let midY = size.height / 2
        let segs = editor.segments
        let D = segs.reduce(0) { $0 + $1.length }
        let total = Int((D * F - 1e-6).rounded(.up))
        let fh = L.frameH

        // film base
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.film))

        let reach = Int((midY / fh).rounded(.up)) + 1
        let c0 = Int(d.rounded(.down))
        let perfW = Film35.perfW * mm, perfH = Film35.perfH * mm, perfR = Film35.perfCorner * mm
        let edge = Font.system(size: max(8, 1.15 * mm), weight: .semibold, design: .monospaced)

        for c in (c0 - reach)...(c0 + reach) {
            let yc = midY - dir * (CGFloat(c) + 0.5 - d) * fh
            let top = yc - fh / 2
            guard top < size.height, top + fh > 0 else { continue }

            // 3 perforations per frame on each edge (KS, wider than tall)
            for j in 0..<(Film35.perforated ? Film35.perfsPerFrame : 0) {
                let py = top + (CGFloat(j) + 0.5) * Film35.perfPitch * mm - perfH / 2
                for x in [Film35.perfLeftX * mm, Film35.perfRightX * mm] {
                    gc.fill(Path(roundedRect: CGRect(x: x, y: py, width: perfW, height: perfH), cornerRadius: perfR),
                            with: .color(Color(hex: 0x0F110F)))
                }
            }

            // the picture area of this frame (the gate frame itself is covered by the live picture)
            let r = CGRect(x: L.pic.minX, y: top + Film35.picTop * mm, width: L.pic.width, height: L.pic.height)
            if c >= 0 && c < total, let l = locate((Double(c) + 0.5) / F, in: segs) {
                gc.fill(Path(r), with: .color(.black))
                let idx = editor.thumbs.index(for: l.src)
                if let img = editor.thumbs.peek(l.segment.mediaID, idx) ?? editor.thumbs.keepImage(l.segment.mediaID, idx) {
                    let s = max(r.width / CGFloat(img.width), r.height / CGFloat(img.height))
                    let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
                    var g = gc
                    g.clip(to: Path(r))
                    g.draw(Image(decorative: img, scale: 1).resizable(),
                           in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
                }
                // edge print: the timecode of this frame, outside the perforations
                let label = Text(TC.string(Double(c) / F, fps: editor.engine.fps)).font(edge).foregroundStyle(Theme.accent.opacity(0.7))
                var g = gc
                g.translateBy(x: Film35.edgePrintX * mm, y: yc)
                g.rotate(by: .degrees(-90))
                g.draw(label, at: .zero)
            } else {
                gc.fill(Path(r), with: .color(Color(hex: 0x3D2B18)))   // leader
            }
        }

        // optical soundtrack: two bilateral variable-area tracks beside the picture
        let tx = Film35.trackX * mm, tw = Film35.trackW * mm
        gc.fill(Path(CGRect(x: tx, y: 0, width: tw, height: size.height)), with: .color(Color(hex: 0x0B0D0B)))
        let laneGap = 0.12 * mm, laneW = (tw - laneGap) / 2
        let step: CGFloat = 2
        let span = Double(step / fh) / F
        for lane in 0..<2 {
            let cx = tx + laneW / 2 + CGFloat(lane) * (laneW + laneGap)
            let path = soundtrackPath(centerX: cx, halfWidth: laneW / 2 * 0.95, y0: 0, y1: size.height, step: step) { y in
                let u = Double(d) - Double((y - midY) / (dir * fh))     // film position in cells at this y
                let t = u / F
                return editor.soundLevel(lane: lane, from: t - span / 2, to: t + span / 2) ?? 0
            }
            gc.fill(Path(path), with: .color(Color(hex: 0xEDE6D3).opacity(0.92)))
        }

        // the neighbouring frames sink into the dark of the hood
        let fade = (size.height - L.pic.height) / 2
        for (from, to) in [(CGFloat(0), fade), (size.height, size.height - fade)] {
            gc.fill(Path(CGRect(x: 0, y: min(from, to), width: size.width, height: abs(to - from))),
                    with: .linearGradient(Gradient(stops: [.init(color: Color(hex: 0x1D231C).opacity(0.85), location: 0),
                                                           .init(color: Color(hex: 0x1D231C).opacity(0.3), location: 0.7),
                                                           .init(color: .clear, location: 1)]),
                                          startPoint: CGPoint(x: 0, y: from), endPoint: CGPoint(x: 0, y: to)))
        }
    }
}

/// The lamp behind the gate breathes a little while film runs.
struct GateFlicker: View {
    let editor: Editor
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { _ in
            Color.black.opacity(editor.speed != 0 ? Double.random(in: 0...0.06) : 0)
        }
    }
}

/// Transparent layer over the viewer that turns scrolling into frame-accurate scrubbing.
/// Vertical scroll moves the film the same way as on the strip; a sideways swipe works like a timeline.
struct ScrubOverlay: NSViewRepresentable {
    let editor: Editor
    func makeNSView(context: Context) -> ScrubNSView {
        let v = ScrubNSView(); v.editor = editor; return v
    }
    func updateNSView(_ nsView: ScrubNSView, context: Context) { nsView.editor = editor }
}

final class ScrubNSView: NSView {
    weak var editor: Editor?
    private var pending: CGFloat = 0
    private var snapWork: DispatchWorkItem?
    /// Trackpad points of travel per video frame.
    private let pointsPerFrame: CGFloat = 6

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func scrollWheel(with e: NSEvent) {
        let dir = CGFloat(MainActor.assumeIsolated { editor?.direction ?? 1 })
        // Dominant axis: vertical follows the film direction, horizontal reads like a timeline.
        let delta = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX)
            ? dir * e.scrollingDeltaY
            : -e.scrollingDeltaX

        if !e.hasPreciseScrollingDeltas {
            // Mouse wheel: one notch = one frame.
            let n = delta > 0 ? 1 : (delta < 0 ? -1 : 0)
            if n != 0 { MainActor.assumeIsolated { editor?.step(n) } }
            return
        }

        pending += delta
        let frames = (pending / pointsPerFrame).rounded(.towardZero)
        if frames != 0 {
            pending -= frames * pointsPerFrame
            MainActor.assumeIsolated {
                guard let ed = editor else { return }
                ed.fling = 0
                ed.scrub(by: Double(frames) / ed.engine.fps)
            }
        }
        snapWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.pending = 0
            MainActor.assumeIsolated { self?.editor?.snap() }
        }
        snapWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }
}

struct EmptyStateView: View {
    let editor: Editor
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(Theme.muted)
            Text(L("動画ファイルをここにドロップ")).font(.system(size: 15, weight: .semibold))
            Text(L("左のフィルムを上下にドラッグして手回し、スペースで再生")).foregroundStyle(Theme.muted)
            Button(L("素材を開く…")) { editor.openPanel() }
                .buttonStyle(FilmButtonStyle(primary: true))
        }
    }
}
