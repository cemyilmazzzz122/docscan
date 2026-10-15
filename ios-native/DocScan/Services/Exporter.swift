import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Saving and sharing scans.
enum Exporter {
    static func baseName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Scan \(f.string(from: Date()))"
    }

    /// One A4 page per scan, portrait or landscape to match the image. The JPEGs are embedded as they are.
    static func pdf(_ pages: [ScanPage]) -> Data {
        let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Scanned document",
            kCGPDFContextCreator as String: "DocScan",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: a4, format: format)
        return renderer.pdfData { ctx in
            for page in pages {
                guard let data = page.result,
                      let provider = CGDataProvider(data: data as CFData),
                      let image = CGImage(
                        jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                        intent: .defaultIntent)
                else { continue }
                let w = CGFloat(image.width), h = CGFloat(image.height)
                let bounds = w > h ? CGRect(x: 0, y: 0, width: a4.height, height: a4.width) : a4
                ctx.beginPage(withBounds: bounds, pageInfo: [:])
                let s = min(bounds.width / w, bounds.height / h)
                let rect = CGRect(
                    x: (bounds.width - w * s) / 2, y: (bounds.height - h * s) / 2, width: w * s, height: h * s)
                // UIKit's PDF context is flipped; Core Graphics draws images bottom-up
                let cg = ctx.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: bounds.height)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(image, in: rect)
                cg.restoreGState()
            }
        }
    }

    /// Writes files for the share sheet into an empty temporary folder (cleared on each share).
    static func shareFiles(pdfOf pages: [ScanPage]) throws -> [URL] {
        let url = try shareDir().appendingPathComponent("\(baseName()).pdf")
        try pdf(pages).write(to: url)
        return [url]
    }

    static func shareFiles(imagesOf pages: [ScanPage]) throws -> [URL] {
        let dir = try shareDir()
        let base = baseName()
        var urls: [URL] = []
        for (i, page) in pages.enumerated() {
            guard let data = page.result else { continue }
            let suffix = pages.count > 1 ? " (\(i + 1))" : ""
            let url = dir.appendingPathComponent("\(base)\(suffix).jpg")
            try data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    private static func shareDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves the pages to the photo library, in a "DocScan" album when full access is granted.
    static func saveToPhotos(_ pages: [ScanPage]) async throws {
        let jpegs = pages.compactMap(\.result)
        var status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if status != .authorized && status != .limited {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else {
            throw EngineError(message: "No permission to save photos")
        }
        let album = status == .authorized ? existingAlbum() : nil
        let useAlbum = status == .authorized
        let base = baseName()
        try await PHPhotoLibrary.shared().performChanges {
            var placeholders: [PHObjectPlaceholder] = []
            for (i, data) in jpegs.enumerated() {
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.originalFilename = "\(base) \(i + 1).jpg"
                req.addResource(with: .photo, data: data, options: opts)
                if let p = req.placeholderForCreatedAsset { placeholders.append(p) }
            }
            guard useAlbum else { return }
            let albumReq = album.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "DocScan")
            albumReq.addAssets(placeholders as NSArray)
        }
    }

    private static func existingAlbum() -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title == %@", "DocScan")
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts)
            .firstObject
    }
}

/// A finished PDF for `fileExporter`.
struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
