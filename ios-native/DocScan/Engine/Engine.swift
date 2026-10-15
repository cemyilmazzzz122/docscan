import CoreGraphics
import Foundation
import ImageIO

/// Output filter (DS_MODE_* in docscan.h).
enum ScanMode: Int32, CaseIterable, Identifiable {
    case color = 0, gray, blackWhite, original

    var id: Self { self }

    var title: String {
        switch self {
        case .color: "Color"
        case .gray: "Gray"
        case .blackWhite: "B&W"
        case .original: "Original"
        }
    }
}

/// A JPEG produced by the engine.
struct EncodedImage: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

struct Detection: Sendable {
    /// Top-left, top-right, bottom-right, bottom-left, in image pixels.
    let corners: [CGPoint]
    let found: Bool
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Swift wrapper around the C API in engine/src/docscan.h.
///
/// Every call is synchronous and CPU heavy; run them off the main actor.
enum Engine {
    /// Longest side kept from the camera; plenty for a 300 dpi A4 page.
    static let maxSide: Int32 = 4000

    static var version: String { String(cString: ds_version()) }

    /// Turns any picked file into an upright JPEG the engine can work with.
    static func normalize(_ data: Data) throws -> EncodedImage {
        var out = ds_image()
        let rc = data.withUnsafeBytes { buf in
            ds_normalize(buf.bindMemory(to: UInt8.self).baseAddress, Int32(buf.count), maxSide, &out)
        }
        if rc == 0 { return take(&out) }
        // Formats OpenCV can't read (HEIC and friends): let ImageIO decode, hand over raw pixels.
        guard let image = decodeUpright(data) else { throw lastError() }
        return try normalize(image)
    }

    /// Same as `normalize(_:)` from an already decoded image.
    static func normalize(_ image: CGImage) throws -> EncodedImage {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw EngineError(message: "could not read the image pixels") }
        var out = ds_image()
        let rc = pixels.withUnsafeBufferPointer {
            ds_normalize_rgba($0.baseAddress, Int32(w), Int32(h), maxSide, &out)
        }
        guard rc == 0 else { throw lastError() }
        return take(&out)
    }

    static func detect(_ jpeg: Data) throws -> Detection {
        var c = [Float](repeating: 0, count: 8)
        let rc = jpeg.withUnsafeBytes { buf in
            c.withUnsafeMutableBufferPointer {
                ds_detect(buf.bindMemory(to: UInt8.self).baseAddress, Int32(buf.count), $0.baseAddress)
            }
        }
        guard rc >= 0 else { throw lastError() }
        let corners = (0..<4).map { CGPoint(x: CGFloat(c[2 * $0]), y: CGFloat(c[2 * $0 + 1])) }
        return Detection(corners: corners, found: rc == 1)
    }

    static func process(
        _ jpeg: Data, corners: [CGPoint], mode: ScanMode, straighten: Bool, quarterTurns: Int
    ) throws -> EncodedImage {
        let c = corners.flatMap { [Float($0.x), Float($0.y)] }
        var out = ds_image()
        let rc = jpeg.withUnsafeBytes { buf in
            c.withUnsafeBufferPointer {
                ds_process(
                    buf.bindMemory(to: UInt8.self).baseAddress, Int32(buf.count), $0.baseAddress,
                    mode.rawValue, straighten ? 1 : 0, Int32(quarterTurns), 0, &out)
            }
        }
        guard rc == 0 else { throw lastError() }
        return take(&out)
    }

    private static func take(_ image: inout ds_image) -> EncodedImage {
        defer { ds_free(&image) }
        return EncodedImage(
            data: Data(bytes: image.data, count: Int(image.size)),
            width: Int(image.width), height: Int(image.height))
    }

    private static func lastError() -> EngineError {
        EngineError(message: String(cString: ds_last_error()))
    }

    /// Decodes with ImageIO, applying the EXIF orientation and capping the size at `maxSide`.
    private static func decodeUpright(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
