import SwiftUI

/// Zooming the strip: the strip itself is magnified, a narrow overview reel appears on its left with
/// the zoomed stretch outlined, and the viewer slides over to make room.
extension Editor {
    static let zoomSteps: [Double] = [1, 1.5, 2, 3, 4]
    static let zoomRange: ClosedRange<Double> = 1...4

    var isZoomed: Bool { stripZoom > 1.01 }

    func setZoom(_ z: Double, animated: Bool = true) {
        let v = min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard abs(v - stripZoom) > 0.001 else { return }
        if v > 1.01 { lastZoom = v }
        if animated {
            withAnimation(.easeInOut(duration: 0.28)) { stripZoom = v }
        } else {
            stripZoom = v
        }
    }

    func zoomIn() { setZoom(Self.zoomSteps.first { $0 > stripZoom + 0.01 } ?? Self.zoomRange.upperBound) }
    func zoomOut() { setZoom(Self.zoomSteps.last { $0 < stripZoom - 0.01 } ?? 1) }

    /// Z: zoom in to the last magnification used (2× the first time), or back out.
    func toggleZoom() { setZoom(isZoomed ? 1 : lastZoom) }

    /// End of a pinch: settle on the nearest step (close to 1 means off).
    func settleZoom() {
        let z = Self.zoomSteps.min { abs($0 - stripZoom) < abs($1 - stripZoom) } ?? 1
        setZoom(z)
    }

    private var lastZoom: Double {
        get { UserDefaults.standard.object(forKey: "lastZoom") as? Double ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "lastZoom") }
    }
}
