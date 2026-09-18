// ChatBotsCoreTests — BMP and TIFF are converted, not sent as undocumented types
//
// The magic-byte sniffer recognised BMP and TIFF and the intake path sent them as `image/bmp`
// and `image/tiff`. The API documentation for the intake lane lists png, jpeg, webp and gif, so
// those attachments were likely rejected. This is that defect in the other direction: the earlier
// work fixed a type the app offered but did not send; this was a type the app sent but the API may
// not take.
//
// The judgement is the same one: convert what can be converted rather than send an undocumented type
// or refuse a common one. BMP and TIFF are both common (macOS writes TIFF, other systems
// produce BMP) and ImageIO reads both, so intake re-encodes them as PNG or JPEG and the sniffer
// no longer names them at all. These tests build real files with ImageIO rather than fixtures.

import ChatBotsCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

private enum WireImageError: Error {
    case cannotWrite(String)
}

/// A real image file in `type`, written by ImageIO, returned as bytes.
private func writeWireImage(
    as type: UTType, width: Int, height: Int, to url: URL
) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil),
        let image = context.makeImage()
    else { throw WireImageError.cannotWrite(type.identifier) }

    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw WireImageError.cannotWrite(type.identifier)
    }
    return try Data(contentsOf: url)
}

private func wireImageDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "chatbots-wire-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A real 1×1 PNG, for the pass-through check.
private let realPNG: Data = {
    guard
        let data = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )
    else {
        Issue.record("the fixture PNG is not valid base64")
        return Data()
    }
    return data
}()

@Suite("BMP and TIFF are converted, not sent as undocumented types")
struct ClientsImageTests {

    /// The premise, so a failure elsewhere is unambiguous: these are the four types the API
    /// documents, and the list is short on purpose.
    @Test("The accepted list is exactly the documented types")
    func acceptedListIsDocumentedTypes() {
        #expect(
            AttachedDocument.acceptedImageMediaTypes == [
                "image/png", "image/jpeg", "image/webp", "image/gif",
            ])
        #expect(!AttachedDocument.acceptedImageMediaTypes.contains("image/bmp"))
        #expect(!AttachedDocument.acceptedImageMediaTypes.contains("image/tiff"))
    }

    /// The sniffer and the sender share one list, so nothing the sniffer can name is a type the
    /// request may not carry. This is the assertion that keeps the two from drifting: adding a
    /// branch to `mediaType(of:)` that is not in the accepted set fails here.
    @Test("Every type the sniffer can return is one the API accepts")
    func snifferOnlyReturnsAcceptedTypes() {
        let samples: [(String, Data)] = [
            ("png", realPNG),
            ("jpeg", Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])),
            ("gif", Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
            ("webp", Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
        ]
        for (name, bytes) in samples {
            let type = AttachedDocument.mediaType(of: bytes)
            #expect(type != nil, "\(name) should still be recognised")
            if let type {
                #expect(
                    AttachedDocument.acceptedImageMediaTypes.contains(type),
                    "\(name) sniffed as \(type), which the API does not document")
            }
        }
    }

    /// The picker deliberately offers more than the API takes: those extra formats are the ones
    /// intake converts. If any of these left the picker, the conversion path would be dead for
    /// the formats these tests are about.
    @Test("The picker still offers the formats intake converts")
    func pickerOffersConvertibleFormats() {
        for ext in ["bmp", "tiff", "tif", "heic"] {
            #expect(
                DocumentKind.imageExtensions.contains(ext),
                "\(ext) is convertible but no longer offered")
        }
    }

    /// The defect itself: pre-fix the stored bytes sniffed as `image/bmp` and went on the wire.
    @Test("A BMP is converted to a type the API accepts")
    func bmpIsConverted() throws {
        let directory = try wireImageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "screenshot.bmp")
        let original = try writeWireImage(as: .bmp, width: 8, height: 4, to: url)
        #expect(AttachedDocument.mediaType(of: original) == nil)

        let document = try SystemDocumentExtractor.ingestor.add(url: url)

        #expect(document.kind == .image)
        let converted = try #require(document.imageData)
        #expect(converted != original, "the BMP should have been re-encoded")
        let mediaType = try #require(
            document.imageMediaType,
            "an image with no acceptable media type would be dropped before sending")
        #expect(
            AttachedDocument.acceptedImageMediaTypes.contains(mediaType),
            "converted to \(mediaType), which the API does not document")

        // A real conversion, not a rename: it decodes at the same size.
        let source = try #require(CGImageSourceCreateWithData(converted as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 8 && image.height == 4)
    }

    @Test("A TIFF is converted to a type the API accepts")
    func tiffIsConverted() throws {
        let directory = try wireImageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "scan.tiff")
        let original = try writeWireImage(as: .tiff, width: 6, height: 9, to: url)
        #expect(AttachedDocument.mediaType(of: original) == nil)

        let document = try SystemDocumentExtractor.ingestor.add(url: url)

        let converted = try #require(document.imageData)
        #expect(converted != original, "the TIFF should have been re-encoded")
        let mediaType = try #require(document.imageMediaType)
        #expect(AttachedDocument.acceptedImageMediaTypes.contains(mediaType))

        let source = try #require(CGImageSourceCreateWithData(converted as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 6 && image.height == 9)
    }

    /// A type the API does accept must not be touched, exactly as the earlier rule requires.
    @Test("A PNG is passed through byte-identical")
    func pngIsUntouched() throws {
        let directory = try wireImageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "already.png")
        try realPNG.write(to: url)

        let document = try SystemDocumentExtractor.ingestor.add(url: url)

        #expect(document.imageMediaType == "image/png")
        #expect(document.imageData == realPNG)
    }
}
