// Draws Stow's app icon: a menu bar strip with its icons on the right and,
// past a thin divider and Stow's arrow, the ones tucked away fading out to
// the left. On the cream squircle the Harbor apps share.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-out")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

func draw(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // Body.
    let body = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.22))
    cg.addPath(body)
    cg.setFillColor(color(0xf6e7d6))
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(body)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xfdf3e8), color(0xf1dfc8)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The menu bar strip.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x3a2a1c, 0.25))
    cg.addPath(rounded(CGRect(x: 170, y: 437, width: 684, height: 150), 75))
    cg.setFillColor(color(0x231f1c))
    cg.fillPath()
    cg.restoreGState()

    // Icons in view, right of the arrow.
    cg.setFillColor(color(0xfffbf6))
    for x: CGFloat in [628, 708, 788] {
        cg.fillEllipse(in: CGRect(x: x - 24, y: 488, width: 48, height: 48))
    }
    // Stow's arrow, in harbour teal.
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 548, y: 546))
    arrow.addLine(to: CGPoint(x: 520, y: 512))
    arrow.addLine(to: CGPoint(x: 548, y: 478))
    cg.addPath(arrow)
    cg.setStrokeColor(color(0x6cc3cf))
    cg.setLineWidth(22)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.strokePath()
    // The divider.
    cg.setFillColor(color(0xfffbf6, 0.35))
    cg.addPath(rounded(CGRect(x: 462, y: 474, width: 10, height: 76), 5))
    cg.fillPath()
    // Icons tucked away, fading toward the edge.
    for (x, alpha) in [(CGFloat(392), CGFloat(0.42)), (312, 0.26), (232, 0.14)] {
        cg.setFillColor(color(0xfffbf6, alpha))
        cg.fillEllipse(in: CGRect(x: x - 24, y: 488, width: 48, height: 48))
    }
    cg.restoreGState()

    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = out.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)@\(scale)x.png"
        try! draw(size: base * scale).write(to: iconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
try! draw(size: 512).write(to: out.appendingPathComponent("icon.png"))
try! draw(size: 180).write(to: out.appendingPathComponent("apple-touch-icon.png"))
try! draw(size: 64).write(to: out.appendingPathComponent("favicon.png"))
print("wrote \(out.path)")
