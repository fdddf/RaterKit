import Foundation
import UIKit

/// A screenshot ready to upload, already compressed.
public struct Attachment: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The compressed JPEG bytes.
    public let data: Data
    public let contentType: String
    /// Thumbnail, used only for the form's preview.
    public let thumbnail: Data?

    public var byteCount: Int { data.count }

    init(id: UUID = UUID(), data: Data, contentType: String, thumbnail: Data?) {
        self.id = id
        self.data = data
        self.contentType = contentType
        self.thumbnail = thumbnail
    }

    /// Compresses an image down to something worth uploading.
    ///
    /// Screenshots picked from the library are routinely several megabytes — slow to
    /// send and liable to hit the server's 5 MB cap. Downscaling the long edge to
    /// `maxDimension` and re-encoding as JPEG puts a typical iPhone screenshot at
    /// 200–400 KB.
    public static func make(
        from image: UIImage,
        maxDimension: CGFloat = 1600,
        quality: CGFloat = 0.7
    ) throws -> Attachment {
        let resized = image.rater_resized(maxDimension: maxDimension)
        guard let data = resized.jpegData(compressionQuality: quality) else {
            throw RaterError.attachmentEncodingFailed
        }
        let thumb = image.rater_resized(maxDimension: 240).jpegData(compressionQuality: 0.6)
        return Attachment(data: data, contentType: "image/jpeg", thumbnail: thumb)
    }

    /// Builds one from the raw data the photo picker hands back.
    public static func make(
        fromImageData imageData: Data,
        maxDimension: CGFloat = 1600,
        quality: CGFloat = 0.7
    ) throws -> Attachment {
        guard let image = UIImage(data: imageData) else {
            throw RaterError.attachmentEncodingFailed
        }
        return try make(from: image, maxDimension: maxDimension, quality: quality)
    }
}

extension UIImage {
    /// Scales proportionally by the long edge. Images already small enough are returned
    /// untouched, avoiding a pointless redraw and the quality loss that comes with it.
    func rater_resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }

        let scale = maxDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        // Screenshots don't need @3x; rendering at 1x cuts the pixel count ninefold.
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
