import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

// MARK: - options

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case h264, hevc, prores422, prores4444, audio, still

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: return "H.264（MP4）"
        case .hevc: return "HEVC / H.265（MOV）"
        case .prores422: return "Apple ProRes 422（MOV）"
        case .prores4444: return "Apple ProRes 4444（MOV）"
        case .audio: return "音声のみ（AAC・M4A）"
        case .still: return "静止画（PNG）"
        }
    }

    var detail: String {
        switch self {
        case .h264: return "どこでも再生できる共有向け。SNS・Web・送付に"
        case .hevc: return "H.264 と同じ画質でファイルが小さい。新しめの機器向け"
        case .prores422: return "画質劣化の少ない編集用。他の編集ソフトへ渡すときに"
        case .prores4444: return "422 より色情報が多い最高画質のマスター用。ファイルは大きい"
        case .audio: return "映像を捨てて音だけを書き出す"
        case .still: return "ゲートにある今のコマを 1 枚の画像に"
        }
    }

    var ext: String {
        switch self {
        case .h264: return "mp4"
        case .hevc, .prores422, .prores4444: return "mov"
        case .audio: return "m4a"
        case .still: return "png"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .h264: return .mp4
        case .audio: return .m4a
        default: return .mov
        }
    }

    var utType: UTType {
        switch self {
        case .h264: return .mpeg4Movie
        case .audio: return .mpeg4Audio
        case .still: return .png
        default: return .quickTimeMovie
        }
    }

    var isMovie: Bool { self != .audio && self != .still }

    /// Sizes this format can be scaled to (ProRes / audio / still keep the original).
    var resolutions: [ExportResolution] {
        switch self {
        case .h264: return [.original, .uhd, .fhd, .hd]
        case .hevc: return [.original, .uhd, .fhd]
        default: return []
        }
    }

    func preset(_ r: ExportResolution) -> String {
        switch (self, r) {
        case (.h264, .uhd): return AVAssetExportPreset3840x2160
        case (.h264, .fhd): return AVAssetExportPreset1920x1080
        case (.h264, .hd): return AVAssetExportPreset1280x720
        case (.h264, _): return AVAssetExportPresetHighestQuality
        case (.hevc, .uhd): return AVAssetExportPresetHEVC3840x2160
        case (.hevc, .fhd): return AVAssetExportPresetHEVC1920x1080
        case (.hevc, _): return AVAssetExportPresetHEVCHighestQuality
        case (.prores422, _): return AVAssetExportPresetAppleProRes422LPCM
        case (.prores4444, _): return AVAssetExportPresetAppleProRes4444LPCM
        case (.audio, _): return AVAssetExportPresetAppleM4A
        case (.still, _): return AVAssetExportPresetPassthrough
        }
    }

    var nameSuffix: String {
        switch self {
        case .h264: return ""
        case .hevc: return "_HEVC"
        case .prores422: return "_ProRes422"
        case .prores4444: return "_ProRes4444"
        case .audio: return "_音声"
        case .still: return "_コマ"
        }
    }
}

enum ExportResolution: String, CaseIterable, Identifiable, Codable {
    case original, uhd, fhd, hd
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "元のサイズ"
        case .uhd: return "4K"
        case .fhd: return "1080p"
        case .hd: return "720p"
        }
    }
    /// Bounding box the preset fits into (nil = keep original).
    var box: CGSize? {
        switch self {
        case .original: return nil
        case .uhd: return CGSize(width: 3840, height: 2160)
        case .fhd: return CGSize(width: 1920, height: 1080)
        case .hd: return CGSize(width: 1280, height: 720)
        }
    }
}

enum ExportTarget: String, CaseIterable, Identifiable, Codable {
    case reel, source
    var id: String { rawValue }
    var title: String { self == .reel ? "リール全体" : "素材の IN〜OUT" }
}

struct ExportOptions: Codable, Equatable {
    var format: ExportFormat = .h264
    var resolution: ExportResolution = .original
    var target: ExportTarget = .reel

