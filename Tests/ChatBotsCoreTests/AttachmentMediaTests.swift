// ChatBotsCoreTests — an image that reaches intake is an image that can be sent
//
// `imageMediaType` sniffs png/jpeg/gif/bmp/webp/tiff and then returns nil. HEIC — the default
// format of an iPhone photo, and offered in the picker — was not among them, so the bytes were
// stored, `isUsable` passed, the vision gate passed, the chip appeared, and then
// `OpenAIResponsesEngine.setAttachments` dropped it and generation sent text only, with nothing
// logged or shown. The MLX backend reads HEIC with `CIImage`, so the behaviour was
// backend-dependent and invisible.
//
// The fix is to convert at intake: what a model can be given is passed through untouched, what
// ImageIO can decode is re-encoded as PNG or JPEG, and what neither is is refused with its name.
// These tests build a real HEIC with ImageIO rather than shipping a fixture, so the format is
// the one an iPhone actually produces.

import ChatBotsCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

private enum MediaTestError: Error {
    case cannotWriteImage
}

/// A real image file in `type`, written by ImageIO, returned as bytes.
private func writeImage(
    as type: UTType, width: Int, height: Int, orientation: Int? = nil, to url: URL
) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)
    else { throw MediaTestError.cannotWriteImage }

    context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { throw MediaTestError.cannotWriteImage }

    var properties: [CFString: Any] = [:]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw MediaTestError.cannotWriteImage }
    return try Data(contentsOf: url)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "chatbots-media-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A real 1×1 PNG, for the pass-through case.
private let pngBytes = Data(
    base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!

@Suite("An image intake can convert", .serialized)
struct ImageMediaTests {

    /// The premise, so the rest of the file is clear: HEIC's magic bytes are not a type the
    /// sniffer knows, which is exactly why the conversion has to happen at intake.
    @Test("The bytes sniffer does not recognise HEIC")
    func heicMagicBytesAreUnknown() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heic = try writeImage(
            as: .heic, width: 6, height: 4, to: directory.appending(path: "photo.heic"))
        #expect(AttachedDocument.mediaType(of: heic) == nil)
    }

    @Test("A HEIC photo is converted to a format the API accepts")
    func heicIsConverted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "photo.heic")
        let original = try writeImage(as: .heic, width: 6, height: 4, to: url)

        let document = try SystemDocumentExtractor.ingestor.add(url: url)

        #expect(document.kind == .image)
        #expect(document.isUsable, "a converted image is still a usable attachment")
        let converted = try #require(document.imageData)
        #expect(converted != original, "the HEIC bytes should have been re-encoded")
        let mediaType = try #require(
            document.imageMediaType,
            "an image that cannot be described to the API must not reach it as one")
        #expect(
            ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mediaType),
            "converted to \(mediaType), which the Responses API does not accept")

        // The conversion is a real image, not a renamed copy: it decodes at the same size.
        let source = try #require(CGImageSourceCreateWithData(converted as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 6)
        #expect(image.height == 4)
    }

    /// An iPhone stores a portrait photo landscape with an EXIF orientation. Orientation lives
    /// in metadata, not in the pixels, and `CGImageSourceCreateImageAtIndex` does not apply it,
    /// so a conversion that just re-encoded the decoded image would hand the model a sideways
    /// picture — a regression introduced by fixing the silent drop. The conversion decodes
    /// through the transforming path instead, and this is the assertion that says so: 6x4
    /// tagged "rotate 90 degrees" has to come out 4x6.
    @Test("A photo's EXIF orientation is applied by the conversion")
    func orientationIsApplied() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "portrait.heic")
        _ = try writeImage(as: .heic, width: 6, height: 4, orientation: 6, to: url)

        let document = try SystemDocumentExtractor.ingestor.add(url: url)
        let converted = try #require(document.imageData)
        let source = try #require(CGImageSourceCreateWithData(converted as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        #expect(
            image.width == 4 && image.height == 6,
            "got \(image.width)x\(image.height); the orientation tag was dropped")
    }

    @Test("An image already in a supported format is passed through untouched")
    func supportedFormatIsUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "already.png")
        try pngBytes.write(to: url)

        let document = try SystemDocumentExtractor.ingestor.add(url: url)

        #expect(document.imageMediaType == "image/png")
        #expect(document.imageData == pngBytes, "a supported image must not be re-encoded")
    }

    /// The other half of the finding: it must stop being silent. A file the picker offers
    /// because of its extension but that is not an image at all is refused with its name, at
    /// intake, where the moderator sees it — not stored and then dropped by one backend.
    @Test("An image that cannot be decoded is refused with its name")
    func undecodableImageIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "not-really.heic")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]).write(to: url)

        do {
            _ = try SystemDocumentExtractor.ingestor.add(url: url)
            Issue.record("a file that is not an image should have been refused")
        } catch let error as DocumentError {
            let reason = error.errorDescription ?? ""
            #expect(reason.contains("not-really.heic"), "the refusal must name the file")
            #expect(reason.contains("could not be converted") || reason.contains("not an image"))
        }
    }
}
