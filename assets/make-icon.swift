// Draws the app icon: a speaker with a clock at the corner of its box; the clock's hands are the box's edges (both shapes solid).
// Usage: swiftc assets/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <output folder> [light|dark] [nowaves] [filled]
// The shipped icon is made with: /tmp/make-icon assets dark nowaves filled
// Writes <output folder>/AppIcon.iconset (every size macOS wants) and icon-1024.png.
import AppKit
import CoreGraphics

// Laid out in a 1024-unit square with the origin at the top left.
func drawIcon(_ ctx: CGContext, dark: Bool) {
    let ink = dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.07, alpha: 1)
    let paper = dark ? CGColor(gray: 0.07, alpha: 1) : CGColor(gray: 1, alpha: 1)

    // macOS icon body: an 824 square inside the 1024 canvas
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(paper); ctx.fillPath()
    if !dark {   // a hairline so a white icon doesn't disappear on a white background
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 0.8, alpha: 1)); ctx.setLineWidth(6); ctx.strokePath()
    }

    // Layout (idea from the owner's sketch): a conventional speaker, with a clock at the
    // bottom-left corner of its box. The clock's two hands are the box's left and bottom edges.
    // Drawn around x 170...715, y 305...770, then centred and scaled.
    ctx.saveGState()
    let waves = !CommandLine.arguments.contains("nowaves")
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 1.25, y: 1.25); ctx.translateBy(x: waves ? -443 : -386, y: -538)
    ctx.setStrokeColor(ink); ctx.setFillColor(ink)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setLineWidth(22)

    let centre = CGPoint(x: 330, y: 620)   // clock centre = bottom-left corner of the speaker box
    let coneHeight: CGFloat = 440          // how tall the speaker's cone is (a regular speaker icon is about as tall as it is wide)

    // Speaker outline: a short box and a short cone. Each corner is a real arc; the radius is how round it is.
    let boxTop = centre.y - 190, boxRight = centre.x + 150, coneRight = centre.x + 270
    let midY = (boxTop + centre.y) / 2
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: centre.x, y: boxTop), 12), (CGPoint(x: boxRight, y: boxTop), 18), (CGPoint(x: coneRight, y: midY - coneHeight / 2), 12),
        (CGPoint(x: coneRight, y: midY + coneHeight / 2), 12), (CGPoint(x: boxRight, y: centre.y), 18), (centre, 1)]
    let outline = CGMutablePath()
    let (first, last) = (corners[0].0, corners[corners.count - 1].0)
    outline.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
    for i in 0..<corners.count {
        outline.addArc(tangent1End: corners[i].0, tangent2End: corners[(i + 1) % corners.count].0, radius: corners[i].1)
    }
    outline.closeSubpath()

    // Clock face, then the speaker outline (the clock's hands are the box's left and bottom edges)
    let r: CGFloat = 150
    let face = CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
    if CommandLine.arguments.contains("filled") {
        // Both shapes solid; where they overlap the fill flips to the background colour so the hands still show
        ctx.fillEllipse(in: face)
        ctx.addPath(outline); ctx.fillPath()
        ctx.saveGState()
        ctx.addEllipse(in: face); ctx.clip()
        ctx.addPath(outline); ctx.setFillColor(paper); ctx.fillPath()
        ctx.restoreGState()
        ctx.move(to: CGPoint(x: centre.x, y: boxTop)); ctx.addLine(to: centre); ctx.addLine(to: CGPoint(x: boxRight, y: centre.y))
        ctx.strokePath()
    } else {
        ctx.strokeEllipse(in: face)
        ctx.addPath(outline); ctx.strokePath()
    }
    ctx.fillEllipse(in: CGRect(x: centre.x - 17, y: centre.y - 17, width: 34, height: 34))

    // Sound waves
    let spread = 38.0 * CGFloat.pi / 180
    for radius in (waves ? [70.0, 125.0] : []) as [CGFloat] {
        ctx.addArc(center: CGPoint(x: coneRight, y: midY), radius: radius, startAngle: -spread, endAngle: spread, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func render(size: Int, dark: Bool, to path: String) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    drawIcon(ctx, dark: dark)
    let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
let dark = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "dark"
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
// Each size is drawn at its own resolution rather than scaled down, so small icons stay crisp.
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    render(size: px, dark: dark, to: "\(set)/icon_\(name).png")
}
render(size: 1024, dark: dark, to: out + "/icon-1024.png")
