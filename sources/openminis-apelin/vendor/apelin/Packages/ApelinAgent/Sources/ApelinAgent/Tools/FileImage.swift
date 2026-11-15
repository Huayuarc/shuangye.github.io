import CoreGraphics
import Foundation
import ImageIO

/// An image file as file_read shows it to the model: one frame, scaled to
/// at most `maxPixelSize` on its longer side and encoded again — PNG when
/// it has transparency, JPEG otherwise — so no provider is sent HEIC, WebP,
/// TIFF or BMP, an animation, or the file's metadata. What a file is comes
/// from its bytes, never its name: an attachment is saved without one.
struct FileImage: Sendable {
    /// The first line of the result: what the file is and what is shown.
    let summary: String
    let data: Data
    let mimeType: String

    /// The longer side sent, as kwwk's own image normalizer and Anthropic's
    /// guidance have it.
    static let maxPixelSize = 1568
    /// The most a picture may be: base64 makes it a third larger, which
    /// keeps it under the 5 MB a provider takes.
    static let maxBytes = 3 * 1024 * 1024
    /// The most pixels a frame may have: PNG, GIF and the rest are decoded
    /// whole before they are scaled, at four bytes a pixel or more, and a
    /// few kilobytes of PNG can claim this many.
    static let maxSourcePixels = 64 * 1024 * 1024
    /// How much of a file `format(of:)` needs to see.
    static let sniffedBytes = 4096

    /// The formats shown as pictures, by ImageIO's type identifier.
    static let formats: [String: String] = [
        "public.png": "PNG",
        "public.jpeg": "JPEG",
        "com.compuserve.gif": "GIF",
        "public.heic": "HEIC",
        "public.heif": "HEIF",
        "org.webmproject.webp": "WebP",
        "public.tiff": "TIFF",
        "com.microsoft.bmp": "BMP",
    ]

    /// The format of a file whose first bytes are `head`, when it is one
    /// shown as a picture.
    static func format(of head: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(head as CFData, nil),
              let type = CGImageSourceGetType(source)
        else { return nil }
        return formats[type as String]
    }

    /// Frame `frame` of the image `data` (its primary image when nil), or
    /// nil when ImageIO cannot decode it, which may be a text file that
    /// begins as an image does. `name` is the file's, for the summary and
    /// the refusals.
    static func read(_ data: Data, frame: Int?, name: String) throws -> FileImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let type = CGImageSourceGetType(source),
              let format = formats[type as String]
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let index = frame ?? CGImageSourceGetPrimaryImageIndex(source)
        guard (0 ..< count).contains(index) else {
            throw ToolArgumentError(count == 1
                ? "\(name) has one frame; leave frame out"
                : "frame must be 0 to \(count - 1): \(name) has \(count) frames")
        }
        guard let facts = facts(source, index), facts.width > 0, facts.height > 0 else { return nil }
        // Divided, so no size a header claims overflows.
        guard facts.width <= maxSourcePixels / facts.height else {
            throw ToolArgumentError(
                "\(name) is a \(facts.width)×\(facts.height) \(format) image, over the \(maxSourcePixels >> 20)-megapixel limit",
            )
        }
        // Smaller until it fits: a detailed picture with transparency stays
        // PNG, which can be larger than the limit at full size.
        for side in [maxPixelSize, 1024, 512] {
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let picture = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { return nil }
            guard let encoded = encode(picture, transparent: facts.transparent) else {
                throw ToolArgumentError("\(name) is a \(format) image that could not be encoded to be shown")
            }
            guard encoded.data.count <= maxBytes else { continue }
            var summary = "Read image \(name): \(format), \(facts.width)×\(facts.height)"
            if count > 1 {
                summary += ", frame \(index) of \(count) (frame 0 to \(count - 1) picks another)"
            }
            summary += "; shown as a \(picture.width)×\(picture.height) \(encoded.name)."
            return FileImage(summary: summary, data: encoded.data, mimeType: encoded.mimeType)
        }
        throw ToolArgumentError("\(name) is a \(format) image too detailed to show in \(maxBytes) bytes")
    }

    /// The frame's pixel size as it is meant to be seen — EXIF orientations
    /// 5 to 8 turn it a quarter — and whether it has transparency, which the
    /// file says and a scaled picture does not: ImageIO gives an opaque HEIC
    /// photo an alpha channel when it scales it.
    private static func facts(
        _ source: CGImageSource,
        _ index: Int,
    ) -> (width: Int, height: Int, transparent: Bool)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let transparent = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        return orientation >= 5 ? (height, width, transparent) : (width, height, transparent)
    }

    private static func encode(_ picture: CGImage, transparent: Bool) -> (data: Data, mimeType: String, name: String)? {
        let data = NSMutableData()
        let type = transparent ? "public.png" : "public.jpeg"
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        let properties = transparent ? nil : [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, picture, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return transparent ? (data as Data, "image/png", "PNG") : (data as Data, "image/jpeg", "JPEG")
    }
}
