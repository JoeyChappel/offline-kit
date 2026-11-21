import AppKit
import Foundation

// Native layout over the approved, bundled forest photograph. Finder supplies the actual files and labels.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = root.appending(path: "Tools/Release/Artwork", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let logical = NSSize(width: 720, height: 560)
guard let forest = NSImage(contentsOf: root.appending(path: "Resources/watch-forest.jpg")) else { fatalError("Forest asset missing") }
let ink = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.88, alpha: 1)
let sage = NSColor(srgbRed: 0.70, green: 0.82, blue: 0.56, alpha: 1)
func text(_ string: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor = ink) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]
    (string as NSString).draw(in: NSRect(x: 36, y: logical.height - top - size * 1.5, width: logical.width - 72, height: size * 1.5), withAttributes: attributes)
}
// One resolution only: Finder on macOS 26 shows a two-resolution (Retina) background zoomed to twice its size.
for scale in [1] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(logical.width) * scale, pixelsHigh: Int(logical.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = logical
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(scale)); transform.concat()
    NSColor(srgbRed: 0.045, green: 0.105, blue: 0.085, alpha: 1).setFill()
    NSRect(origin: .zero, size: logical).fill()
    // Crop from the left so the forest keeps its recognisable conifer silhouettes.
    let factor = max(logical.width / forest.size.width, logical.height / forest.size.height)
    forest.draw(in: NSRect(x: 0, y: 0, width: forest.size.width * factor, height: forest.size.height * factor))
    NSColor(srgbRed: 0.045, green: 0.105, blue: 0.085, alpha: 0.18).setFill()
    NSRect(origin: .zero, size: logical).fill()
    text("Make yourself at home.", top: 45, size: 31, weight: .bold)
    text("Drag Offline Kit to Applications.", top: 91, size: 19, weight: .regular)
    // The main file icons sit at (180, 225) and (540, 225), in Finder's top-origin coordinates.
    sage.setStroke()
    let arrow = NSBezierPath(); arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 286, y: 335)); arrow.curve(to: NSPoint(x: 434, y: 335), controlPoint1: NSPoint(x: 335, y: 354), controlPoint2: NSPoint(x: 387, y: 354)); arrow.stroke()
    let tip = NSBezierPath(); tip.move(to: NSPoint(x: 417, y: 354)); tip.line(to: NSPoint(x: 437, y: 335)); tip.line(to: NSPoint(x: 411, y: 329)); tip.lineWidth = 3; tip.lineCapStyle = .round; tip.lineJoinStyle = .round; tip.stroke()
    // Finder draws icon labels in black over a background picture, in Dark mode too, so each label gets a soft
    // light plate behind it. Labels sit about 75 points below their icon's center (Finder's top-origin points).
    let plate = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.88, alpha: 0.9)
    plate.setFill()
    for (centerX, labelY, width) in [(CGFloat(180), CGFloat(300), CGFloat(116)), (540, 300, 128), (360, 470, 108)] {
        NSBezierPath(roundedRect: NSRect(x: centerX - width / 2, y: logical.height - labelY - 12, width: width, height: 24),
                     xRadius: 12, yRadius: 12).fill()
    }
    text("When copying finishes, open Offline Kit from Applications.", top: 496, size: 14, weight: .regular)
    text("Apple silicon · macOS 26+", top: 527, size: 12, weight: .regular, color: NSColor(srgbRed: 0.79, green: 0.84, blue: 0.75, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: "forest-install.png"))
}
print("Rendered the 720×560 installer art. Icons and labels are real Finder items, not painted into the art.")
