import SwiftUI

struct FilmButtonStyle: ButtonStyle {
    var primary = false
    var on = false
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let filled = primary || on
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: compact ? 11 : 13, weight: filled ? .semibold : .regular))
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 1 : 6)
            .foregroundStyle(filled ? Theme.accentInk : Theme.text)
            .background(RoundedRectangle(cornerRadius: 6).fill(filled ? Theme.accent : Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(filled ? Theme.accent : Theme.line, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .contentShape(Rectangle())
    }
}

struct Kbd: View {
    let s: String
    init(_ s: String) { self.s = s }
    var body: some View {
        Text(s).font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line))
            .opacity(0.7)
    }
}

struct HeaderBar: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (Text("MAKE").foregroundStyle(Theme.text) + Text("FILM").foregroundStyle(Theme.accent))
                    .font(.system(size: 13, weight: .heavy)).tracking(3.5)
                if let v = AppVersion.short {
                    Text("v\(v)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                        .help(AppVersion.full)
                }
            }
            .padding(.trailing, 8)
            HStack(spacing: 0) {
                Button { editor.setMode(.source) } label: { HStack(spacing: 4) { Text(L("素材")); Kbd("1") } }
                    .buttonStyle(FilmButtonStyle(on: editor.mode == .source))
                Button { editor.setMode(.reel) } label: { HStack(spacing: 4) { Text(L("リール")); Kbd("2") } }
                    .buttonStyle(FilmButtonStyle(on: editor.mode == .reel))
            }
            Button(L("＋ 素材を開く")) { editor.openPanel() }.buttonStyle(FilmButtonStyle())
            Spacer()
            Text(L("流れ")).foregroundStyle(Theme.muted)
            HStack(spacing: 0) {
                Button(L("↑ 上へ")) { editor.direction = -1 }
                    .buttonStyle(FilmButtonStyle(on: editor.direction == -1))
                    .help(L("フィルムが下から上へ流れる（標準）"))
                Button(L("↓ 下へ")) { editor.direction = 1 }
                    .buttonStyle(FilmButtonStyle(on: editor.direction == 1))
                    .help(L("フィルムが上から下へ流れる（ムービオラ式）"))
            }
            Text(L("コマ密度")).foregroundStyle(Theme.muted)
            Picker("", selection: $editor.stripFPS) {
                Text(L("素材と同じ")).tag(0); Text(L("6 /秒")).tag(6); Text(L("12 /秒")).tag(12); Text(L("24 /秒")).tag(24)
            }
            .labelsHidden().frame(width: 110)
            .help(L("縦フィルムの 1 秒あたりのコマ数。「素材と同じ」なら 1 コマ＝動画の 1 フレーム"))
            Text(L("拡大")).foregroundStyle(Theme.muted)
            Picker("", selection: Binding(get: { Editor.zoomSteps.min { abs($0 - editor.stripZoom) < abs($1 - editor.stripZoom) } ?? 1 },
                                          set: { editor.setZoom($0) })) {
                ForEach(Editor.zoomSteps, id: \.self) { z in
                    Text(verbatim: z == 1 ? L("等倍") : String(format: "%g×", z)).tag(z)
                }
            }
            .labelsHidden().frame(width: 76)
            .help(L("フィルムの一部を拡大する。左に全体のリールが出て、拡大している範囲を枠で示す（Z で切り替え、＋／−、ピンチ）"))
            Button(L("書き出し…")) { editor.openExport() }
                .buttonStyle(FilmButtonStyle(primary: true))
                .disabled(!editor.canExport)
                .help(L("リール・素材の範囲・今のコマを、形式とサイズを選んで書き出す (⌘E)"))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.panel)
    }
}

struct TransportBar: View {
    let editor: Editor

    var body: some View {
        HStack(spacing: 16) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                let t = editor.time
                VStack(alignment: .leading, spacing: 0) {
                    Text(TC.string(t, fps: editor.engine.fps))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    HStack(spacing: 4) {
                        Text("35mm")
                        Text(TC.feet(t)).foregroundStyle(Theme.accent).fontWeight(.semibold)
                        Text("ft")
                    }
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                }
                .frame(width: 170, alignment: .leading)
            }

            HStack(spacing: 6) {
                Button("◀︎|") { editor.step(-1) }.help(L("1フレーム戻す (←)"))
                Button(editor.speed == 0 ? "▶︎" : "❚❚") { editor.togglePlay() }.frame(minWidth: 50).help(L("再生/停止 (Space)"))
                Button("|▶︎") { editor.step(1) }.help(L("1フレーム送る (→)"))
            }
            .buttonStyle(FilmButtonStyle())

            HStack(spacing: 4) {
                Text(L("ペダル")).font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.trailing, 2)
                ForEach(Editor.pedal, id: \.self) { s in
                    Button(label(s)) { editor.setSpeed(s) }
                        .buttonStyle(FilmButtonStyle(on: editor.speed == s))
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            if editor.mode == .source {
                HStack(spacing: 6) {
                    Button { editor.markIn() } label: { HStack(spacing: 4) { Text("IN"); Kbd("I") } }
                    Button { editor.markOut() } label: { HStack(spacing: 4) { Text("OUT"); Kbd("O") } }
                    Button { editor.splice() } label: { HStack(spacing: 4) { Text(L("スプライス")); Kbd("⏎") } }
                        .buttonStyle(FilmButtonStyle(primary: true))
                    if let m = editor.currentMedia {
                        Text("IN \(m.markIn.map { TC.string($0, fps: m.fps) } ?? "--")  OUT \(m.markOut.map { TC.string($0, fps: m.fps) } ?? "--")")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.grease)
                    }
                }
                .buttonStyle(FilmButtonStyle())
            } else {
                HStack(spacing: 6) {
                    Button { editor.cutAtGate() } label: { HStack(spacing: 4) { Text(L("切る")); Kbd("C") } }
                        .help(L("ゲート位置でフィルムを切る"))
                    if !editor.music.isEmpty {
                        Button { editor.splitMusicAtGate() } label: { HStack(spacing: 4) { Text(L("曲を切る")); Kbd("⇧C") } }
                            .help(L("ゲートの位置で曲を 2 つに分ける"))
                    }
                    Button { editor.liftAtGate() } label: { HStack(spacing: 4) { Text(L("外す")); Kbd("X") } }
                        .help(L("ゲート位置のカットをリールから外す"))
                    Button { editor.undo() } label: { HStack(spacing: 4) { Text(L("取り消し")); Kbd("⌘Z") } }
                        .disabled(editor.undoStack.isEmpty)
                }
                .buttonStyle(FilmButtonStyle())
            }
            Spacer()
            Text(L("J/K/L 速度 · ↑↓ フィルム送り · ドラッグ/スクロールで手回し"))
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.panel)
    }

    private func label(_ s: Double) -> String {
        if s == 0 { return "■" }
        let mag = abs(s) == 0.5 ? "½" : String(Int(abs(s)))
        return (s < 0 ? "◀" : "▶") + mag
    }
}
