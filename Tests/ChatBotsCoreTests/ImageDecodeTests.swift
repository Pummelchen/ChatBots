// ChatBotsCoreTests — an image is measured before it is decoded
//
// `wireRepresentation` decoded the whole image and only then looked at its size. The formats that
// reach that path are the ones a model cannot be given as they are — TIFF, BMP, HEIC — and they are
// compressed, so the 64 MB byte cap bounds nothing: a 663 KB TIFF can declare a 6 500 × 6 500 canvas
// that decodes to 127 MB, and the same trick at the byte cap is tens of gigabytes. ImageIO reports the
// dimensions from the file's own metadata before decoding anything, so the cap is checked there.
//
// The fixtures here are real PackBits TIFFs, written by the test rather than checked in, so what is
// refused is a format the app genuinely converts.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("An image is measured before it is decoded")
struct ImageDecodeTests {

    /// One entry in a TIFF image file directory. A named type rather than a four-element tuple, which
    /// swiftlint refuses for good reason.
    private struct IFDEntry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var value: UInt32
    }

    /// A one-strip PackBits TIFF: every row is a run of 128 identical bytes, so the file is ~1 % of the
    /// canvas it declares. This is the shape of the problem — tiny on disk, huge in memory — and it is
    /// a file ImageIO decodes happily, which the test below relies on.
    private func packBitsTIFF(width: Int, height: Int, withStrip: Bool = true) -> Data {
        var row = Data()
        var remaining = width
        while remaining > 0 {
            let block = min(128, remaining)
            row.append(UInt8(257 - block))
            row.append(1)
            remaining -= block
        }
        let pixels = Data((0..<height).flatMap { _ in row })

        let entries: [IFDEntry] = [
            IFDEntry(tag: 256, type: 4, count: 1, value: UInt32(width)),  // ImageWidth
            IFDEntry(tag: 257, type: 4, count: 1, value: UInt32(height)),  // ImageLength
            IFDEntry(tag: 258, type: 3, count: 1, value: 8),  // BitsPerSample
            IFDEntry(tag: 259, type: 3, count: 1, value: 32773),  // Compression = PackBits
            IFDEntry(tag: 262, type: 3, count: 1, value: 1),  // Photometric = BlackIsZero
            IFDEntry(tag: 273, type: 4, count: 1, value: 0),  // StripOffsets, filled in below
            IFDEntry(tag: 277, type: 3, count: 1, value: 1),  // SamplesPerPixel
            IFDEntry(tag: 278, type: 4, count: 1, value: UInt32(height)),  // RowsPerStrip
            IFDEntry(tag: 279, type: 4, count: 1, value: UInt32(pixels.count)),  // StripByteCounts
            IFDEntry(tag: 284, type: 3, count: 1, value: 1),  // PlanarConfiguration
            IFDEntry(tag: 339, type: 3, count: 1, value: 1),  // SampleFormat = unsigned
        ]
        let ifdSize = 2 + entries.count * 12 + 4
        let dataOffset = UInt32(8 + ifdSize)

        var out = Data("II".utf8)
        out.append(contentsOf: [42, 0])
        out.append(contentsOf: withUnsafeBytes(of: UInt32(8).littleEndian) { Array($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt16(entries.count).littleEndian) { Array($0) })
        for entry in entries.sorted(by: { $0.tag < $1.tag }) {
            let value = entry.tag == 273 ? dataOffset : entry.value
            out.append(contentsOf: withUnsafeBytes(of: entry.tag.littleEndian) { Array($0) })
            out.append(contentsOf: withUnsafeBytes(of: entry.type.littleEndian) { Array($0) })
            out.append(contentsOf: withUnsafeBytes(of: entry.count.littleEndian) { Array($0) })
            if entry.type == 3, entry.count == 1 {
                out.append(contentsOf: withUnsafeBytes(of: UInt16(value).littleEndian) { Array($0) })
                out.append(contentsOf: [0, 0])
            } else {
                out.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
            }
        }
        out.append(contentsOf: [0, 0, 0, 0])  // no next IFD
        // The directory still declares the full strip size when the bytes are withheld, which is the
        // damaged-header case: a real format ImageIO recognises and will not measure.
        if withStrip { out.append(pixels) }
        return out
    }

    @Test("An image whose metadata declares too many pixels is refused without being decoded")
    func anOversizedImageIsRefusedBeforeDecoding() throws {
        let data = packBitsTIFF(width: 6_500, height: 6_500)
        // The premise: this is small on disk and far over the cap in canvas.
        #expect(data.count < 1_000_000, "fixture grew: \(data.count) bytes")
        #expect(6_500 * 6_500 > AttachmentLimits.defaultMaximumImagePixels)

        do {
            _ = try ImageExtractor.wireRepresentation(
                of: data, filename: "big.tiff", limits: .standard)
            Issue.record("a 42 MP TIFF was converted")
        } catch let error as DocumentError {
            guard case .imageTooManyPixels(let name, let pixels, let limit) = error else {
                Issue.record("expected the pixel refusal, got \(error)")
                return
            }
            #expect(name == "big.tiff")
            #expect(pixels == 6_500 * 6_500)
            #expect(limit == AttachmentLimits.defaultMaximumImagePixels)
            // The message has to be actionable: what it is, what the limit is, what to do.
            let message = error.errorDescription ?? ""
            #expect(message.contains("megapixels"))
            #expect(message.contains("Resize"))
        }
    }

    @Test("The cap is the caller's, and an image under it is still converted")
    func anImageUnderTheCapIsConverted() throws {
        // A tight cap and a small image, so the boundary is exercised without a large allocation:
        // 20 × 20 is 400 pixels, over a cap of 399 and under a cap of 401.
        let data = packBitsTIFF(width: 20, height: 20)

        #expect(throws: DocumentError.imageTooManyPixels("small.tiff", pixels: 400, limit: 399)) {
            _ = try ImageExtractor.wireRepresentation(
                of: data, filename: "small.tiff",
                limits: AttachmentLimits(maximumImagePixels: 399))
        }

        let converted = try ImageExtractor.wireRepresentation(
            of: data, filename: "small.tiff",
            limits: AttachmentLimits(maximumImagePixels: 401))
        // Converted means a type a model can be given, and not the TIFF it arrived as.
        #expect(AttachedDocument.mediaType(of: converted) != nil)
        #expect(converted.prefix(2) != Data("II".utf8))
    }

    /// A BMP whose header declares a canvas and which carries no pixels.
    ///
    /// ImageIO recognises the format — `CGImageSourceGetType` answers `com.microsoft.bmp` — and reports
    /// no dimensions for it, which is the damaged-header case: the old code's only way to find out was
    /// to decode it.
    private func headerOnlyBMP(width: Int32, height: Int32) -> Data {
        var out = Data("BM".utf8)
        func append(_ value: UInt32) { out.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) }) }
        func append(_ value: Int32) { out.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) }) }
        func append(_ value: UInt16) { out.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) }) }
        append(UInt32(54))  // file size
        append(UInt32(0))
        append(UInt32(54))  // pixel data offset
        append(UInt32(40))  // DIB header size
        append(width)
        append(height)
        append(UInt16(1))  // planes
        append(UInt16(24))  // bits per pixel
        append(UInt32(0))  // no compression
        append(UInt32(0))  // image size, which would be the pixel bytes
        append(Int32(2835))
        append(Int32(2835))
        append(UInt32(0))
        append(UInt32(0))
        return out
    }

    @Test("An image that will not report its dimensions is refused rather than decoded blind")
    func anUnmeasurableImageIsRefused() throws {
        let truncated = headerOnlyBMP(width: 8_000, height: 6_000)

        do {
            _ = try ImageExtractor.wireRepresentation(
                of: truncated, filename: "broken.bmp", limits: .standard)
            Issue.record("an unmeasurable BMP was converted")
        } catch let error as DocumentError {
            guard case .unreadable(let reason) = error else {
                Issue.record("expected a refusal naming the reason, got \(error)")
                return
            }
            #expect(reason.contains("dimensions"))
        }
    }

    @Test("A file that is not an image at all is refused as that, not as an unmeasurable image")
    func aFileThatIsNotAnImageIsNamedAsSuch() throws {
        // The two refusals are different sentences because they are different problems: this is the
        // file somebody's picker offered because of its extension.
        let junk = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        do {
            _ = try ImageExtractor.wireRepresentation(
                of: junk, filename: "not-really.heic", limits: .standard)
            Issue.record("a file that is not an image was converted")
        } catch let error as DocumentError {
            guard case .unreadable(let reason) = error else {
                Issue.record("expected a refusal naming the reason, got \(error)")
                return
            }
            #expect(reason.contains("not an image format"))
        }
    }
}
