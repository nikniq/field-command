// Renders the app icon into an .iconset folder: swift scripts/make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: s * 0.19, cornerHeight: s * 0.19, transform: nil))
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 0.20, green: 0.29, blue: 0.17, alpha: 1),
                                   CGColor(red: 0.07, green: 0.11, blue: 0.07, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
    ctx.setLineWidth(max(1, s / 256))
    var g = rect.minX
    while g < rect.maxX {
        ctx.move(to: CGPoint(x: g, y: rect.minY)); ctx.addLine(to: CGPoint(x: g, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.minX, y: g)); ctx.addLine(to: CGPoint(x: rect.maxX, y: g))
        g += s / 8
    }
    ctx.strokePath()

    func base(_ c: CGPoint, _ fill: CGColor, _ stroke: CGColor) {
        let r = CGRect(x: c.x - s * 0.13, y: c.y - s * 0.13, width: s * 0.26, height: s * 0.26)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil))
        ctx.setFillColor(fill); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil))
        ctx.setStrokeColor(stroke); ctx.setLineWidth(s * 0.02); ctx.strokePath()
        ctx.setFillColor(stroke)
        ctx.fillEllipse(in: CGRect(x: c.x - s * 0.045, y: c.y - s * 0.045, width: s * 0.09, height: s * 0.09))
    }
    base(CGPoint(x: s * 0.3, y: s * 0.3), CGColor(red: 0.1, green: 0.22, blue: 0.38, alpha: 1), CGColor(red: 0.28, green: 0.62, blue: 1, alpha: 1))
    base(CGPoint(x: s * 0.7, y: s * 0.7), CGColor(red: 0.36, green: 0.11, blue: 0.1, alpha: 1), CGColor(red: 0.95, green: 0.32, blue: 0.26, alpha: 1))

    // Central crystal
    let c = CGPoint(x: s * 0.5, y: s * 0.5)
    let crystal = CGMutablePath()
    crystal.move(to: CGPoint(x: c.x, y: c.y + s * 0.17))
    crystal.addLine(to: CGPoint(x: c.x + s * 0.08, y: c.y + s * 0.02))
    crystal.addLine(to: CGPoint(x: c.x, y: c.y - s * 0.13))
    crystal.addLine(to: CGPoint(x: c.x - s * 0.08, y: c.y + s * 0.02))
    crystal.closeSubpath()
    ctx.setShadow(offset: .zero, blur: s * 0.05, color: CGColor(red: 0.4, green: 0.92, blue: 1, alpha: 0.9))
    ctx.addPath(crystal); ctx.setFillColor(CGColor(red: 0.4, green: 0.92, blue: 1, alpha: 1)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)
    ctx.addPath(crystal); ctx.setStrokeColor(CGColor(red: 0.9, green: 1, blue: 1, alpha: 1)); ctx.setLineWidth(s * 0.012); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
