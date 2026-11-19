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

/// The Moviola's small viewing screen inside its hood.
struct ViewerView: View {
    let editor: Editor

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x232A23), Theme.bg], center: .center, startRadius: 0, endRadius: 600)
            if editor.media.isEmpty {
                EmptyStateView(editor: editor)
            } else {
                ZStack {
                    PlayerLayerView(player: editor.engine.player)
                    // ground-glass vignette
                    RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center,
                                   startRadius: 120, endRadius: 520)
                        .allowsHitTesting(false)
                    // scroll over the picture to crank the film
                    ScrubOverlay(editor: editor)
                }
                .aspectRatio(editor.aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.vertical, 14)
                .padding(.horizontal, FilmRailsView.railZone)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 22)
                            .fill(LinearGradient(colors: [Color(hex: 0x2F372E), Color(hex: 0x1D231C)],
                                                 startPoint: .top, endPoint: .bottom))
                            .shadow(color: .black.opacity(0.55), radius: 25, y: 14)
                        // film running past the picture on both sides
                        FilmRailsView(editor: editor)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .allowsHitTesting(false)
                    }
                )
                .padding(36)
            }
        }
    }
}

/// Perforated film edges running past both sides of the picture, locked to the playhead.
/// They move with playback, scrubbing and the strip, in the chosen flow direction, so even a
/// still shot reads as "film is running". Edge numbers (feet+frames) ride along like latent edge print.
struct FilmRailsView: View {
    let editor: Editor

    /// Horizontal space reserved on each side of the picture.
    static let railZone: CGFloat = 64
    private let pitch: CGFloat = 18          // perforation spacing
    private let perfsPerCell: CGFloat = 2    // rail travel per strip frame

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { gc, size in draw(gc, size) }
        }
    }

    private func draw(_ gc: GraphicsContext, _ size: CGSize) {
        let t = editor.time
        let speed = editor.speed
        let sgn: CGFloat = editor.direction > 0 ? 1 : -1      // + = film moves down
        let travel = CGFloat(t * Double(editor.stripFPS)) * perfsPerCell * pitch
        let midY = size.height / 2
        let running = speed != 0
        // Faster film smears the holes a little.
        let blur = running ? min(max(abs(CGFloat(speed)) - 1, 0), 3) * 4 : 0
        let holeH: CGFloat = 10 + blur
        let railW: CGFloat = 36
        let filmColor = Theme.film
        let holeColor = Color(hex: 0x0F110F)
        let edgeColor = Theme.accent.opacity(running ? 0.75 : 0.45)

        for side in [0, 1] {
            let railX = side == 0 ? CGFloat(16) : size.width - 16 - railW
            gc.fill(Path(CGRect(x: railX, y: 0, width: railW, height: size.height)), with: .color(filmColor))
            // faint emulsion edge lines
            gc.fill(Path(CGRect(x: railX + 2, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.05)))
            gc.fill(Path(CGRect(x: railX + railW - 3, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.05)))

            let kMin = Int(floor((travel - midY - pitch * 2) / pitch))
            let kMax = Int(ceil((travel + midY + pitch * 2) / pitch))
            for k in kMin...kMax {
                let y = midY + sgn * (travel - CGFloat(k) * pitch)
                let r = CGRect(x: railX + (railW - 14) / 2, y: y - holeH / 2, width: 14, height: holeH)
                gc.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(holeColor.opacity(blur > 0 ? 0.8 : 1)))

                // edge print every 16 strip frames, on the outer side of each rail
                let cellsPerLabel = 16
                let perfsPerLabel = cellsPerLabel * Int(perfsPerCell)
                if k % perfsPerLabel == 0 && k >= 0 {
                    let seconds = Double(k) / Double(perfsPerCell) / Double(editor.stripFPS)
                    let label = Text(TC.feet(seconds))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(edgeColor)
                    var g = gc
                    let x = side == 0 ? railX - 8 : railX + railW + 8
                    g.translateBy(x: x, y: y)
                    g.rotate(by: .degrees(side == 0 ? -90 : 90))
                    g.draw(label, at: .zero)
                }
            }
        }

        // the lamp behind the gate breathes a little while film runs
        if running {
            let a = 0.05 + Double.random(in: 0...0.04)
            gc.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(Gradient(colors: [Theme.accent.opacity(a), .clear]),
                                          center: CGPoint(x: size.width / 2, y: midY),
                                          startRadius: 0, endRadius: max(size.width, size.height) * 0.6))
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
