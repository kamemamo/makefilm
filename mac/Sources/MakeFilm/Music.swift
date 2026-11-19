import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// An audio file loaded for the sound reel (music, effects…).
struct AudioSource: Identifiable {
    var id = UUID()
    let url: URL
    let name: String
    let asset: AVURLAsset
    let duration: Double
    let track: AVAssetTrack

    static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]

    static func load(url: URL, id: UUID = UUID()) async throws -> AudioSource {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw LoadError(message: L("音声トラックがありません"))
        }
        return AudioSource(id: id, url: url, name: url.lastPathComponent, asset: asset, duration: duration, track: track)
    }
}

/// A piece of an audio file laid on the sound reel, in sync with the picture reel.
struct MusicClip: Identifiable, Codable, Hashable {
    var id = UUID()
    var sourceID: UUID
    var start: Double            // in the audio file
    var end: Double
    var at: Double               // where it starts on the reel
    var gain: Double = 1         // 0…1.5 (linear)
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var length: Double { end - start }
    var endAt: Double { at + length }

    /// Volume (with fades) at a reel time inside the clip.
    func volume(atReel t: Double) -> Double {
        let local = t - at
        var v = gain
        if fadeIn > 0 { v *= min(1, max(0, local / fadeIn)) }
        if fadeOut > 0 { v *= min(1, max(0, (length - local) / fadeOut)) }
        return v
    }
}

/// What undo / redo restore.
struct EditState: Equatable {
    var reel: [Segment]
    var music: [MusicClip]
}

extension Editor {

    var selectedMusic: MusicClip? { music.first { $0.id == selectedMusicID } }
    func source(_ id: UUID) -> AudioSource? { musicSources.first { $0.id == id } }

    // MARK: importing

    func openMusicPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = L("サウンドリールに置く音楽を選んでください（ゲートの位置に置かれます）")
        if panel.runModal() == .OK { importMusic(panel.urls) }
    }

    /// Load audio files and lay them on the sound reel, starting at the gate (one after another).
    func importMusic(_ urls: [URL]) {
        Task {
            // At the gate in the reel; from the Source view, where the reel was last left.
            let wasReel = mode == .reel
            var at = wasReel ? time : reelTime
            var added: [MusicClip] = []
            for url in urls {
                do {
                    let s = try await AudioSource.load(url: url)
                    musicSources.append(s)
                    loadEnvelope(source: s)
                    let clip = MusicClip(sourceID: s.id, start: 0, end: s.duration, at: at)
                    added.append(clip)
                    at += s.duration
                } catch {
                    toast(L("読み込めませんでした: %@", url.lastPathComponent))
                }
            }
            guard !added.isEmpty else { return }
            pushUndo()
            music.append(contentsOf: added)
            music.sort { $0.at < $1.at }
            selectedMusicID = added.last?.id
            if wasReel {
                musicChanged()
            } else {
                // music can start a reel on its own: cut the picture to it afterwards
                rememberPosition()
                mode = .reel
                reloadPlayer(at: added.first?.at ?? 0)
            }
            toast(L("サウンドリールに置きました: %@", added.compactMap { source($0.sourceID)?.name }.joined(separator: ", ")))
        }
    }

    func loadEnvelope(source s: AudioSource) {
        guard envelopes[s.id] == nil else { return }
        let asset = s.asset, track = s.track, id = s.id
        Task.detached(priority: .utility) {
            let env = await AudioEnvelope.make(asset: asset, track: track)
            await MainActor.run { if let env { self.envelopes[id] = env } }
        }
    }

    // MARK: editing a music clip

    private func updateMusic(_ id: UUID, undoable: Bool = true, _ change: (inout MusicClip) -> Void) {
        guard let i = music.firstIndex(where: { $0.id == id }) else { return }
        if undoable { pushUndo() }
        change(&music[i])
        music.sort { $0.at < $1.at }
        musicChanged()
    }

    /// Slide a clip along the reel (live while dragging; call `commitMusicMove` on release).
    func slideMusic(_ id: UUID, by delta: Double) {
        guard let i = music.firstIndex(where: { $0.id == id }) else { return }
        music[i].at = max(0, music[i].at + delta)
    }

    func beginMusicMove() { pushUndo() }

    func commitMusicMove(_ id: UUID) {
        guard let i = music.firstIndex(where: { $0.id == id }) else { return }
        let f = engine.fps
        music[i].at = max(0, (music[i].at * f).rounded() / f)      // land on a frame
        music.sort { $0.at < $1.at }
        musicChanged()
    }

    func musicAtGateToStart(_ id: UUID) {
        let t = time
        updateMusic(id) { $0.at = t }
        toast(L("曲の頭をゲートに合わせました"))
    }

    /// Cut the beginning away so the clip starts at the gate.
    func trimMusicHead(_ id: UUID) {
        guard let c = music.first(where: { $0.id == id }) else { return }
        let t = time
        guard t > c.at + 0.05, t < c.endAt - 0.05 else { toast(L("ゲートが曲の範囲の中にありません")); return }
        updateMusic(id) { $0.start += t - $0.at; $0.at = t }
        toast(L("ゲートの位置で曲の頭を切りました"))
    }

    /// Cut the end away so the clip stops at the gate.
    func trimMusicTail(_ id: UUID) {
        guard let c = music.first(where: { $0.id == id }) else { return }
        let t = time
        guard t > c.at + 0.05, t < c.endAt - 0.05 else { toast(L("ゲートが曲の範囲の中にありません")); return }
        updateMusic(id) { $0.end = $0.start + (t - $0.at) }
        toast(L("ゲートの位置で曲の終わりを切りました"))
    }

    func setMusicGain(_ id: UUID, _ g: Double) { updateMusic(id) { $0.gain = g } }
    func setMusicFade(_ id: UUID, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        updateMusic(id) { c in
            if let f = fadeIn { c.fadeIn = min(f, c.length / 2) }
            if let f = fadeOut { c.fadeOut = min(f, c.length / 2) }
        }
    }

    func removeMusic(_ id: UUID) {
        guard music.contains(where: { $0.id == id }) else { return }
        pushUndo()
        music.removeAll { $0.id == id }
        if selectedMusicID == id { selectedMusicID = nil }
        musicChanged()
        toast(L("サウンドリールから外しました"))
    }

    /// Music clip under a reel time (the last one placed wins where they overlap).
    func musicClip(atReel t: Double) -> MusicClip? {
        music.last { t >= $0.at && t < $0.endAt }
    }

    /// Level of the sound reel at a span of reel time, for drawing (nil where nothing is laid).
    func musicLevel(from t0: Double, to t1: Double) -> Float? {
        let mid = (t0 + t1) / 2
        var best: Float?
        for c in music where mid >= c.at && mid < c.endAt {
            guard let env = envelopes[c.sourceID] else { best = max(best ?? 0, 0); continue }
            let a = c.start + (t0 - c.at), b = c.start + (t1 - c.at)
            let v = max(env.level(0, from: a, to: b), env.level(1, from: a, to: b)) * Float(min(1.2, c.volume(atReel: mid)))
            best = max(best ?? 0, v)
        }
        return best
    }

    /// Rebuild playback so the change is heard.
    func musicChanged() {
        guard mode == .reel else { return }
        if reel.isEmpty && music.isEmpty {
            mode = .source
            reloadPlayer(at: currentMedia?.lastTime ?? 0)
        } else {
            reloadPlayer(at: time)
        }
    }
}

