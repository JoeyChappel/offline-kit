import AppKit
import Foundation

// Builds the Apple TV app icon (a three-layer parallax stack) and Top Shelf images
// from the same compass layers as the Mac and iPhone icons.
// Usage: swift Tools/export-tv-icon.swift <repo OfflineKitApp folder>
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let layers = root.appending(path: "Design/IconComposer/Compass")
let brand = root.appending(path: "Sources/TV/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
let fm = FileManager.default

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: layers.appending(path: name)) else { fatalError("Missing \(name)") }
    return image
}
let background = load("00-background.png")
let book = load("01-book.png")
let marks = load("02-direction-marks.png")
let needle = load("03-needle-and-pivot.png")

func render(_ w: Int, _ h: Int, opaque: Bool, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.set(); NSRect(x: 0, y: 0, width: w, height: h).fill(using: .copy)
    draw(NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    guard opaque else { return rep }
    // The back layer and Top Shelf images must have no alpha channel.
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
    return NSBitmapImageRep(cgImage: context.makeImage()!)
}

/// The 1024 artwork square, centered. The book fills about 60% of the icon's height,
/// leaving room for the parallax crop at the edges.
func artRect(in bounds: NSRect, scale: CGFloat = 1.1, centerX: CGFloat? = nil) -> NSRect {
    let side = bounds.height * scale
    let x = (centerX ?? bounds.midX) - side / 2
    return NSRect(x: x, y: bounds.midY - side / 2, width: side, height: side)
}

func write(_ rep: NSBitmapImageRep, _ folder: URL, _ name: String) throws {
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appending(path: name))
}

func json(_ object: Any, _ folder: URL) throws {
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: folder.appending(path: "Contents.json"))
}
let info = ["author": "xcode", "version": 1] as [String: Any]

// MARK: App icon stacks

func stack(_ name: String, width: Int, height: Int, scales: [Int]) throws {
    let folder = brand.appending(path: "\(name).imagestack")
    let parts: [(String, Bool, (NSRect) -> Void)] = [
        ("Front", false, { r in marks.draw(in: artRect(in: r)); needle.draw(in: artRect(in: r)) }),
        ("Middle", false, { r in book.draw(in: artRect(in: r)) }),
        ("Back", true, { r in background.draw(in: r) }),
    ]
    for (layer, opaque, draw) in parts {
        let set = folder.appending(path: "\(layer).imagestacklayer/Content.imageset")
        var images: [[String: Any]] = []
        for scale in scales {
            let file = "\(layer.lowercased())@\(scale)x.png"
            try write(render(width * scale, height * scale, opaque: opaque, draw), set, file)
            images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
        }
        try json(["images": images, "info": info], set)
        try json(["info": info], folder.appending(path: "\(layer).imagestacklayer"))
    }
    try json(["info": info, "layers": parts.map { ["filename": "\($0.0).imagestacklayer"] }], folder)
}

try? fm.removeItem(at: brand)
try stack("App Icon", width: 400, height: 240, scales: [1, 2])
try stack("App Icon - App Store", width: 1280, height: 768, scales: [1])

// MARK: Top Shelf

func topShelf(_ name: String, width: Int) throws {
    let set = brand.appending(path: "\(name).imageset")
    var images: [[String: Any]] = []
    for scale in [1, 2] {
        let rep = render(width * scale, 720 * scale, opaque: true) { r in
            background.draw(in: r)
            let s = CGFloat(scale)
            let art = artRect(in: r, scale: 0.95, centerX: r.width * 0.30)
            for layer in [book, marks, needle] { layer.draw(in: art) }
            let ink = NSColor(srgbRed: 0.96, green: 0.93, blue: 0.85, alpha: 1)
            let title = NSAttributedString(string: "Offline Kit", attributes: [
                .font: NSFont.systemFont(ofSize: 96 * s, weight: .bold), .foregroundColor: ink])
            let tagline = NSAttributedString(string: "Movies and audiobooks from your Mac", attributes: [
                .font: NSFont.systemFont(ofSize: 40 * s, weight: .medium), .foregroundColor: ink.withAlphaComponent(0.75)])
            let x = art.maxX + 40 * s
            title.draw(at: NSPoint(x: x, y: r.midY + 4 * s))
            tagline.draw(at: NSPoint(x: x + 4 * s, y: r.midY - 56 * s))
        }
        let file = "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))@\(scale)x.png"
        try write(rep, set, file)
        images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
    }
    try json(["images": images, "info": info], set)
}

try topShelf("Top Shelf Image", width: 1920)
try topShelf("Top Shelf Image Wide", width: 2320)

try json(["assets": [
    ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
], "info": info], brand)
try json(["info": info], brand.deletingLastPathComponent())
print("Wrote \(brand.path)")
