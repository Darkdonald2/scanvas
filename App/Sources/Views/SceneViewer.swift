import SwiftUI
import SceneKit

/// 3D viewer with orbit/zoom and tap-to-measure between two points on the model.
struct SceneViewer: UIViewRepresentable {
    var scene: SCNScene
    var measuring: Bool
    var onMeasure: (Float?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.scene = scene
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        if view.scene !== scene {
            view.scene = scene
            context.coordinator.reset()
        }
        if !measuring { context.coordinator.reset() }
    }

    final class Coordinator: NSObject {
        var parent: SceneViewer
        weak var view: SCNView?
        private var points: [SCNVector3] = []
        private let markers = SCNNode()

        init(_ parent: SceneViewer) { self.parent = parent }

        func reset() {
            guard !points.isEmpty || markers.parent != nil else { return }
            points.removeAll()
            markers.childNodes.forEach { $0.removeFromParentNode() }
            markers.removeFromParentNode()
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard parent.measuring, let view, let scene = view.scene else { return }
            let hits = view.hitTest(g.location(in: view), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            guard let hit = hits.first(where: { $0.node.parent !== markers && $0.node !== markers }) else { return }
            if markers.parent == nil { scene.rootNode.addChildNode(markers) }
            if points.count == 2 { reset(); scene.rootNode.addChildNode(markers) }
            let p = hit.worldCoordinates
            points.append(p)
            let size = CGFloat(markerSize(scene))
            let dot = SCNNode(geometry: SCNSphere(radius: size))
            dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow
            dot.geometry?.firstMaterial?.lightingModel = .constant
            dot.position = p
            markers.addChildNode(dot)
            if points.count == 2 {
                let a = points[0], b = points[1]
                let src = SCNGeometrySource(vertices: [a, b])
                let el = SCNGeometryElement(indices: [UInt16(0), 1], primitiveType: .line)
                let line = SCNGeometry(sources: [src], elements: [el])
                line.firstMaterial?.diffuse.contents = UIColor.systemYellow
                line.firstMaterial?.lightingModel = .constant
                line.firstMaterial?.readsFromDepthBuffer = false
                markers.addChildNode(SCNNode(geometry: line))
                let d = simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z))
                parent.onMeasure(d)
            } else {
                parent.onMeasure(nil)
            }
        }

        private func markerSize(_ scene: SCNScene) -> Float {
            let (lo, hi) = scene.rootNode.boundingBox
            return max(0.005, min(0.05, max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) / 150))
        }
    }
}
