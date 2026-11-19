import SwiftUI
import AVFoundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class Editor {
    // MARK: observed state
    var media: [MediaClip] = []
    var reel: [Segment] = []
    var mode: EditMode = .source
    var currentMediaID: UUID?
    var speed: Double = 0
    /// -1 = film flows upward (default), 1 = downward (Moviola).
    var direction: Int = -1
    var stripFPS: Int = 12 {
        didSet {
            thumbs.fps = stripFPS
            for m in media { thumbs.updateMaxIndex(m) }
            thumbVersion += 1
        }
    }
    var activeSegmentIndex = -1
    var thumbVersion = 0
    var toastMessage: String?
    var exportProgress: Double?
    var showExportSheet = false
    var exportOptions = ExportOptions.load()
    var undoStack: [[Segment]] = []
    var redoStack: [[Segment]] = []
    /// Cuts copied with ⌘C (kept for the session).
    var cutClipboard: [Segment] = []

    // MARK: project (see Project.swift)
    var projectURL: URL?
    /// What was last saved/opened; the project is "edited" when the current state differs.
    var savedCore = ProjectCore()
    var recentProjects: [URL] = Editor.loadRecents()
    @ObservationIgnored var launchHandled = false

    // MARK: per-frame state (not observed)
    @ObservationIgnored let engine = PlaybackEngine()
    @ObservationIgnored let thumbs = ThumbnailStore()
    @ObservationIgnored var dragging = false
    @ObservationIgnored var fling: Double = 0
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var manualSpeed: Double = 0
    @ObservationIgnored var reelTime: Double = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored var exportSession: AVAssetExportSession?

    static let pedal: [Double] = [-4, -2, -1, 0, 0.5, 1, 2, 4]

    init() {
        thumbs.onKeepFulfilled = { [weak self] in self?.thumbVersion += 1 }
    }

    // MARK: derived

    var currentMedia: MediaClip? { media.first { $0.id == currentMediaID } }
    var currentIndex: Int? { media.firstIndex { $0.id == currentMediaID } }
    func clip(_ id: UUID) -> MediaClip? { media.first { $0.id == id } }
    var clipMap: [UUID: MediaClip] { Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) }) }

    var segments: [Segment] {
        switch mode {
        case .source:
            guard let m = currentMedia else { return [] }
            return [Segment(id: m.id, mediaID: m.id, start: 0, end: m.duration)]
        case .reel:
            return reel
        }
    }

    var reelDuration: Double { reel.reduce(0) { $0 + $1.length } }

    /// Aspect used for the strip cells and the viewer.
    var aspect: Double {
        if mode == .reel, let f = reel.first, let m = clip(f.mediaID) { return m.aspect }
        return currentMedia?.aspect ?? 16 / 9
    }

    var time: Double { engine.time }

    // MARK: loading

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = L("編集する動画を選んでください")
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    func importURLs(_ urls: [URL]) {
        launchHandled = true
        let have = Set(media.map { $0.url.standardizedFileURL.path })
        for url in urls where !have.contains(url.standardizedFileURL.path) {
            Task {
                do {
                    let m = try await MediaClip.load(url: url)
                    media.append(m)
                    thumbs.register(m)
                    select(m.id)
                } catch {
                    toast(L("読み込めませんでした: %@", url.lastPathComponent))
                }
            }
        }
    }

    func select(_ id: UUID) {
        rememberPosition()
        currentMediaID = id
        mode = .source
        reloadPlayer(at: currentMedia?.lastTime ?? 0)
    }

    func rememberPosition() {
        if mode == .source, let i = currentIndex { media[i].lastTime = time }
        if mode == .reel { reelTime = time }
    }

    func reloadPlayer(at t: Double) {
        manualSpeed = 0
        speed = 0
        fling = 0
        switch mode {
        case .source:
            guard let m = currentMedia else {
                engine.setItem(nil, duration: 0, fps: 24, at: 0); return
            }
            engine.setItem(AVPlayerItem(asset: m.asset), duration: m.duration, fps: m.fps, at: t)
        case .reel:
            guard let c = ReelComposition.build(reel, clips: clipMap) else {
                engine.setItem(nil, duration: 0, fps: 24, at: 0); return
            }
            let item = AVPlayerItem(asset: c.composition)
            item.videoComposition = c.videoComposition
            engine.setItem(item, duration: c.duration, fps: c.fps, at: t)
        }
        snap()
        activeSegmentIndex = -1
    }

    func setMode(_ m: EditMode) {
        guard m != mode else { return }
        if m == .reel && reel.isEmpty { toast(L("リールはまだ空です")); return }
        if m == .source && currentMedia == nil { return }
        rememberPosition()
        mode = m
        reloadPlayer(at: m == .source ? (currentMedia?.lastTime ?? 0) : reelTime)
    }

    // MARK: transport

    func setSpeed(_ s: Double) {
        guard engine.duration > 0 else { return }
        if s == 0 { stop(); return }
        fling = 0
        if s > 0 && time >= engine.duration - 0.05 { engine.scrub(to: 0) }
        if s < 0 && time <= 0.01 { engine.scrub(to: engine.duration) }
        if engine.canPlay(rate: s) {
            manualSpeed = 0
            engine.play(rate: Float(s))
        } else {
            engine.pause()
            manualSpeed = s
        }
        speed = s
    }

    func togglePlay() { speed == 0 ? setSpeed(1) : stop() }

    func stop() {
        manualSpeed = 0
        engine.pause()
        if speed != 0 { speed = 0 }
        snap()
    }

    /// Park the playhead in the middle of a real video frame.
    func snap() {
        guard engine.duration > 0 else { return }
        let f = engine.fps
        engine.scrub(to: ((time * f + 1e-6).rounded(.down) + 0.5) / f)
    }

    func step(_ frames: Int) {
        stop()
        let f = engine.fps
        let k = (time * f + 1e-6).rounded(.down) + Double(frames)
        engine.scrub(to: (k + 0.5) / f)
    }

    func jump(to t: Double) {
        if speed != 0 { stop() }
        fling = 0
        engine.scrub(to: t)
        snap()
    }

    func home() { jump(to: 0) }
    func end() { jump(to: engine.duration) }

    // strip hand-cranking
    func beginDrag() {
        if speed != 0 { stop() }
        fling = 0
        dragging = true
    }

    func scrub(by delta: Double) {
        if speed != 0 { stop() }
        engine.scrub(to: time + delta)
    }

    func endDrag(fling v: Double?) {
        dragging = false
        if let v { fling = v } else { snap() }
    }

    /// Called every display refresh by the strip view.
    func tick(now: CFTimeInterval) {
        let dt = lastTick == 0 ? 0 : min(now - lastTick, 0.1)
        lastTick = now
        guard engine.duration > 0 else { return }

        if manualSpeed != 0 {
            let t = time + dt * manualSpeed
            engine.scrub(to: t)
            if t <= 0 || t >= engine.duration { stop() }
        } else if speed != 0 {
            if !engine.isRunning {         // reached the end (or start, in reverse)
                engine.adoptPlayerTime()
                speed = 0
                snap()
            }
        } else if fling != 0 && !dragging {
            engine.scrub(to: time + fling * dt)
            fling *= pow(0.9, dt * 60)
            if abs(fling) < 0.02 || time <= 0 || time >= engine.duration - 0.001 { fling = 0; snap() }
        }

        let idx = mode == .reel ? (locate(time, in: reel)?.index ?? -1) : -1
        if idx != activeSegmentIndex { activeSegmentIndex = idx }
    }

    // MARK: editing

    func markIn() {
        guard mode == .source, let i = currentIndex else { return }
        let f = media[i].fps
        let a = (time * f + 1e-6).rounded(.down) / f
        media[i].markIn = a
        if let o = media[i].markOut, o <= a { media[i].markOut = nil }
    }

    func markOut() {
        guard mode == .source, let i = currentIndex else { return }
        let f = media[i].fps
        let b = min(((time * f + 1e-6).rounded(.down) + 1) / f, media[i].duration)
        media[i].markOut = b
        if let a = media[i].markIn, a >= b { media[i].markIn = nil }
    }

    func splice() {
        guard mode == .source, let i = currentIndex else { return }
        let m = media[i]
        let a = m.markIn ?? 0, b = m.markOut ?? m.duration
        guard b - a >= 1 / m.fps * 0.99 else { toast(L("IN と OUT の間が短すぎます")); return }
        pushUndo()
        reel.append(Segment(mediaID: m.id, start: a, end: b))
        media[i].markIn = nil
        media[i].markOut = nil
        toast(L("リールに継ぎました（#%ld・%.1f秒）", reel.count, b - a))
    }

    func cutAtGate() {
        guard mode == .reel else { return }
        stop()
        guard let l = locate(time, in: reel), let m = clip(l.segment.mediaID) else { return }
        let fd = 1 / m.fps
        let at = (l.src * m.fps + 1e-6).rounded(.down) / m.fps   // cut just before the frame in the gate
        guard at - l.segment.start >= fd * 0.99, l.segment.end - at >= fd * 0.99 else {
            toast(L("カットの端に近すぎます")); return
        }
        pushUndo()
        var a = l.segment; a.id = UUID(); a.end = at
        var b = l.segment; b.id = UUID(); b.start = at
        reel.replaceSubrange(l.index...l.index, with: [a, b])
        reelChanged(keepingTime: time)
        toast(L("ゲート位置で切りました"))
    }

    func liftAtGate() {
        guard mode == .reel else { return }
        stop()
        guard let l = locate(time, in: reel) else { return }
        remove(at: l.index)
    }

    func remove(at index: Int) {
        guard reel.indices.contains(index) else { return }
        let start = reel.prefix(index).reduce(0) { $0 + $1.length }
        pushUndo()
        reel.remove(at: index)
        reelChanged(keepingTime: start)
        toast(L("#%ld を外しました", index + 1))
    }

    /// Move a segment so it sits before `targetID` (or at the end when nil).
    func move(_ id: UUID, before targetID: UUID?) {
        guard let from = reel.firstIndex(where: { $0.id == id }), id != targetID else { return }
        pushUndo()
        let s = reel.remove(at: from)
        if let targetID, let to = reel.firstIndex(where: { $0.id == targetID }) {
            reel.insert(s, at: to)
        } else {
            reel.append(s)
        }
        reelChanged(keepingTime: time)
    }

    /// Trim-bin drop: moves the cut, or copies it when ⌥ is held (as in Finder).
    func dropCut(_ id: UUID, before targetID: UUID?) {
        if NSEvent.modifierFlags.contains(.option) { duplicate(id, before: targetID) } else { move(id, before: targetID) }
    }

    /// Insert a copy of a segment before `targetID` (or at the end) — ⌥-drag in the trim bin.
    func duplicate(_ id: UUID, before targetID: UUID?) {
        guard let from = reel.firstIndex(where: { $0.id == id }) else { return }
        var copy = reel[from]; copy.id = UUID()
        pushUndo()
        let to = targetID.flatMap { t in reel.firstIndex(where: { $0.id == t }) } ?? reel.count
        reel.insert(copy, at: to)
        reelChanged(keepingTime: time)
        toast(L("#%ld を #%ld として複製しました", from + 1, to + 1))
    }

    /// ⌘C: in the reel, the cut at the gate; in Source, the IN–OUT range (or the whole clip).
    func copyCut() {
        switch mode {
        case .reel:
            guard let l = locate(time, in: reel) else { toast(L("コピーできるカットがありません")); return }
            cutClipboard = [l.segment]
            toast(L("#%ld をコピーしました", l.index + 1))
        case .source:
            guard let m = currentMedia else { toast(L("コピーできるカットがありません")); return }
            let a = m.markIn ?? 0, b = m.markOut ?? m.duration
            guard b - a >= 1 / m.fps * 0.99 else { toast(L("IN と OUT の間が短すぎます")); return }
            cutClipboard = [Segment(mediaID: m.id, start: a, end: b)]
            toast(L("IN〜OUT をコピーしました"))
        }
    }

    /// ⌘V: in the reel, insert right after the cut at the gate and park on it; in Source, append to the reel.
    func pasteCut() {
        let items = cutClipboard.filter { clip($0.mediaID) != nil }.map { s -> Segment in
            var c = s; c.id = UUID(); return c
        }
        guard !items.isEmpty else { return }
        pushUndo()
        if mode == .reel, let l = locate(time, in: reel) {
            let at = l.index + 1
            reel.insert(contentsOf: items, at: at)
            let start = reel.prefix(at).reduce(0) { $0 + $1.length }
            reelChanged(keepingTime: start + 0.5 / engine.fps)
            toast(L("#%ld に貼り付けました", at + 1))
        } else {
            reel.append(contentsOf: items)
            if mode == .reel { reelChanged(keepingTime: time) }
            toast(L("リールの最後に貼り付けました（#%ld）", reel.count))
        }
    }

    func jumpToSegment(_ index: Int) {
        guard reel.indices.contains(index) else { return }
        if mode != .reel { setMode(.reel) }
        let start = reel.prefix(index).reduce(0) { $0 + $1.length }
        jump(to: start + 0.5 / engine.fps)
    }

    private func reelChanged(keepingTime t: Double) {
        if mode == .reel {
            if reel.isEmpty {
                mode = .source
                reloadPlayer(at: currentMedia?.lastTime ?? 0)
            } else {
                reloadPlayer(at: t)
            }
        }
    }

    private func pushUndo() {
        undoStack.append(reel)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(reel)
        reel = prev
        reelChanged(keepingTime: time)
        toast(L("取り消し"))
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(reel)
        reel = next
        reelChanged(keepingTime: time)
        toast(L("やり直し"))
    }

    // MARK: export (see Export.swift)

    func cancelExport() { exportSession?.cancelExport() }

    // MARK: misc

    func toast(_ msg: String) {
        toastMessage = msg
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { toastMessage = nil }
        }
    }

    /// Returns true when the key was handled.
    func handleKey(_ e: NSEvent) -> Bool {
        if exportProgress != nil || showExportSheet { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) { return false }
        let shift = mods.contains(.shift)
        let big = max(1, Int(engine.fps.rounded()))
        let n = shift ? big : 1

        switch e.keyCode {
        case 49: togglePlay(); return true                       // space
        case 36, 76: splice(); return true                       // return / enter
        case 51, 117: liftAtGate(); return true                  // delete
        case 123: step(-n); return true                          // ←
        case 124: step(n); return true                           // →
        case 125: step(n * direction); return true               // ↓ film moves down
        case 126: step(-n * direction); return true              // ↑
        case 115: home(); return true
        case 119: end(); return true
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "j": setSpeed(speed >= 0 ? -1 : max(speed * 2, -4))
        case "k": stop()
        case "l": setSpeed(speed <= 0 ? 1 : min(speed * 2, 4))
        case "i": markIn()
        case "o": markOut()
        case "c": cutAtGate()
        case "x": liftAtGate()
        case "1": setMode(.source)
        case "2": setMode(.reel)
        default: return false
        }
        return true
    }
}
