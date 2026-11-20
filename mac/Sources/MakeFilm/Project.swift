import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// `.makefilm` project document (declared in Info.plist).
    static let makefilmProject = UTType(exportedAs: "local.makefilm.project", conformingTo: .json)
}

/// The `.makefilm` file: plain JSON that points at the source files (they are not copied).
struct ProjectFile: Codable {
    var format = "makefilm-project"
    var version = 1
    var media: [Media]
    var reel: [Segment]
    var currentMediaID: UUID?
    var mode: String            // "source" | "reel"
    var reelTime: Double
    var direction: Int
    var stripFPS: Int
    /// Sound reel (added in 0.5; absent in older files).
    var musicSources: [Media]? = nil
    var music: [MusicClip]? = nil

    struct Media: Codable {
        var id: UUID
        var path: String            // absolute path when saved
        var relativePath: String?   // relative to the project file, used if the folder was moved
        var markIn: Double?
        var markOut: Double?
        var lastTime: Double
    }
}

/// The part of the state that counts as "the edit" (positions and view settings don't make a project dirty).
struct ProjectCore: Equatable {
    struct M: Equatable { var id: UUID; var path: String; var markIn: Double?; var markOut: Double? }
    var media: [M] = []
    var reel: [Segment] = []
    var musicSources: [M] = []
    var music: [MusicClip] = []
}

extension Editor {

    // MARK: state

    var projectName: String { projectURL?.deletingPathExtension().lastPathComponent ?? L("名称未設定") }
    var isDirty: Bool { core() != savedCore }
    var windowTitle: String { projectName + (isDirty ? L(" — 編集済み") : "") }

    func core() -> ProjectCore {
        ProjectCore(media: media.map { .init(id: $0.id, path: $0.url.standardizedFileURL.path, markIn: $0.markIn, markOut: $0.markOut) },
                    reel: reel,
                    musicSources: musicSources.map { .init(id: $0.id, path: $0.url.standardizedFileURL.path, markIn: nil, markOut: nil) },
                    music: music)
    }

    // MARK: new / open / save

    func newProject() {
        guard confirmDiscardIfNeeded() else { return }
        stop()
        thumbs.removeAll(); thumbsHi.removeAll()
        envelopes.removeAll()
        media = []; reel = []; undoStack = []; redoStack = []
        musicSources = []; music = []; selectedMusicID = nil
        currentMediaID = nil; mode = .source; reelTime = 0
        projectURL = nil
        reloadPlayer(at: 0)
        savedCore = core()
        UserDefaults.standard.removeObject(forKey: "lastProject")
    }

