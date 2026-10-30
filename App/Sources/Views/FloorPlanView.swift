import SwiftUI

/// Zoomable 2D plan drawn with the same renderer as the PDF/PNG exports.
struct FloorPlanView: View {
    var drawing: PlanDrawing
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                ctx.withCGContext { cg in
                    PlanRenderer(drawing: drawing, theme: .dark).draw(in: cg, rect: CGRect(origin: .zero, size: size), margin: 30)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale = max(0.5, min(8, lastScale * $0)) }
                    .onEnded { _ in lastScale = scale }
                    .simultaneously(with: DragGesture()
                        .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width, height: lastOffset.height + $0.translation.height) }
                        .onEnded { _ in lastOffset = offset })
            )
            .onTapGesture(count: 2) {
                withAnimation { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
            }
        }
        .clipped()
        .background(Color(white: 0.07))
    }
}
