import SwiftUI

/// One page at a time: filter, crop, straighten, rotate. Swipe for the other pages.
struct PageEditorView: View {
    @Environment(ScanSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var selection: ScanPage.ID?
    @State private var cropping: ScanPage?
    @State private var share: ShareItem?
    @State private var toast: String?

    init(startID: ScanPage.ID) {
        _selection = State(initialValue: startID)
    }

    private var index: Int { session.pages.firstIndex { $0.id == selection } ?? 0 }

    var body: some View {
        let pages = session.pages
        Group {
            if pages.isEmpty {
                Color.clear
            } else {
                let page = pages[min(index, pages.count - 1)]
                TabView(selection: $selection) {
                    ForEach(pages) { p in
                        content(for: p)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .tag(Optional(p.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .navigationTitle("Page \(index + 1) of \(pages.count)")
                .toolbar { toolbar(page) }
                .safeAreaInset(edge: .bottom) { controls(page) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast)
        .shareSheet($share)
        .fullScreenCover(item: $cropping) { page in
            CropView(page: page) { session.setCorners(page, $0) }
        }
    }

    @ViewBuilder
    private func content(for page: ScanPage) -> some View {
        if page.error != nil {
            ContentUnavailableView {
                Label("This page could not be processed", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try Again") { session.retry(page) }
                    .buttonStyle(.glass)
            }
        } else {
            Zoomable { PageImageView(page: page) }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ page: ScanPage) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Delete Page", systemImage: "trash", role: .destructive) { delete(page) }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button("Share", systemImage: "square.and.arrow.up") {
                do {
                    share = ShareItem(urls: try Exporter.shareFiles(imagesOf: [page]))
                } catch {
                    toast = "Share failed: \(error.localizedDescription)"
                }
            }
            .disabled(!page.isReady)
        }
    }

    private func controls(_ page: ScanPage) -> some View {
        VStack(spacing: 10) {
            if !page.documentFound && page.isReady {
                Text("No page edges found, using the whole photo. Tap Crop to adjust.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 12) {
                    Picker("Mode", selection: Binding(get: { page.mode }, set: { session.setMode(page, $0) })) {
                        ForEach(ScanMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        tool("Crop", "crop", on: false) { cropping = page }
                        tool("Straighten", "text.alignleft", on: page.straighten) {
                            session.setStraighten(page, !page.straighten)
                        }
                        tool("Rotate", "rotate.right", on: false) { session.rotate(page) }
                    }
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 30))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .sensoryFeedback(.selection, trigger: page.mode)
        .sensoryFeedback(.impact(weight: .light), trigger: page.quarterTurns)
    }

    /// A tool button; toggles light up with a tinted glass when on.
    @ViewBuilder
    private func tool(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        let label = VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 50)

        if on {
            Button(action: action) { label }.buttonStyle(.glassProminent)
        } else {
            Button(action: action) { label }.buttonStyle(.glass)
        }
    }

    private func delete(_ page: ScanPage) {
        let pages = session.pages
        guard let i = pages.firstIndex(where: { $0 === page }) else { return }
        let next = i + 1 < pages.count ? pages[i + 1] : (i > 0 ? pages[i - 1] : nil)
        session.remove(page)
        if let next {
            selection = next.id
        } else {
            dismiss()
        }
    }
}