    func openProjectPanel() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.makefilmProject]
        panel.allowsMultipleSelection = false
        panel.message = L("開くプロジェクトを選んでください")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(url) }
    }

    /// Opens a project; asks about unsaved changes first unless `confirmed`.
    func openProject(_ url: URL, confirmed: Bool = true) async {
        launchHandled = true
        if !confirmed { guard confirmDiscardIfNeeded() else { return } }
        let file: ProjectFile
        do {
            file = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
        } catch {
            toast(L("プロジェクトを開けませんでした: %@", url.lastPathComponent))
            return
        }
        stop()

        // Find every source file: saved path → path relative to the project → ask the user.
        let base = url.deletingLastPathComponent()
        var loaded: [MediaClip] = []
        var relinked = 0, missing: [String] = []
        for m in file.media {
            var candidates = [URL(fileURLWithPath: m.path)]
            if let r = m.relativePath { candidates.append(URL(fileURLWithPath: r, relativeTo: base).standardizedFileURL) }
            var found = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            if found == nil { found = locateMissing(name: (m.path as NSString).lastPathComponent) }
            guard let f = found, var clip = try? await MediaClip.load(url: f, id: m.id) else {
                missing.append((m.path as NSString).lastPathComponent); continue
            }
            if f.standardizedFileURL.path != URL(fileURLWithPath: m.path).standardizedFileURL.path { relinked += 1 }
            clip.markIn = m.markIn; clip.markOut = m.markOut; clip.lastTime = m.lastTime
            loaded.append(clip)
        }

        // the sound reel's audio files, found the same way
        var loadedAudio: [AudioSource] = []
        for m in file.musicSources ?? [] {
            var candidates = [URL(fileURLWithPath: m.path)]
            if let r = m.relativePath { candidates.append(URL(fileURLWithPath: r, relativeTo: base).standardizedFileURL) }
            var found = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            if found == nil { found = locateMissing(name: (m.path as NSString).lastPathComponent, audio: true) }
            guard let f = found, let a = try? await AudioSource.load(url: f, id: m.id) else {
                missing.append((m.path as NSString).lastPathComponent); continue
            }
            if f.standardizedFileURL.path != URL(fileURLWithPath: m.path).standardizedFileURL.path { relinked += 1 }
            loadedAudio.append(a)
        }

        stripFPS = [0, 6, 12, 24].contains(file.stripFPS) ? file.stripFPS : 0
        direction = file.direction >= 0 ? 1 : -1
        thumbs.removeAll(); thumbsHi.removeAll()
        envelopes.removeAll()
        for c in loaded { thumbs.register(c); thumbsHi.register(c); loadEnvelope(for: c) }
        let ids = Set(loaded.map(\.id))
        media = loaded
        reel = file.reel.filter { ids.contains($0.mediaID) }
        musicSources = loadedAudio
        for a in loadedAudio { loadEnvelope(source: a) }
        let audioIDs = Set(loadedAudio.map(\.id))
        music = (file.music ?? []).filter { audioIDs.contains($0.sourceID) }
        selectedMusicID = nil
        undoStack = []; redoStack = []
        currentMediaID = file.currentMediaID.flatMap { ids.contains($0) ? $0 : nil } ?? loaded.first?.id
        mode = (file.mode == "reel" && (!reel.isEmpty || !music.isEmpty)) ? .reel : .source
        reelTime = file.reelTime
        projectURL = url
        reloadPlayer(at: mode == .reel ? reelTime : (currentMedia?.lastTime ?? 0))

        // Relinked or dropped files mean the saved file is out of date → leave it marked as edited.
        if relinked == 0 && missing.isEmpty {
            savedCore = core()
        } else {
            savedCore = ProjectCore(media: file.media.map { .init(id: $0.id, path: $0.path, markIn: $0.markIn, markOut: $0.markOut) },
                                    reel: file.reel,
                                    musicSources: (file.musicSources ?? []).map { .init(id: $0.id, path: $0.path, markIn: nil, markOut: nil) },
                                    music: file.music ?? [])
        }
        noteRecent(url)

        if !missing.isEmpty {
            alert(L("見つからない素材があります"),
                  L("次の素材は読み込めなかったため、プロジェクトから外しました（使っていたカットも外れます）。") + "\n\n" + missing.joined(separator: "\n"))
        } else {
            toast(relinked > 0 ? L("開きました（素材の場所を %ld 件更新）: %@", relinked, projectName) : L("開きました: %@", projectName))
        }
    }

    /// Save to the current file, or ask where if the project has never been saved. Returns false if cancelled/failed.
    @discardableResult
    func saveProject() -> Bool {
        guard let url = projectURL else { return saveProjectAs() }
        return write(to: url)
    }

    @discardableResult
    func saveProjectAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.makefilmProject]
        panel.nameFieldStringValue = projectName + ".makefilm"
        panel.message = L("プロジェクトの保存先を選んでください（素材ファイルはコピーされません）")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard write(to: url) else { return false }
        projectURL = url
        noteRecent(url)
        return true
    }

    private func write(to url: URL) -> Bool {
        rememberPosition()
        let base = url.deletingLastPathComponent()
        let file = ProjectFile(
            media: media.map { m in
                .init(id: m.id, path: m.url.standardizedFileURL.path,
                      relativePath: Self.relativePath(from: base, to: m.url),
                      markIn: m.markIn, markOut: m.markOut, lastTime: m.lastTime)
            },
            reel: reel, currentMediaID: currentMediaID,
            mode: mode == .reel ? "reel" : "source", reelTime: reelTime,
            direction: direction, stripFPS: stripFPS,
            musicSources: musicSources.map { a in
                .init(id: a.id, path: a.url.standardizedFileURL.path,
                      relativePath: Self.relativePath(from: base, to: a.url), markIn: nil, markOut: nil, lastTime: 0)
            },
            music: music)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(file).write(to: url, options: .atomic)
        } catch {
            alert(L("保存できませんでした"), error.localizedDescription)
            return false
        }
        savedCore = core()
        UserDefaults.standard.set(url.path, forKey: "lastProject")
        toast(L("保存しました: %@", url.lastPathComponent))
        return true
    }

    // MARK: unsaved changes

    /// Returns true when it is OK to throw away the current state.
    func confirmDiscardIfNeeded() -> Bool {
        guard isDirty else { return true }
        let a = NSAlert()
        a.messageText = L("「%@」への変更を保存しますか？", projectName)
        a.informativeText = L("保存しないと、リールや IN/OUT の変更は失われます。")
        a.addButton(withTitle: L("保存"))
        a.addButton(withTitle: L("キャンセル"))
        a.addButton(withTitle: L("保存しない"))
        switch a.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func locateMissing(name: String, audio: Bool = false) -> URL? {
        let p = NSOpenPanel()
        p.message = L("素材「%@」が見つかりません。新しい場所を指定してください（キャンセルで外す）", name)
        p.allowedContentTypes = audio ? [.audio] : [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: recent projects

    static func loadRecents() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func noteRecent(_ url: URL) {
        var list = recentProjects.filter { $0.standardizedFileURL != url.standardizedFileURL }
        list.insert(url, at: 0)
        recentProjects = Array(list.prefix(8))
        UserDefaults.standard.set(recentProjects.map(\.path), forKey: "recentProjects")
        UserDefaults.standard.set(url.path, forKey: "lastProject")
    }

    func clearRecents() {
        recentProjects = []
        UserDefaults.standard.removeObject(forKey: "recentProjects")
    }

    /// Reopen the project that was open last time (when nothing else was asked for at launch).
    func reopenLastProjectIfAny() {
        guard !launchHandled, let p = UserDefaults.standard.string(forKey: "lastProject"),
              FileManager.default.fileExists(atPath: p) else { return }
        Task { await openProject(URL(fileURLWithPath: p)) }
    }

    // MARK: files from Finder / drops / command line

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "mts"]

    /// `.makefilm` → open as project; videos → import as source clips. Returns true if anything was taken.
    @discardableResult
    func openFiles(_ urls: [URL]) -> Bool {
        if let project = urls.first(where: { $0.pathExtension.lowercased() == "makefilm" }) {
            launchHandled = true
            Task { await openProject(project, confirmed: false) }
            return true
        }
        let videos = urls.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
        let audio = urls.filter { AudioSource.extensions.contains($0.pathExtension.lowercased()) }
        importURLs(videos)
        if !audio.isEmpty { importMusic(audio) }
        return !videos.isEmpty || !audio.isEmpty
    }

    // MARK: helpers

    /// "../clips/a.mov"-style path from a folder to a file.
    static func relativePath(from dir: URL, to file: URL) -> String {
        let a = dir.standardizedFileURL.pathComponents
        let b = file.standardizedFileURL.pathComponents
        var i = 0
        while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: a.count - i) + b[i...]).joined(separator: "/")
    }
}
