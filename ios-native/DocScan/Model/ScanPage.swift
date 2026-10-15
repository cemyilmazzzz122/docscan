import SwiftUI

/// One scanned page: the original photo plus the settings that turn it into the result.
@Observable
final class ScanPage: Identifiable {
    let id = UUID()

    /// The photo, normalized to an upright JPEG (EXIF rotation applied).
    let source: Data
    let sourceImage: UIImage
    let width: Int
    let height: Int

    /// Document corners in `source` pixels: TL, TR, BR, BL. Nil until detected.
    var corners: [CGPoint]?
    /// What automatic detection found (the full frame if `documentFound` is false).
    var detectedCorners: [CGPoint]?
    var documentFound = false

    var mode: ScanMode = .color
    var straighten = true
    var quarterTurns = 0

    /// The processed page (JPEG). Kept while a newer version is being made, so the screen doesn't flash.
    var result: Data?
    var resultImage: UIImage?
    var isProcessing = false
    var error: String?

    /// Bumped on every settings change so stale results can be dropped.
    @ObservationIgnored var revision = 0

    var isReady: Bool { result != nil && !isProcessing }

    var fullFrame: [CGPoint] {
        let w = CGFloat(width - 1), h = CGFloat(height - 1)
        return [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)]
    }

    init(source: EncodedImage, image: UIImage) {
        self.source = source.data
        self.sourceImage = image
        self.width = source.width
        self.height = source.height
    }
}
