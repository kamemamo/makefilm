// Draws the MakeFilm app icon and writes a 1024×1024 PNG.
//   swift scripts/make-icon.swift Resources/AppIcon-1024.png
//
// Design: 35mm film runs almost edge to edge through the icon. The frame in the gate is lit
// (a sunset), and the next frame is a black title card that reads MAKE / FILM.
// Coordinates are in a 160×160 design grid, scaled onto the 824×824 macOS icon body.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let S: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)    // Apple's icon grid: 824 body on 1024 canvas
let k = body.width / 160                                         // design grid → pixels

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
/// Design-grid rect (origin top-left) → pixel rect in the top-left (flipped) context.
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: body.minX + x * k, y: body.minY + y * k, width: w * k, height: h * k)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: body.minX + x * k, y: body.minY + y * k) }

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)           // work top-left like the design

/// Centered single line of text with letter spacing, baseline at `y` (design grid).
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, centerX: CGFloat, baseline y: CGFloat, tracking: CGFloat) {
    let font = NSFont.systemFont(ofSize: size * k, weight: weight)
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: tracking * k])
    let line = CTLineCreateWithAttributedString(attr)
    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - tracking * k   // drop trailing kern
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.translateBy(x: body.minX + centerX * k - w / 2, y: body.minY + y * k)
    ctx.scaleBy(x: 1, y: -1)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// soft drop shadow under the body
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: hex(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(hex(0x2B332A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// hammertone body (only a narrow margin shows either side of the film)
let bg = CGGradient(colorsSpace: cs, colors: [hex(0x36402F), hex(0x232A22)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])

// --- film geometry -------------------------------------------------------
let filmX: CGFloat = 12, filmW: CGFloat = 136            // film edge to edge, small margins
let picX: CGFloat = 36, picW: CGFloat = 88               // picture area between the perforation lanes
let gateY: CGFloat = 16, picH: CGFloat = 68, gap: CGFloat = 5
let pitch = picH + gap                                   // one frame
let titleY = gateY + pitch                               // the frame after the gate

ctx.setFillColor(hex(0x3A2414)); ctx.fill(R(filmX, 0, filmW, 160))
ctx.setFillColor(hex(0xFFBE78, 0.07)); ctx.fill(R(filmX + 1.5, 0, 0.5, 160)); ctx.fill(R(filmX + filmW - 2, 0, 0.5, 160))

// perforations: 4 per frame, landscape (KS), aligned to the frame lines
let perfH: CGFloat = pitch / 4 * 0.42, perfW = perfH * 1.41
ctx.setFillColor(hex(0x151915))
for f in -1...2 {
    let top = gateY - gap / 2 + CGFloat(f) * pitch
    for j in 0..<4 {
        let y = top + (CGFloat(j) + 0.5) * pitch / 4 - perfH / 2
        for cx in [CGFloat(24), 136] {
            ctx.addPath(CGPath(roundedRect: R(cx - perfW / 2, y, perfW, perfH),
                               cornerWidth: perfH * 0.28 * k, cornerHeight: perfH * 0.28 * k, transform: nil))
        }
    }
}
ctx.fillPath()

// previous frame (only its bottom shows)
ctx.setFillColor(hex(0x6B5236)); ctx.fill(R(picX, gateY - pitch, picW, picH))

// warm light behind the gate
let glow = CGGradient(colorsSpace: cs, colors: [hex(0xFFD98A, 0.30), hex(0xFFD98A, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: P(80, gateY + picH / 2), startRadius: 0,
                       endCenter: P(80, gateY + picH / 2), endRadius: 62 * k, options: [])

// the frame in the gate: a setting sun
ctx.saveGState()
ctx.clip(to: R(picX, gateY, picW, picH))
let sky = CGGradient(colorsSpace: cs, colors: [hex(0xFFD98A), hex(0xF2B95A)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: P(0, gateY), end: P(0, gateY + picH), options: [])
ctx.setFillColor(hex(0xFFF3D2)); ctx.fillEllipse(in: R(68, gateY + 25, 24, 24))
let land = CGMutablePath()
land.move(to: P(picX, gateY + 44))
land.addCurve(to: P(picX + picW, gateY + 41), control1: P(60, gateY + 37), control2: P(100, gateY + 47))
land.addLine(to: P(picX + picW, gateY + picH)); land.addLine(to: P(picX, gateY + picH)); land.closeSubpath()
ctx.addPath(land); ctx.setFillColor(hex(0x8C5A22)); ctx.fillPath()
ctx.setFillColor(hex(0xFFF3D2, 0.55)); ctx.fill(R(64, gateY + 49, 32, 1.4)); ctx.fill(R(70, gateY + 54, 20, 1.4))
ctx.restoreGState()

// the next frame: a black title card
ctx.setFillColor(hex(0x101310)); ctx.fill(R(picX, titleY, picW, picH))
text("MAKE", size: 21, weight: .heavy, color: hex(0xEDE6D3), centerX: 80, baseline: titleY + 29, tracking: 3.2)
text("FILM", size: 21, weight: .heavy, color: hex(0xE3A548), centerX: 80, baseline: titleY + 54, tracking: 3.2)

// film fades a little into the dark at the very top and bottom
let fade = CGGradient(colorsSpace: cs, colors: [hex(0x1F251E, 0.75), hex(0x1F251E, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fade, start: P(0, 0), end: P(0, 12), options: [])
ctx.drawLinearGradient(fade, start: P(0, 160), end: P(0, 152), options: [])

// gate corner brackets
ctx.setStrokeColor(hex(0xE3A548)); ctx.setLineWidth(3.4 * k); ctx.setLineCap(.round); ctx.setLineJoin(.round)
let g0 = P(picX - 5, gateY - 5), g1 = P(picX + picW + 5, gateY + picH + 5), c = 12 * k
for pts in [[CGPoint(x: g0.x, y: g0.y + c), g0, CGPoint(x: g0.x + c, y: g0.y)],
            [CGPoint(x: g1.x - c, y: g0.y), CGPoint(x: g1.x, y: g0.y), CGPoint(x: g1.x, y: g0.y + c)],
            [CGPoint(x: g0.x, y: g1.y - c), CGPoint(x: g0.x, y: g1.y), CGPoint(x: g0.x + c, y: g1.y)],
            [CGPoint(x: g1.x - c, y: g1.y), g1, CGPoint(x: g1.x, y: g1.y - c)]] {
    ctx.addLines(between: pts)
}
ctx.strokePath()
ctx.restoreGState()

// subtle rim
ctx.addPath(shape); ctx.setStrokeColor(hex(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
