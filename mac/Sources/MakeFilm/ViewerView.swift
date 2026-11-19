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
