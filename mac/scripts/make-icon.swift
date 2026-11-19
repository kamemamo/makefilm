// Draws the MakeFilm app icon (design A: "Gate") and writes a 1024×1024 PNG.
//   swift scripts/make-icon.swift Resources/AppIcon-1024.png
// Coordinates below are in a 160×160 design grid, scaled onto the 824×824 macOS icon body.
import CoreGraphics
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
/// Design-grid rect (origin top-left) → pixel rect in a top-left (flipped) context.
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: body.minX + x * k, y: body.minY + y * k, width: w * k, height: h * k)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: body.minX + x * k, y: body.minY + y * k) }

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// work top-left like the design
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// soft drop shadow under the body
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: hex(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(hex(0x2B332A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// hammertone body: slightly lighter at the top
let bg = CGGradient(colorsSpace: cs, colors: [hex(0x36402F), hex(0x232A22)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])

// film base
ctx.setFillColor(hex(0x3A2414)); ctx.fill(R(42, 0, 76, 160))
ctx.setFillColor(hex(0xFFBE78, 0.06)); ctx.fill(R(43.2, 0, 0.5, 160)); ctx.fill(R(116.3, 0, 0.5, 160))

// perforations: 4 per frame, landscape (KS)
ctx.setFillColor(hex(0x151915))
for i in 0..<16 {
    let y = 5 + CGFloat(i) * 10
    for x in [CGFloat(46), 105] {
        ctx.addPath(CGPath(roundedRect: R(x, y, 9, 6), cornerWidth: 1.5 * k, cornerHeight: 1.5 * k, transform: nil))
    }
}
ctx.fillPath()

// neighbouring frames
ctx.setFillColor(hex(0x5A4630)); ctx.fill(R(59, -14, 42, 32)); ctx.fill(R(59, 142, 42, 32))
ctx.setFillColor(hex(0x6B5236)); ctx.fill(R(59, 22, 42, 36)); ctx.fill(R(59, 102, 42, 36))

// warm light behind the gate
let glow = CGGradient(colorsSpace: cs, colors: [hex(0xFFD98A, 0.28), hex(0xFFD98A, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: P(80, 80), startRadius: 0, endCenter: P(80, 80), endRadius: 32 * k, options: [])

// the frame in the gate: a lit little landscape
ctx.saveGState()
ctx.clip(to: R(59, 62, 42, 36))
let sky = CGGradient(colorsSpace: cs, colors: [hex(0xFFD98A), hex(0xF2B95A)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: P(0, 62), end: P(0, 98), options: [])
// a setting sun on the horizon, the classic last shot
ctx.setFillColor(hex(0xFFF3D2)); ctx.fillEllipse(in: R(72, 78, 16, 16))
let land = CGMutablePath()
land.move(to: P(59, 87))
land.addCurve(to: P(101, 85), control1: P(72, 83), control2: P(88, 89))
land.addLine(to: P(101, 98)); land.addLine(to: P(59, 98)); land.closeSubpath()
ctx.addPath(land); ctx.setFillColor(hex(0x8C5A22)); ctx.fillPath()
ctx.setFillColor(hex(0xFFF3D2, 0.55)); ctx.fill(R(70, 89.5, 20, 1)); ctx.fill(R(74, 92.5, 12, 1))
ctx.restoreGState()

// film fades into the dark at top and bottom, like the viewer hood
let fade = CGGradient(colorsSpace: cs, colors: [hex(0x1F251E, 0.85), hex(0x1F251E, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fade, start: P(0, 0), end: P(0, 34), options: [])
ctx.drawLinearGradient(fade, start: P(0, 160), end: P(0, 126), options: [])

// gate corner brackets
ctx.setStrokeColor(hex(0xE3A548)); ctx.setLineWidth(3.2 * k); ctx.setLineCap(.round); ctx.setLineJoin(.round)
for pts in [[P(53, 68), P(53, 57), P(64, 57)], [P(96, 57), P(107, 57), P(107, 68)],
            [P(53, 92), P(53, 103), P(64, 103)], [P(96, 103), P(107, 103), P(107, 92)]] {
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
