import SwiftUI
import AppKit

/// A horizontal-only scroller where an ordinary vertical mouse wheel also scrolls sideways
/// (SwiftUI's ScrollView only reacts to horizontal swipes / shift+wheel).
struct HorizontalScroll<Content: View>: NSViewRepresentable {
    /// When this value grows (e.g. a clip was spliced on), scroll to the right end.
    var scrollToEndToken: Int = 0
    @ViewBuilder var content: () -> Content

    final class Coordinator { var lastToken = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SidewaysScrollView {
        let sv = SidewaysScrollView()
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.horizontalScrollElasticity = .allowed
        sv.verticalScrollElasticity = .none
        let hc = NSHostingController(rootView: AnyView(content()))
        hc.sizingOptions = []
        sv.host = hc
        sv.documentView = hc.view
        context.coordinator.lastToken = scrollToEndToken
        return sv
    }

    func updateNSView(_ sv: SidewaysScrollView, context: Context) {
        sv.host?.rootView = AnyView(content())
        sv.fitDocument()
        if scrollToEndToken > context.coordinator.lastToken {
            // Wait for SwiftUI to lay out the new card (and its insert animation) before measuring.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sv.scrollToEnd() }
        }
        context.coordinator.lastToken = scrollToEndToken
    }
}

final class SidewaysScrollView: NSScrollView {
    var host: NSHostingController<AnyView>?

    override func layout() {
        super.layout()
        fitDocument()
    }

    /// Document is as tall as the visible area and exactly as wide as its SwiftUI content,
    /// so short rows stay pinned to the left edge instead of being centered.
    func fitDocument() {
        guard let doc = documentView, let host else { return }
        let h = contentSize.height
        let ideal = host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: h))
        let size = CGSize(width: ceil(ideal.width), height: h)
        if doc.frame.size != size { doc.setFrameSize(size) }
    }

    func scrollToEnd() {
        fitDocument()
        guard let doc = documentView else { return }
        let x = max(0, doc.frame.width - contentView.bounds.width)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            contentView.setBoundsOrigin(NSPoint(x: x, y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    override func scrollWheel(with e: NSEvent) {
        // Trackpad sideways swipes keep their native feel.
        if abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) {
            super.scrollWheel(with: e)
            return
        }
        guard let doc = documentView else { return }
        let dy = e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 12)
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        let x = min(max(contentView.bounds.origin.x - dy, 0), maxX)
        contentView.setBoundsOrigin(NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}
