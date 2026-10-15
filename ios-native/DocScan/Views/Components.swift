import SwiftUI

/// A page's result image, with the photo and a spinner underneath while the first scan is made.
struct PageImageView: View {
    let page: ScanPage

    var body: some View {
        ZStack {
            if let image = page.resultImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if page.error != nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.red)
            } else {
                Image(uiImage: page.sourceImage)
                    .resizable()
                    .scaledToFit()
                    .opacity(0.35)
            }
            if page.isProcessing {
                ProgressView()
                    .controlSize(.large)
                    .padding(12)
                    .glassEffect(.regular, in: .circle)
            }
        }
        .animation(.smooth(duration: 0.25), value: page.isProcessing)
    }
}

/// Grid tile for the page list.
struct PageThumb: View {
    let page: ScanPage
    let number: Int

    var body: some View {
        PageImageView(page: page)
            .padding(10)
            .frame(maxWidth: .infinity)
            .aspectRatio(0.72, contentMode: .fit)
            .background(.background.secondary, in: .rect(cornerRadius: 22))
            .overlay(alignment: .bottomLeading) {
                Text("\(number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .padding(8)
            }
            .contentShape(.rect(cornerRadius: 22))
    }
}

/// Pinch to zoom, drag to pan while zoomed, double tap to toggle.
struct Zoomable<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = min(max(baseScale * $0.magnification, 1), 5) }
                    .onEnded { _ in
                        baseScale = scale
                        if scale <= 1 { reset() }
                    }
            )
            // Panning only while zoomed, so swiping still moves between pages
            .gesture(
                DragGesture()
                    .onChanged {
                        offset = CGSize(
                            width: baseOffset.width + $0.translation.width,
                            height: baseOffset.height + $0.translation.height)
                    }
                    .onEnded { _ in baseOffset = offset },
                including: scale > 1 ? .all : .subviews
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.35)) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 2.5
                        baseScale = 2.5
                    }
                }
            }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

/// A short message in a glass capsule at the top of the screen.
struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.message = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

/// Files handed to the system share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    func shareSheet(_ item: Binding<ShareItem?>) -> some View {
        sheet(item: item) { share in
            ActivityView(items: share.urls)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }
}

/// The system camera.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
