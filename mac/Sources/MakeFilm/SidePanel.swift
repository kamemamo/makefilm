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

struct SidePanel: View {
    let editor: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("素材", trailing: editor.media.isEmpty ? "" : "\(editor.media.count) 本")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(editor.media) { m in mediaRow(m) }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 190)

            sectionTitle("トリムビン（リール順）",
                         trailing: editor.reel.isEmpty ? "" : TC.string(editor.reelDuration, fps: 24))
            // the rack the clips hang from
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(hex: 0x6B7366), Color(hex: 0x3C433A)], startPoint: .top, endPoint: .bottom))
                .frame(height: 6)
                .padding(.horizontal, 10)

            if editor.reel.isEmpty {
                Text("素材で I・O を付けて Return（スプライス）すると、ここに吊るされます。ドラッグで並べ替え。")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .padding(14)
                Spacer()
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(editor.reel.enumerated()), id: \.element.id) { i, seg in
                            ClipCard(editor: editor, index: i, segment: seg)
                        }
                        Color.clear.frame(width: 40, height: 200)
                            .dropDestination(for: String.self) { items, _ in
                                guard let s = items.first, let id = UUID(uuidString: s) else { return false }
                                editor.move(id, before: nil); return true
                            }
                    }
                    .padding(.horizontal, 10)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private func sectionTitle(_ s: String, trailing: String) -> some View {
        HStack {
            Text(s); Spacer(); Text(trailing).font(.system(size: 11, design: .monospaced))
        }
        .font(.system(size: 11, weight: .semibold))
        .tracking(1.5)
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
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
    @State private var targeted = false

    var body: some View {
        let on = editor.mode == .reel && editor.activeSegmentIndex == index
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 5, bottomTrailingRadius: 5, topTrailingRadius: 2)
                .fill(Color(hex: 0x9AA395)).frame(width: 10, height: 14).zIndex(1)
            VStack(spacing: 4) {
                ForEach([segment.start, (segment.start + segment.end) / 2, segment.end - 0.04], id: \.self) { t in
                    ThumbView(editor: editor, mediaID: segment.mediaID, time: t)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 9)
            .background(FilmEdge())
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(on ? Theme.accent : .clear, lineWidth: 2).padding(-2))
            .overlay(alignment: .leading) {
                if targeted { Rectangle().fill(Theme.accent).frame(width: 3).offset(x: -7) }
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
                .help("リールから外す")
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
            editor.move(id, before: segment.id); return true
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
                for x in [CGFloat(2), size.width - 6] {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: 4, height: 4), cornerRadius: 1),
                             with: .color(Theme.hole))
                }
                y += 8
            }
        }
    }
}
