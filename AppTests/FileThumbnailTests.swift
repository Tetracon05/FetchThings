import AppKit
import Foundation
import Testing
@testable import Downloader

@Suite("File previews")
@MainActor
struct FileThumbnailTests {
    private let box = CGSize(width: 120, height: 90)

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileThumbnailTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writePNG(to url: URL, width: Int = 200, height: Int = 100) throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    @Test func aPictureGetsAPreviewOfItsContents() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.png")
        try writePNG(to: file)

        #expect(FileThumbnails.cached(file, size: box) == nil)
        let image = await FileThumbnails.load(file, size: box)
        #expect(image != nil)
        // Asking again is answered from memory.
        #expect(FileThumbnails.cached(file, size: box) != nil)
    }

    @Test func aFileWithoutAPreviewGivesNilSoTheIconStaysInPlace() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("blob.bin")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: file)

        #expect(await FileThumbnails.load(file, size: box) == nil)
        #expect(await FileThumbnails.load(folder.appendingPathComponent("missing.png"), size: box) == nil)
    }

    @Test func aFileReplacedAtTheSamePathDoesNotShowTheOldPreview() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.png")
        try writePNG(to: file)
        _ = await FileThumbnails.load(file, size: box)
        #expect(FileThumbnails.cached(file, size: box) != nil)

        // Remove it and download another file under the same name, a minute later.
        try FileManager.default.removeItem(at: file)
        try writePNG(to: file, width: 100, height: 200)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        #expect(FileThumbnails.cached(file, size: box) == nil)
    }
}
