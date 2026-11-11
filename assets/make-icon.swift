// Draws the app icon: a rounded speaker with a clock's hands inside its cone and two sound waves.
// Usage: swiftc assets/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <output folder> [light|dark]
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

    // The drawing is laid out around x 230...620, y 300...724, then centred and enlarged.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 1.35, y: 1.35); ctx.translateBy(x: -445, y: -512)
    ctx.setStrokeColor(ink); ctx.setFillColor(ink)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)

    // Speaker outline: a box and a cone. Each corner is a real arc; the radius is how round it is.
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 230, y: 430), 14), (CGPoint(x: 350, y: 430), 20), (CGPoint(x: 500, y: 300), 14),
        (CGPoint(x: 500, y: 724), 14), (CGPoint(x: 350, y: 594), 20), (CGPoint(x: 230, y: 594), 14)]
    let outline = CGMutablePath()
    let (first, last) = (corners[0].0, corners[corners.count - 1].0)
    outline.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
    for i in 0..<corners.count {
        outline.addArc(tangent1End: corners[i].0, tangent2End: corners[(i + 1) % corners.count].0, radius: corners[i].1)
    }
    outline.closeSubpath()
    ctx.addPath(outline); ctx.setLineWidth(20); ctx.strokePath()

    // Clock hands inside the cone
    ctx.setLineWidth(18)
    ctx.move(to: CGPoint(x: 440, y: 512)); ctx.addLine(to: CGPoint(x: 440, y: 407)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 440, y: 512)); ctx.addLine(to: CGPoint(x: 376, y: 544)); ctx.strokePath()
    ctx.fillEllipse(in: CGRect(x: 420, y: 492, width: 40, height: 40))

    // Sound waves
    ctx.setLineWidth(20)
    let spread = 38.0 * CGFloat.pi / 180
    for radius in [110.0, 190.0] as [CGFloat] {
        ctx.addArc(center: CGPoint(x: 470, y: 512), radius: radius, startAngle: -spread, endAngle: spread, clockwise: false)
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