    private static let key = "exportOptions"
    static func load() -> ExportOptions {
        guard let d = UserDefaults.standard.data(forKey: key),
              let o = try? JSONDecoder().decode(ExportOptions.self, from: d) else { return ExportOptions() }
        return o
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

// MARK: - running exports

extension Editor {
    var canExport: Bool { !media.isEmpty && exportProgress == nil }

    func openExport() {
        guard canExport else { return }
        stop()
        if reel.isEmpty { exportOptions.target = .source }
        if currentMedia == nil { exportOptions.target = .reel }
        showExportSheet = true
    }

    /// The film a target would export.
    func exportSegments(_ target: ExportTarget) -> [Segment] {
        switch target {
        case .reel:
            return reel
        case .source:
            guard let m = currentMedia else { return [] }
            return [Segment(mediaID: m.id, start: m.markIn ?? 0, end: m.markOut ?? m.duration)]
        }
    }

    func runExport() {
        let o = exportOptions
        o.save()
        showExportSheet = false
        if o.format == .still { exportStill(); return }

        let segs = exportSegments(o.target)
        guard !segs.isEmpty, let c = ReelComposition.build(segs, clips: clipMap) else {
            toast("書き出すフィルムがありません"); return
        }
        if o.format == .audio && c.composition.tracks(withMediaType: .audio).isEmpty {
            toast("音声トラックがありません"); return
        }
        guard let session = AVAssetExportSession(asset: c.composition, presetName: o.format.preset(o.resolution)),
              session.supportedFileTypes.contains(o.format.fileType) else {
            toast("この素材は \(o.format.title) で書き出せません"); return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [o.format.utType]
        panel.nameFieldStringValue = defaultExportName(o) + "." + o.format.ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)

        if o.format.isMovie { session.videoComposition = c.videoComposition }
        session.outputURL = url
        session.outputFileType = o.format.fileType
        exportSession = session
        exportProgress = 0

        Task {
            while let s = exportSession, s.status == .waiting || s.status == .exporting || s.status == .unknown {
                exportProgress = Double(s.progress)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        Task {
            await session.export()
            let status = session.status
            exportSession = nil
            exportProgress = nil
            switch status {
            case .completed:
                toast("書き出しました: \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .cancelled:
                toast("書き出しを中止しました")
            default:
                toast("書き出しに失敗しました: \(session.error?.localizedDescription ?? "")")
            }
        }
    }

    private func defaultExportName(_ o: ExportOptions) -> String {
        let base: String
        if o.format == .still || o.target == .source, let m = currentMedia, mode == .source || o.target == .source {
            base = (m.name as NSString).deletingPathExtension
        } else {
            base = "MakeFilm リール"
        }
        var name = base + o.format.nameSuffix
        if o.format == .still { name += "_" + TC.string(time, fps: engine.fps).replacingOccurrences(of: ":", with: "-") }
        if let box = o.resolution.box, o.format.resolutions.contains(o.resolution) { name += "_\(Int(box.height))p" }
        return name
    }

    /// Save the frame currently in the gate as a PNG.
    func exportStill() {
        let t = time
        let gen: AVAssetImageGenerator
        switch mode {
        case .source:
            guard let m = currentMedia else { return }
            gen = AVAssetImageGenerator(asset: m.asset)
        case .reel:
            guard let c = ReelComposition.build(reel, clips: clipMap) else { return }
            gen = AVAssetImageGenerator(asset: c.composition)
            gen.videoComposition = c.videoComposition
        }
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let name = defaultExportName(exportOptions) + ".png"

        Task {
            guard let img = try? await gen.image(at: cm(t)).image else {
                toast("コマを取り出せませんでした"); return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                toast("保存できませんでした"); return
            }
            CGImageDestinationAddImage(dest, img, nil)
            if CGImageDestinationFinalize(dest) {
                toast("書き出しました: \(url.lastPathComponent)（\(img.width)×\(img.height)）")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                toast("保存できませんでした")
            }
        }
    }
}

// MARK: - sheet

struct ExportSheet: View {
    @Bindable var editor: Editor

    private var o: ExportOptions { editor.exportOptions }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("書き出し").font(.system(size: 17, weight: .bold))

            // what
            VStack(alignment: .leading, spacing: 8) {
                label("書き出す範囲")
                if o.format == .still {
                    Text("ゲートにある今のコマ（\(TC.string(editor.time, fps: editor.engine.fps))）")
                        .foregroundStyle(Theme.muted)
                } else {
                    HStack(spacing: 0) {
                        ForEach(ExportTarget.allCases) { t in
                            Button(t.title) { editor.exportOptions.target = t }
                                .buttonStyle(FilmButtonStyle(on: o.target == t))
                                .disabled(t == .reel ? editor.reel.isEmpty : editor.currentMedia == nil)
                        }
                    }
                }
            }

            // format
            VStack(alignment: .leading, spacing: 6) {
                label("形式")
                ForEach(ExportFormat.allCases) { f in formatRow(f) }
            }

            // size
            if !o.format.resolutions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    label("サイズ")
                    HStack(spacing: 0) {
                        ForEach(o.format.resolutions) { r in
                            Button(r.title) { editor.exportOptions.resolution = r }
                                .buttonStyle(FilmButtonStyle(on: o.resolution == r))
                        }
                    }
                }
            }

            Text(summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.grease)

            HStack {
                Spacer()
                Button("キャンセル") { editor.showExportSheet = false }
                    .buttonStyle(FilmButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("書き出す…") { editor.runExport() }
                    .buttonStyle(FilmButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
        .onChange(of: editor.exportOptions.format) { _, f in
            if !f.resolutions.contains(editor.exportOptions.resolution) { editor.exportOptions.resolution = .original }
        }
    }

    private var ready: Bool {
        o.format == .still ? editor.engine.duration > 0 : !editor.exportSegments(o.target).isEmpty
    }

    private var summary: String {
        if o.format == .still {
            let size = editor.mode == .reel ? editor.reel.first.flatMap { editor.clip($0.mediaID) }?.displaySize
                                            : editor.currentMedia?.displaySize
            return "PNG · " + (size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "")
        }
        let segs = editor.exportSegments(o.target)
        let dur = segs.reduce(0) { $0 + $1.length }
        var parts = [TC.string(dur, fps: 24), "\(segs.count) カット"]
        if o.format.isMovie, let first = segs.first.flatMap({ editor.clip($0.mediaID) }) {
            var size = first.displaySize
            if let box = o.resolution.box, o.format.resolutions.contains(o.resolution) {
                // Presets only ever shrink; a small source stays at its own size.
                let s = min(1, box.width / size.width, box.height / size.height)
                size = CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
            }
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        parts.append("." + o.format.ext)
        return parts.joined(separator: " · ")
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
    }

    private func formatRow(_ f: ExportFormat) -> some View {
        let on = o.format == f
        return HStack(spacing: 10) {
            Image(systemName: on ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(on ? Theme.accent : Theme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.title).fontWeight(on ? .semibold : .regular)
                Text(f.detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.panel2 : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.accent.opacity(0.7) : Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { editor.exportOptions.format = f }
    }
}
