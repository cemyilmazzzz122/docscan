import PhotosUI
import SwiftUI

struct HomeView: View {
    @Environment(ScanSession.self) private var session

    @State private var path: [ScanPage.ID] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var confirmClear = false
    @State private var pdfToSave: PDFFile?
    @State private var share: ShareItem?
    @State private var toast: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 14)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if session.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("DocScan")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { captureBar }
            .navigationDestination(for: ScanPage.ID.self) { PageEditorView(startID: $0) }
        }
        .toast($toast)
        .shareSheet($share)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.95) else { return }
                Task { await add([data]) }
            }
            .ignoresSafeArea()
        }
        .fileExporter(
            isPresented: Binding(get: { pdfToSave != nil }, set: { if !$0 { pdfToSave = nil } }),
            document: pdfToSave,
            contentType: .pdf,
            defaultFilename: Exporter.baseName()
        ) { result in
            if case .success = result { toast = "PDF saved" }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                var files: [Data] = []
                var unreadable = 0
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        files.append(data)
                    } else {
                        unreadable += 1
                    }
                }
                await add(files, alreadyFailed: unreadable)
            }
        }
    }

    // MARK: Content

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Scan a document", systemImage: "doc.viewfinder")
        } description: {
            Text("Take a photo or pick one from your library. Edges, perspective, bent pages and shadows are fixed automatically.")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                    NavigationLink(value: page.id) {
                        PageThumb(page: page, number: index + 1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { pageMenu(page, at: index) }
                }
                ForEach(0..<session.importing, id: \.self) { _ in
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(0.72, contentMode: .fit)
                        .background(.background.secondary, in: .rect(cornerRadius: 22))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.smooth, value: session.pages.map(\.id))
        }
    }

    @ViewBuilder
    private func pageMenu(_ page: ScanPage, at index: Int) -> some View {
        if index > 0 {
            Button("Move Earlier", systemImage: "arrow.backward") { session.move(from: index, to: index - 1) }
        }
        if index < session.pages.count - 1 {
            Button("Move Later", systemImage: "arrow.forward") { session.move(from: index, to: index + 1) }
        }
        Button("Share", systemImage: "square.and.arrow.up") { shareImages([page]) }
            .disabled(!page.isReady)
        Button("Delete", systemImage: "trash", role: .destructive) { session.remove(page) }
    }

    // MARK: Bars

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !session.pages.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Remove All", systemImage: "trash") { confirmClear = true }
                    .confirmationDialog("Remove all pages?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Remove All", role: .destructive) { session.clear() }
                    }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Save as PDF", systemImage: "doc.richtext") {
                        exportAction { pdfToSave = PDFFile(data: Exporter.pdf(session.pages)) }
                    }
                    Button("Share PDF", systemImage: "square.and.arrow.up") {
                        exportAction { share = ShareItem(urls: try Exporter.shareFiles(pdfOf: session.pages)) }
                    }
                    Divider()
                    Button("Save Images to Photos", systemImage: "photo.badge.arrow.down") {
                        exportAction {
                            Task {
                                do {
                                    try await Exporter.saveToPhotos(session.pages)
                                    let n = session.pages.count
                                    toast = n == 1 ? "Saved to Photos" : "\(n) images saved to Photos"
                                } catch {
                                    toast = error.localizedDescription
                                }
                            }
                        }
                    }
                    Button("Share Images", systemImage: "photo.on.rectangle") { shareImages(session.pages) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.button)
                .buttonStyle(.glassProminent)
            }
        }
    }

    private var captureBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItems, matching: .images, photoLibrary: .shared()) {
                    Label("Library", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                Button {
                    if CameraPicker.isAvailable {
                        showCamera = true
                    } else {
                        toast = "No camera on this device"
                    }
                } label: {
                    Label("Camera", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.extraLarge)
            .font(.body.weight(.semibold))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: Actions

    private func add(_ files: [Data], alreadyFailed: Int = 0) async {
        let failed = alreadyFailed + (files.isEmpty ? 0 : await session.addImages(files))
        if failed > 0 {
            toast = failed == 1 ? "One image could not be read" : "\(failed) images could not be read"
        }
    }

    private func exportAction(_ pages: [ScanPage]? = nil, _ action: () throws -> Void) {
        let pages = pages ?? session.pages
        guard !pages.isEmpty, pages.allSatisfy(\.isReady) else {
            toast = "Pages are still being processed"
            return
        }
        do {
            try action()
        } catch {
            toast = "Export failed: \(error.localizedDescription)"
        }
    }

    private func shareImages(_ pages: [ScanPage]) {
        exportAction(pages) { share = ShareItem(urls: try Exporter.shareFiles(imagesOf: pages)) }
    }
}
