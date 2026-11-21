import AppKit
import Foundation

// Packaging only: normalize the generated artwork and separate disconnected compass
// elements into registered, full-size PNGs. The same layer stack makes the app icon.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let bookInput = URL(fileURLWithPath: CommandLine.arguments[2])
let compassInput = URL(fileURLWithPath: CommandLine.arguments[3])
let output = root.appending(path: "Design/IconComposer/Compass", directoryHint: .isDirectory)
let fm = FileManager.default
try fm.createDirectory(at: output, withIntermediateDirectories: true)
let size = 1024

func bitmap(_ size: Int = 1024) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bitmapFormat: [],
                     bytesPerRow: size * 4, bitsPerPixel: 32)!
}

func render(_ size: Int = 1024, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = bitmap(size)
    memset(rep.bitmapData!, 0, rep.bytesPerRow * size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func opaque(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let rgb = NSBitmapImageRep(cgImage: context.makeImage()!)
    precondition(!rgb.hasAlpha)
    let center = rgb.colorAt(x: 512, y: 500)!.usingColorSpace(.sRGB)!
    precondition(center.redComponent + center.greenComponent + center.blueComponent > 0.5, "Opaque export must preserve visible artwork")
    return rgb
}

func normalized(_ url: URL) throws -> NSBitmapImageRep {
    guard let image = NSImage(contentsOf: url) else { throw NSError(domain: "Icon", code: 1) }
    return render { image.draw(in: NSRect(x: 0, y: 0, width: size, height: size)) }
}

func image(_ rep: NSBitmapImageRep) -> NSImage { NSImage(cgImage: rep.cgImage!, size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)) }

struct Component {
    var pixels: [Int]
    var minX: Int, maxX: Int, minY: Int, maxY: Int
    var count: Int { pixels.count }
}

func components(_ rep: NSBitmapImageRep) -> [Component] {
    let data = rep.bitmapData!, w = rep.pixelsWide, h = rep.pixelsHigh
    var seen = [Bool](repeating: false, count: w * h), result: [Component] = []
    for start in 0..<(w * h) where !seen[start] && data[start * 4 + 3] > 24 {
        var queue = [start], head = 0
        seen[start] = true
        var c = Component(pixels: [], minX: start % w, maxX: start % w, minY: start / w, maxY: start / w)
        while head < queue.count {
            let point = queue[head]; head += 1
            let x = point % w, y = point / w
            c.pixels.append(point)
            c.minX = min(c.minX, x); c.maxX = max(c.maxX, x)
            c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
            for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let next = ny * w + nx
                if !seen[next] && data[next * 4 + 3] > 24 { seen[next] = true; queue.append(next) }
            }
        }
        result.append(c)
    }
    return result.sorted { $0.count > $1.count }
}

let book = try normalized(bookInput)
let overlay = try normalized(compassInput)
let parts = components(overlay).filter { $0.count > 120 }
guard parts.count == 5 else { fatalError("Expected a needle/pivot and four direction marks, found \(parts.count)") }
let needle = bitmap(), marks = bitmap()
memset(needle.bitmapData!, 0, needle.bytesPerRow * size)
memset(marks.bitmapData!, 0, marks.bytesPerRow * size)
for (index, part) in parts.enumerated() {
    let target = index == 0 ? needle : marks
    // Rectangular alpha-preserving extraction includes the antialias fringe.
    for y in max(0, part.minY - 2)...min(size - 1, part.maxY + 2) {
        for x in max(0, part.minX - 2)...min(size - 1, part.maxX + 2) {
            let offset = (y * size + x) * 4
            for channel in 0..<4 { target.bitmapData![offset + channel] = overlay.bitmapData![offset + channel] }
        }
    }
}

let background = render {
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.035, green: 0.24, blue: 0.14, alpha: 1),
                              ending: NSColor(srgbRed: 0.014, green: 0.13, blue: 0.075, alpha: 1))!
    gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -55)
}
let foreground = render {
    for rep in [book, marks, needle] { image(rep).draw(in: NSRect(x: 0, y: 0, width: size, height: size)) }
}
let composite = render {
    image(background).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    image(foreground).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
}

for (name, rep) in [("00-background.png",background),("01-book.png",book),("02-direction-marks.png",marks),
                     ("03-needle-and-pivot.png",needle),("foreground-combined.png",foreground),("preview.png",composite)] {
    try write(rep, output.appending(path: name))
}

let assets = root.appending(path: "Resources/Assets.xcassets")
let appIcon = assets.appending(path: "AppIcon.appiconset")
try write(opaque(composite), appIcon.appending(path: "ios-1024.png"))
let macMaster = render {
    let inset = NSRect(x: 56, y: 56, width: 912, height: 912)
    NSBezierPath(roundedRect: inset, xRadius: 202, yRadius: 202).addClip()
    image(composite).draw(in: inset)
}
for pointSize in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = pointSize * scale
        let small = render(pixels) { image(macMaster).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)) }
        try write(small, appIcon.appending(path: "mac-\(pointSize)@\(scale)x.png"))
    }
}
let markAssets = assets.appending(path: "KitIcon.imageset", directoryHint: .isDirectory)
try fm.createDirectory(at: markAssets, withIntermediateDirectories: true)
try write(composite, markAssets.appending(path: "compass.png"))
let contents = """
{"images":[{"filename":"compass.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}
"""
try contents.write(to: markAssets.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

var validation: [[String: Any]] = []
for (name, rep) in [("01-book.png",book),("02-direction-marks.png",marks),("03-needle-and-pivot.png",needle)] {
    var transparent = 0, visible = 0
    for i in 0..<(size * size) {
        let alpha = rep.bitmapData![i * 4 + 3]
        if alpha == 0 { transparent += 1 }
        if alpha > 24 { visible += 1 }
    }
    guard transparent > size * size / 2, visible > 100 else { fatalError("Invalid layer alpha: \(name)") }
    validation.append(["file":name,"width":size,"height":size,"hasAlpha":true,"transparentPixels":transparent,"visiblePixels":visible])
}
let report: [String: Any] = ["layers":validation,"compassComponents":parts.count,"canvas":"1024 × 1024, sRGB, RGBA", "registration":"All layers share the same origin. Stack without cropping or repositioning."]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output.appending(path: "validation.json"))
print("Exported three registered 1024×1024 transparent layers, background, preview, and Mac/iOS app icons.")
