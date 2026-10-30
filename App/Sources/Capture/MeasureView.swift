import SwiftUI
import RealityKit
import ARKit
import Combine

/// AR tape measure: aim the centre dot, add points, read each segment and the total.
final class MeasureModel: ObservableObject {
    @Published var points: [SIMD3<Float>] = []
    @Published var aim: SIMD3<Float>?
    @Published var labels: [(CGPoint, String)] = []

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    private let root = AnchorEntity(world: .zero)
    private var updates: Cancellable?

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { config.sceneReconstruction = .mesh }
        arView.session.run(config)
        arView.scene.addAnchor(root)
        updates = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.tick() }
    }

    func stop() {
        updates?.cancel()
        arView.session.pause()
    }

    private func tick() {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        aim = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first.map {
            SIMD3($0.worldTransform.columns.3.x, $0.worldTransform.columns.3.y, $0.worldTransform.columns.3.z)
        }
        let units = UnitSystem.current
        var newLabels: [(CGPoint, String)] = []
        for i in 1..<max(1, points.count) {
            let a = points[i - 1], b = points[i]
            if let p = arView.project((a + b) / 2) { newLabels.append((p, units.length(simd_distance(a, b)))) }
        }
        labels = newLabels
    }

    var liveDistance: Float? {
        guard let last = points.last, let aim else { return nil }
        return simd_distance(last, aim)
    }

    var total: Float {
        zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    func addPoint() {
        guard let p = aim else { return }
        if let last = points.last { root.addChild(segment(from: last, to: p)) }
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [UnlitMaterial(color: .systemYellow)])
        dot.position = p
        root.addChild(dot)
        points.append(p)
    }

    func undo() {
        guard !points.isEmpty else { return }
        points.removeLast()
        rebuild()
    }

    func clear() {
        points.removeAll()
        rebuild()
    }

    private func rebuild() {
        root.children.removeAll()
        for (i, p) in points.enumerated() {
            if i > 0 { root.addChild(segment(from: points[i - 1], to: p)) }
            let dot = ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [UnlitMaterial(color: .systemYellow)])
            dot.position = p
            root.addChild(dot)
        }
    }

    private func segment(from a: SIMD3<Float>, to b: SIMD3<Float>) -> ModelEntity {
        let length = simd_distance(a, b)
        let e = ModelEntity(mesh: .generateBox(size: SIMD3(0.003, 0.003, length)), materials: [UnlitMaterial(color: .systemYellow)])
        e.position = (a + b) / 2
        e.look(at: b, from: e.position, relativeTo: nil)
        return e
    }
}

private struct MeasureARContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct MeasureView: View {
    @StateObject private var model = MeasureModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let units = UnitSystem.current
        ZStack {
            MeasureARContainer(arView: model.arView).ignoresSafeArea()
            ForEach(Array(model.labels.enumerated()), id: \.offset) { _, label in
                Text(label.1).font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.yellow, in: Capsule()).foregroundStyle(.black)
                    .position(label.0)
            }
            .ignoresSafeArea()
            Circle().stroke(model.aim == nil ? Color.red : Color.white, lineWidth: 2).frame(width: 22, height: 22)
            Circle().fill(.white).frame(width: 4, height: 4)

            VStack {
                HStack {
                    Button("Close") { model.stop(); dismiss() }.buttonStyle(.bordered).tint(.white)
                    Spacer()
                    if model.points.count > 1 {
                        Text("Total " + units.length(model.total)).font(.callout.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding()
                Spacer()
                if let d = model.liveDistance {
                    Text(units.length(d)).font(.title.bold().monospacedDigit())
                        .padding(.horizontal, 16).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
                }
                HStack(spacing: 24) {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.title2).frame(width: 54, height: 54) }
                        .background(.ultraThinMaterial, in: Circle()).disabled(model.points.isEmpty)
                    Button { model.addPoint() } label: { Image(systemName: "plus").font(.largeTitle.bold()).frame(width: 76, height: 76) }
                        .background(Color.accentColor, in: Circle()).foregroundStyle(.black).disabled(model.aim == nil)
                    Button { model.clear() } label: { Image(systemName: "trash").font(.title2).frame(width: 54, height: 54) }
                        .background(.ultraThinMaterial, in: Circle()).disabled(model.points.isEmpty)
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
