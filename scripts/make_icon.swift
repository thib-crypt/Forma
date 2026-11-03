import AppKit
let out = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.025; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.black.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.32, alpha: 1), NSColor(srgbRed: 0.93, green: 0.22, blue: 0.47, alpha: 1), NSColor(srgbRed: 0.42, green: 0.25, blue: 0.93, alpha: 1)])!.draw(in: path, angle: -60)
    // glossy top
    NSGraphicsContext.saveGraphicsState(); path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Two stacked "files" (before → after)
    func card(_ r: NSRect, alpha: CGFloat) {
        let p = NSBezierPath(roundedRect: r, xRadius: r.width * 0.14, yRadius: r.width * 0.14)
        NSColor.white.withAlphaComponent(alpha).setFill(); p.fill()
    }
    let cw = rect.width * 0.36, ch = rect.width * 0.46
    card(NSRect(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.30, width: cw, height: ch), alpha: 0.35)
    card(NSRect(x: rect.minX + rect.width * 0.46, y: rect.minY + rect.height * 0.22, width: cw * 0.82, height: ch * 0.82), alpha: 0.95)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.2, weight: .bold)
    if let sym = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
        let sz = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - sz.width * 0.62, y: rect.minY + rect.height * 0.70, width: sz.width * 0.75, height: sz.height * 0.75))
    }
    let cfg2 = NSImage.SymbolConfiguration(pointSize: s * 0.13, weight: .heavy)
    if let sym = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(cfg2) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor(srgbRed: 0.93, green: 0.22, blue: 0.47, alpha: 1).set(); r.fill(using: .sourceAtop); return true }
        let sz = tinted.size
        let c = NSRect(x: rect.minX + rect.width * 0.46, y: rect.minY + rect.height * 0.22, width: cw * 0.82, height: ch * 0.82)
        tinted.draw(in: NSRect(x: c.midX - sz.width / 2, y: c.midY - sz.height / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png"
        try! render(pt * sc).write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
        images.append(["size": "\(pt)x\(pt)", "idiom": "mac", "filename": name, "scale": "\(sc)x"])
    }
}
let json: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: URL(fileURLWithPath: out).appendingPathComponent("Contents.json"))