// MARK: - panel

/// "Sound reel" section of the right-hand panel: the music laid on the reel and the selected clip's settings.
struct MusicPanel: View {
    let editor: Editor
    @State private var gainDraft: Double?

    private static let fades: [Double] = [0, 0.5, 1, 2, 3, 5]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(L("サウンドリール"), trailing: editor.music.isEmpty ? "" : L("%ld 曲", editor.music.count))
            Button(L("＋ 音楽を読み込む…")) { editor.openMusicPanel() }
                .buttonStyle(FilmButtonStyle(compact: true))
                .padding(.horizontal, 14).padding(.bottom, 6)
            if editor.reel.isEmpty && editor.music.isEmpty {
                hint(L("音楽を先に置いて、それに合わせて絵を継ぐこともできます。"))
            } else if editor.music.isEmpty {
                hint(L("音楽ファイルをドロップするか読み込むと、ゲートの位置に置かれます。サウンドリールの上でドラッグすると絵に対して前後にずらせます。"))
            }
            ForEach(editor.music) { c in row(c) }
            if let c = editor.selectedMusic { inspector(c) }
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.bottom, 6)
    }

    private func row(_ c: MusicClip) -> some View {
        let on = c.id == editor.selectedMusicID
        return HStack(spacing: 8) {
            Image(systemName: "music.note").foregroundStyle(on ? Theme.accent : Theme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(editor.source(c.sourceID)?.name ?? "—").lineLimit(1).truncationMode(.middle)
                Text("\(TC.string(c.at, fps: editor.engine.fps)) · \(String(format: "%.1fs", c.length))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.panel2 : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Theme.accent : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            editor.selectedMusicID = c.id
            if editor.mode != .reel { editor.setMode(.reel) }
            editor.jump(to: min(c.at, max(0, editor.reelDuration - 0.01)))
        }
        .padding(.horizontal, 8)
    }

    private func inspector(_ c: MusicClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("音量")).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                Slider(value: Binding(get: { gainDraft ?? c.gain }, set: { gainDraft = $0 }), in: 0...1.5) { editing in
                    if !editing, let g = gainDraft { editor.setMusicGain(c.id, g); gainDraft = nil }
                }
                Text("\(Int(((gainDraft ?? c.gain) * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text(L("フェード")).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                fadeMenu(L("イン"), c.fadeIn) { editor.setMusicFade(c.id, fadeIn: $0) }
                fadeMenu(L("アウト"), c.fadeOut) { editor.setMusicFade(c.id, fadeOut: $0) }
            }
            HStack(spacing: 6) {
                Button(L("頭をゲートへ")) { editor.musicAtGateToStart(c.id) }
                    .help(L("曲の頭がゲートの位置から始まるように動かす"))
                Button(L("ゲートで頭を切る")) { editor.trimMusicHead(c.id) }
                    .help(L("ゲートより前の部分を切り落とす"))
            }
            HStack(spacing: 6) {
                Button(L("ゲートで終わりを切る")) { editor.trimMusicTail(c.id) }
                    .help(L("ゲートより後の部分を切り落とす"))
                Button(L("外す")) { editor.removeMusic(c.id) }
            }
        }
        .buttonStyle(FilmButtonStyle(compact: true))
        .font(.system(size: 12))
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2.opacity(0.6)))
        .padding(.horizontal, 8).padding(.top, 6)
    }

    private func fadeMenu(_ title: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        Menu {
            ForEach(Self.fades, id: \.self) { f in
                Button(f == 0 ? L("なし") : String(format: "%.1f s", f)) { set(f) }
            }
        } label: {
            Text("\(title) \(value == 0 ? L("なし") : String(format: "%.1fs", value))")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
