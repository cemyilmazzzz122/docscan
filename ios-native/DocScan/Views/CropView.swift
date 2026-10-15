import SwiftUI

/// Drag the four corners onto the page edges. A loupe above the finger shows the exact edge.
struct CropView: View {
    let page: ScanPage
    let onDone: ([CGPoint]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var points: [CGPoint]
    /// Corner being dragged, and where it was (in view coordinates) when the drag started.
    @State private var dragging: Int?
    @State private var dragStart: CGPoint = .zero
    @State private var dragMissed = false

    private static let reach: CGFloat = 48
    private static let loupeSize: CGFloat = 110
    private static let zoom: CGFloat = 2.5

    init(page: ScanPage, onDone: @escaping ([CGPoint]) -> Void) {
        self.page = page
        self.onDone = onDone
        _points = State(initialValue: page.corners ?? page.fullFrame)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fit = Fit(image: CGSize(width: page.width, height: page.height), box: geo.size)
                let view = points.map(fit.toView)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: page.sourceImage)
                        .resizable()
                        .frame(width: fit.size.width, height: fit.size.height)
                        .offset(x: fit.origin.x, y: fit.origin.y)
                    QuadOverlay(points: view, active: dragging)
                    if let i = dragging {
                        loupe(at: view[i], fit: fit, quad: view)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag($0, view: view, fit: fit) }
                        .onEnded { _ in
                            dragging = nil
                            dragMissed = false
                        }
                )
            }
            .padding(28)
            .background(.black)
            .safeAreaInset(edge: .bottom) { presets }
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sensoryFeedback(.selection, trigger: dragging) { _, new in new != nil }
        }
        .environment(\.colorScheme, .dark)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", systemImage: "checkmark") {
                onDone(points)
                dismiss()
            }
            .buttonStyle(.glassProminent)
        }
    }

    private var presets: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button("Auto Detect", systemImage: "wand.and.stars") { setPoints(page.detectedCorners) }
                    .disabled(page.detectedCorners == nil)
                Button("Whole Photo", systemImage: "arrow.up.left.and.arrow.down.right") { setPoints(page.fullFrame) }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(.bottom, 8)
    }

    private func setPoints(_ corners: [CGPoint]?) {
        guard let corners else { return }
        withAnimation(.spring(duration: 0.35)) { points = corners }
    }

    private func drag(_ value: DragGesture.Value, view: [CGPoint], fit: Fit) {
        if dragging == nil {
            guard !dragMissed else { return }
            // Grab the nearest corner within reach
            let nearest = view.indices.min { view[$0].distance(to: value.startLocation) < view[$1].distance(to: value.startLocation) }
            guard let i = nearest, view[i].distance(to: value.startLocation) < Self.reach else {
                dragMissed = true
                return
            }
            dragging = i
            dragStart = view[i]
        }
        guard let i = dragging else { return }
        let target = CGPoint(x: dragStart.x + value.translation.width, y: dragStart.y + value.translation.height)
        points[i] = fit.toImage(target)
    }

    /// The photo under the dragged corner, magnified, with the page outline on top.
    private func loupe(at p: CGPoint, fit: Fit, quad: [CGPoint]) -> some View {
        let r = Self.loupeSize / 2, z = Self.zoom
        return ZStack(alignment: .topLeading) {
            Image(uiImage: page.sourceImage)
                .resizable()
                .frame(width: fit.size.width * z, height: fit.size.height * z)
                .offset(x: r - (p.x - fit.origin.x) * z, y: r - (p.y - fit.origin.y) * z)
            Path { path in
                path.addLines(quad.map { CGPoint(x: r + ($0.x - p.x) * z, y: r + ($0.y - p.y) * z) })
                path.closeSubpath()
            }
            .stroke(.tint, lineWidth: 2)
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: Self.loupeSize, height: Self.loupeSize)
        }
        .frame(width: Self.loupeSize, height: Self.loupeSize, alignment: .topLeading)
        .clipShape(.circle)
        .glassEffect(.clear, in: .circle)
        .overlay(Circle().stroke(.tint, lineWidth: 2))
        .position(x: p.x, y: p.y - Self.loupeSize * 1.1 < r ? p.y + Self.loupeSize * 1.1 : p.y - Self.loupeSize * 1.1)
        .allowsHitTesting(false)
    }
}

/// The photo fitted into the available space, and conversions between image and view points.
private struct Fit {
    let scale: CGFloat
    let size: CGSize
    let origin: CGPoint
    let image: CGSize

    init(image: CGSize, box: CGSize) {
        self.image = image
        scale = min(box.width / image.width, box.height / image.height)
        size = CGSize(width: image.width * scale, height: image.height * scale)
        origin = CGPoint(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    func toImage(_ v: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max((v.x - origin.x) / scale, 0), image.width - 1),
            y: min(max((v.y - origin.y) / scale, 0), image.height - 1))
    }
}

/// Dims everything outside the page and draws the outline with corner handles.
private struct QuadOverlay: View {
    let points: [CGPoint]
    let active: Int?

    var body: some View {
        Canvas { ctx, size in
            var quad = Path()
            quad.addLines(points)
            quad.closeSubpath()
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addPath(quad)
            ctx.fill(outside, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            ctx.stroke(quad, with: .foreground, lineWidth: 2)
            for (i, p) in points.enumerated() where i != active {
                // The dragged corner is left out so the loupe shows the edge underneath
                let dot = Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
                ctx.fill(dot, with: .color(.white))
                ctx.stroke(dot, with: .foreground, lineWidth: 3)
            }
        }
        .foregroundStyle(.tint)
        .allowsHitTesting(false)
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
