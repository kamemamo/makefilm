import SwiftUI

/// A thumbnail that fills in once the store has generated it.
struct ThumbView: View {
    let editor: Editor
    let mediaID: UUID
    let time: Double
    var width: CGFloat = 58
    var height: CGFloat = 33

    var body: some View {
        let _ = editor.thumbVersion   // re-render when thumbnails arrive
        let idx = editor.thumbs.index(for: time)
        Group {
            if let img = editor.thumbs.keepImage(mediaID, idx) {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color(hex: 0x1A120A)
            }
        }
        .frame(width: width, height: height)
        .background(Color.black)
    }
}

func sectionTitle(_ s: String, trailing: String) -> some View {
    HStack {
        Text(s); Spacer(); Text(trailing).font(.system(size: 11, design: .monospaced))
    }
    .font(.system(size: 11, weight: .semibold))
    .tracking(1.5)
    .foregroundStyle(Theme.muted)
    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
}

/// Trim bin across the bottom of the window: clips hang from a rack, left to right in reel order.
struct TrimBinView: View {
    let editor: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(L("トリムビン（リール順）"),
                         trailing: editor.reel.isEmpty ? "" : L("%ld カット", editor.reel.count) + " · " + TC.string(editor.reelDuration, fps: 24))
                .padding(.top, -4)
            // the rack the clips hang from
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(hex: 0x6B7366), Color(hex: 0x3C433A)], startPoint: .top, endPoint: .bottom))
                .frame(height: 6)
                .padding(.horizontal, 10)

            if editor.reel.isEmpty {
                Text(L("素材で I・O を付けて Return（スプライス）すると、ここに吊るされます。ドラッグで並べ替え（⌥ を押しながらで複製）、⌘C / ⌘V でコピーと貼り付け、ホイールで左右にスクロール。"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .padding(14)
                Spacer(minLength: 0)
            } else {
                GeometryReader { geo in
                    // Clips hang at lengths proportional to their running time.
                    // The longest one fills the bin's height; every clip shows at least one frame.
                    let filmMax = max(ClipCard.minFilm, geo.size.height - ClipCard.chrome)
                    let longest = max(editor.reel.map(\.length).max() ?? 1, 0.001)
                    let pxPerSec = filmMax / longest
                    HorizontalScroll(scrollToEndToken: editor.reel.count) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(editor.reel.enumerated()), id: \.element.id) { i, seg in
                                ClipCard(editor: editor, index: i, segment: seg,
                                         filmHeight: max(ClipCard.minFilm, seg.length * pxPerSec))
                            }
                            Color.clear.frame(width: 60, height: filmMax)
                                .contentShape(Rectangle())
                                .dropDestination(for: String.self) { items, _ in
                                    guard let s = items.first, let id = UUID(uuidString: s) else { return false }
                                    editor.dropCut(id, before: nil); return true
                                }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: geo.size.height, alignment: .top)
                        .animation(.easeOut(duration: 0.25), value: editor.reel)
                        .foregroundStyle(Theme.text)
                    }
                }
            }
        }
        .background(Theme.panel)
    }
}

struct MediaPanel: View {
    let editor: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(L("素材"), trailing: editor.media.isEmpty ? "" : L("%ld 本", editor.media.count))
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(editor.media) { m in mediaRow(m) }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private func mediaRow(_ m: MediaClip) -> some View {
        let on = m.id == editor.currentMediaID && editor.mode == .source
        return HStack(spacing: 10) {
            ThumbView(editor: editor, mediaID: m.id, time: m.duration * 0.25, width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).lineLimit(1).truncationMode(.middle)
                Text(TC.string(m.duration, fps: m.fps)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.panel2 : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.accent : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { editor.select(m.id) }
    }
}

/// A clip hanging in the trim bin.
struct ClipCard: View {
    let editor: Editor
    let index: Int
    let segment: Segment
    /// Height of the hanging film, proportional to the clip's length.
    let filmHeight: CGFloat
    @State private var targeted = false

    static let frameH: CGFloat = 33, frameGap: CGFloat = 4, filmPad: CGFloat = 5
    static let minFilm: CGFloat = frameH + filmPad * 2
    /// Pin + label + button below the film.
    static let chrome: CGFloat = 14 + 40 + 26 + 12

    /// As many frames as fit in the strip, sampled evenly across the clip.
    private var frameTimes: [Double] {
        let n = max(1, Int((filmHeight - Self.filmPad * 2 + Self.frameGap) / (Self.frameH + Self.frameGap)))
        return (0..<n).map { segment.start + (Double($0) + 0.5) / Double(n) * segment.length }
    }

    var body: some View {
        let on = editor.mode == .reel && editor.activeSegmentIndex == index
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 5, bottomTrailingRadius: 5, topTrailingRadius: 2)
                .fill(Color(hex: 0x9AA395)).frame(width: 10, height: 14).zIndex(1)
            VStack(spacing: Self.frameGap) {
                ForEach(frameTimes, id: \.self) { t in
                    ThumbView(editor: editor, mediaID: segment.mediaID, time: t)
                }
            }
            .padding(.vertical, Self.filmPad).padding(.horizontal, 9)
            .frame(height: filmHeight, alignment: .top)
            .clipped()
            .background(FilmEdge())
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(on ? Theme.accent : .clear, lineWidth: 2).padding(-2))
            .overlay(alignment: .leading) {
                if targeted {
                    // ⌥ held: the drop makes a copy
                    let copying = NSEvent.modifierFlags.contains(.option)
                    ZStack(alignment: .top) {
                        Rectangle().fill(copying ? Color(hex: 0x7BC47F) : Theme.accent).frame(width: 3)
                        if copying {
                            Text("+").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color(hex: 0x7BC47F))
                                .offset(y: -16)
                        }
                    }
                    .offset(x: -7)
                }
            }
            .padding(.top, -2)

            VStack(spacing: 1) {
                Text("#\(index + 1)").fontWeight(.semibold).foregroundStyle(Theme.text)
                Text(String(format: "%.1fs", segment.length))
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            .padding(.top, 4)

            Button("×") { editor.remove(at: index) }
                .buttonStyle(FilmButtonStyle(compact: true))
                .help(L("リールから外す"))
                .padding(.top, 4)
        }
        .frame(width: 76)
        .contentShape(Rectangle())
        .onTapGesture { editor.jumpToSegment(index) }
        .help("\(editor.clip(segment.mediaID)?.name ?? "")  \(TC.string(segment.start, fps: 24)) – \(TC.string(segment.end, fps: 24))")
        .draggable(segment.id.uuidString) {
            ThumbView(editor: editor, mediaID: segment.mediaID, time: segment.start).opacity(0.8)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            editor.dropCut(id, before: segment.id); return true
        } isTargeted: { targeted = $0 }
    }
}

/// Film base with perforations down both edges.
struct FilmEdge: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.film))
            var y: CGFloat = 2
            while y < size.height {
                for x in [CGFloat(1.5), size.width - 6.5] {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: 5, height: 3.5), cornerRadius: 1),
                             with: .color(Theme.hole))
                }
                y += 8
            }
        }
    }
}
