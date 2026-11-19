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
        playerLayer.videoGravity = .resizeAspect
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

/// The Moviola's viewing hood. The picture is the gate on one continuous piece of 35mm film:
/// perforations (4 per frame) run down both sides and the neighbouring frames peek out above and below.
struct ViewerView: View {
    let editor: Editor

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x232A23), Theme.bg], center: .center, startRadius: 0, endRadius: 600)
            if editor.media.isEmpty {
                EmptyStateView(editor: editor)
            } else {
                GeometryReader { geo in
                    let L = FilmLayout(available: CGSize(width: geo.size.width - 28, height: geo.size.height - 28),
                                       aspect: editor.aspect)
                    ZStack {
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
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        // scroll anywhere on the film to crank it
                        ScrubOverlay(editor: editor)
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

/// Proportions of a 35mm frame around the picture.
struct FilmLayout {
    static let railRatio: CGFloat = 0.12    // perforation margin each side, relative to picture width
    static let peekRatio: CGFloat = 0.30    // how much of the next/previous frame shows, relative to picture height
    static let gapRatio: CGFloat = 0.05     // frame line between frames

    let pic: CGSize
    let rail: CGFloat
    let gap: CGFloat
    let film: CGSize
    var frameH: CGFloat { pic.height + gap }

    init(available: CGSize, aspect: Double) {
        let a = CGFloat(max(aspect, 0.1))
        let wByWidth = available.width / (1 + 2 * Self.railRatio)
        let wByHeight = available.height / (1 + 2 * (Self.peekRatio + Self.gapRatio)) * a
        let w = max(120, min(wByWidth, wByHeight))
        pic = CGSize(width: w.rounded(), height: (w / a).rounded())
        rail = (w * Self.railRatio).rounded()
        gap = max(4, (pic.height * Self.gapRatio).rounded())
        film = CGSize(width: pic.width + rail * 2,
                      height: (pic.height + 2 * (pic.height * Self.peekRatio + gap)).rounded())
    }
}

/// Everything on the film outside the gate: perforations, frame lines, neighbouring frames, edge numbers.
/// Stopped, the current frame sits squarely in the gate; while running it advances a frame at a time with a quick
/// pull-down, the way a projector's claw does, so motion stays readable at any speed.
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
        let L = layout
        let F = Double(editor.stripFPS)
        let dir = CGFloat(editor.direction)
        let d = CGFloat(position())
        let midY = size.height / 2
        let segs = editor.segments
        let D = segs.reduce(0) { $0 + $1.length }
        let total = Int((D * F - 1e-6).rounded(.up))
        let picX = L.rail

        // film base
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.film))
        gc.fill(Path(CGRect(x: 3, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.05)))
        gc.fill(Path(CGRect(x: size.width - 4, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.05)))

        let fh = L.frameH
        let reach = Int((midY / fh).rounded(.up)) + 1
        let c0 = Int(d.rounded(.down))
        // 35mm (KS) perforations are wider than tall: about 2.8 × 2.0 mm on a 4.75 mm pitch.
        var perfH = fh / 4 * 0.42, perfW = perfH * 1.41
        if perfW > L.rail * 0.6 { perfW = L.rail * 0.6; perfH = perfW / 1.41 }
        let edge = Font.system(size: max(8, L.rail * 0.13), weight: .semibold, design: .monospaced)

        for c in (c0 - reach)...(c0 + reach) {
            let yc = midY - dir * (CGFloat(c) + 0.5 - d) * fh
            let top = yc - fh / 2
            guard top < size.height, top + fh > 0 else { continue }

            // 4 perforations per frame on each side
            for j in 0..<4 {
                let py = top + (CGFloat(j) + 0.5) * fh / 4 - perfH / 2
                for x in [(L.rail - perfW) / 2, size.width - L.rail + (L.rail - perfW) / 2] {
                    gc.fill(Path(roundedRect: CGRect(x: x, y: py, width: perfW, height: perfH), cornerRadius: perfH * 0.28),
                            with: .color(Color(hex: 0x0F110F)))
                }
            }

            // the picture area of this frame (the gate frame itself is covered by the live picture)
            let r = CGRect(x: picX, y: yc - L.pic.height / 2, width: L.pic.width, height: L.pic.height)
            if c >= 0 && c < total, let l = locate((Double(c) + 0.5) / F, in: segs) {
                gc.fill(Path(r), with: .color(.black))
                let idx = editor.thumbs.index(for: l.src)
                if let img = editor.thumbs.peek(l.segment.mediaID, idx) ?? editor.thumbs.keepImage(l.segment.mediaID, idx) {
                    gc.draw(Image(decorative: img, scale: 1).resizable(), in: r)
                }
                // edge number for this frame, printed between the perforations and the film edge
                let label = Text(TC.feet(Double(c) / F)).font(edge).foregroundStyle(Theme.accent.opacity(0.7))
                var g = gc
                g.translateBy(x: L.rail * 0.13, y: yc)
                g.rotate(by: .degrees(-90))
                g.draw(label, at: .zero)
            } else {
                gc.fill(Path(r), with: .color(Color(hex: 0x3D2B18)))   // leader
            }
        }

        // the neighbouring frames sink into the dark of the hood
        let fade = (size.height - L.pic.height) / 2
        for (from, to) in [(CGFloat(0), fade), (size.height, size.height - fade)] {
            gc.fill(Path(CGRect(x: 0, y: min(from, to), width: size.width, height: abs(to - from))),
                    with: .linearGradient(Gradient(stops: [.init(color: Color(hex: 0x1D231C).opacity(0.92), location: 0),
                                                           .init(color: Color(hex: 0x1D231C).opacity(0.35), location: 0.75),
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
            Text("動画ファイルをここにドロップ").font(.system(size: 15, weight: .semibold))
            Text("左のフィルムを上下にドラッグして手回し、スペースで再生").foregroundStyle(Theme.muted)
            Button("素材を開く…") { editor.openPanel() }
                .buttonStyle(FilmButtonStyle(primary: true))
        }
    }
}
