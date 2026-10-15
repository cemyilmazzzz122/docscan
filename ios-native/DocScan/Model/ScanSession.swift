import SwiftUI

/// The pages being scanned, in document order. Engine calls run on background tasks.
@MainActor
@Observable
final class ScanSession {
    private(set) var pages: [ScanPage] = []
    /// Number of files still being read.
    private(set) var importing = 0

    var isEmpty: Bool { pages.isEmpty && importing == 0 }
    var allReady: Bool { !pages.isEmpty && pages.allSatisfy(\.isReady) }

    /// Adds photos as new pages. Returns how many could not be read.
    func addImages(_ files: [Data]) async -> Int {
        importing += files.count
        var failed = 0
        for data in files {
            defer { importing -= 1 }
            do {
                let (image, decoded) = try await Task.detached(priority: .userInitiated) {
                    let image = try Engine.normalize(data)
                    guard let decoded = UIImage(data: image.data)?.preparingForDisplay() else {
                        throw EngineError(message: "could not decode the image")
                    }
                    return (image, decoded)
                }.value
                let page = ScanPage(source: image, image: decoded)
                pages.append(page)
                Task { await detectAndProcess(page) }
            } catch {
                failed += 1
            }
        }
        return failed
    }

    private func detectAndProcess(_ page: ScanPage) async {
        page.isProcessing = true
        let source = page.source
        do {
            let d = try await Task.detached(priority: .userInitiated) { try Engine.detect(source) }.value
            page.corners = d.corners
            page.detectedCorners = d.corners
            page.documentFound = d.found
        } catch {
            page.corners = page.fullFrame
        }
        await process(page)
    }

    private func process(_ page: ScanPage) async {
        page.revision += 1
        let rev = page.revision
        page.isProcessing = true
        page.error = nil
        let source = page.source
        let corners = page.corners ?? page.fullFrame
        let mode = page.mode, straighten = page.straighten, turns = page.quarterTurns
        do {
            let (out, image) = try await Task.detached(priority: .userInitiated) {
                let out = try Engine.process(
                    source, corners: corners, mode: mode, straighten: straighten, quarterTurns: turns)
                return (out, UIImage(data: out.data)?.preparingForDisplay())
            }.value
            guard rev == page.revision, pages.contains(where: { $0 === page }) else { return }
            page.result = out.data
            page.resultImage = image
        } catch {
            guard rev == page.revision else { return }
            page.error = error.localizedDescription
        }
        page.isProcessing = false
    }

    func setMode(_ page: ScanPage, _ mode: ScanMode) {
        guard page.mode != mode else { return }
        page.mode = mode
        Task { await process(page) }
    }

    func setStraighten(_ page: ScanPage, _ on: Bool) {
        page.straighten = on
        Task { await process(page) }
    }

    func rotate(_ page: ScanPage) {
        page.quarterTurns = (page.quarterTurns + 1) % 4
        Task { await process(page) }
    }

    func setCorners(_ page: ScanPage, _ corners: [CGPoint]) {
        page.corners = corners
        Task { await process(page) }
    }

    func retry(_ page: ScanPage) {
        Task { await process(page) }
    }

    func remove(_ page: ScanPage) {
        pages.removeAll { $0 === page }
    }

    func move(from: Int, to: Int) {
        let p = pages.remove(at: from)
        pages.insert(p, at: to)
    }

    func clear() {
        pages.removeAll()
    }
}
