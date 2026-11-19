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
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(LinearGradient(colors: [Color(hex: 0x2F372E), Color(hex: 0x1D231C)],
                                             startPoint: .top, endPoint: .bottom))
                        .shadow(color: .black.opacity(0.55), radius: 25, y: 14)
                )
                .padding(36)
            }
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
