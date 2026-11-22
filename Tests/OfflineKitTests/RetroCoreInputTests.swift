import CoreGraphics
import Foundation
import Testing

/// Button codes from outside the app (the browser player sends a byte per button) reach RetroCore as open NS_ENUM values,
/// so anything from 0 to 255 arrives. Out-of-range codes must press nothing. Before the bounds check, `1u << code` was
/// undefined behaviour (the Undefined Behavior Sanitizer reported it) and on arm64 wrapped: code 200 pressed A.
///
/// Runs the real NES core (fceumm, from Vendor/Cores) on Tools/Tests/make-test-nes.py's test pattern, where holding A
/// turns the background red.
@Suite("RetroCore input bounds", .serialized)
struct RetroCoreInputTests {
    final class FrameBox: @unchecked Sendable { var image: CGImage? }

    /// Only one core can be loaded at a time (the title-capture tests use one too), so wait for it to be free.
    func loadCore(_ dir: TempDir) throws -> RetroCore {
        let deadline = Date().addingTimeInterval(20)
        while true {
            if let core = try? RetroCore(libraryPath: GameTitleCaptureTests.corePath, options: nil,
                                         systemDirectory: dir.url.path, saveDirectory: dir.url.path) { return core }
            try #require(Date() < deadline, "the emulator core stayed busy")
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Share of the picture that is the red background.
    func redShare(_ image: CGImage?) throws -> Double {
        let image = try #require(image)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        var red = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i] > 120 && pixels[i + 1] < 90 && pixels[i + 2] < 90 {
            red += 1
        }
        return Double(red) / Double(width * height)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: GameTitleCaptureTests.corePath)))
    func outOfRangeButtonsPressNothing() throws {
        let dir = try TempDir()
        let rom = dir.url.appending(path: "Test Pattern.nes")
        try FileManager.default.copyItem(at: try TestSupport.fixture("Test Pattern.nes"), to: rom)
        let core = try loadCore(dir)
        defer { core.unloadGame() }
        try core.loadGame(atPath: rom.path, systemDirectory: dir.url.path, saveDirectory: dir.url.path)
        let box = FrameBox()
        core.frameHandler = { box.image = $0 }
        func run(_ frames: Int) { for _ in 0..<frames { core.runFrame() } }

        run(30)
        #expect(try redShare(box.image) < 0.05, "no button held yet")

        // 200, 40 and 72 are 8 (A) modulo 32; -1 and 16 are outside the 16 joypad buttons.
        for code in [200, 40, 72, -1, 16, 255] {
            let button = try #require(RetroButton(rawValue: code))
            core.setButton(button, pressed: true)
            core.setButton(button, pressed: true, port: 1)
        }
        for code in [3, 32, 200] { core.setMouseButton(try #require(RetroMouseButton(rawValue: code)), pressed: true) }
        run(10)
        #expect(try redShare(box.image) < 0.05, "a stray button code pressed A")

        core.setButton(.A, pressed: true)
        run(10)
        #expect(try redShare(box.image) > 0.3, "A itself turns the background red")
    }
}
