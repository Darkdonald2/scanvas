import SwiftUI
import SceneKit

enum ViewMode: String, CaseIterable {
    case inside = "Inside", outside = "Outside"
}

/// 3D viewer. Outside: orbit around a dollhouse view (walls nearest you are see-through).
/// Inside: stand in the space, drag to look around, use the joystick to walk. Tap-to-measure works in both.
struct SceneViewer: UIViewRepresentable {
    var scene: SCNScene
    var mode: ViewMode
    var floorY: Float
    var measuring: Bool
    /// Joystick: x = strafe right, y = forward, each −1…1.
    var move: SIMD2<Float> = .zero
    var resetToken = 0
    var onMeasure: (Float?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.delegate = context.coordinator
        view.scene = scene
        let c = context.coordinator
        c.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:))))
        c.look.addTarget(c, action: #selector(Coordinator.looked(_:)))
        c.zoom.addTarget(c, action: #selector(Coordinator.zoomed(_:)))
        view.addGestureRecognizer(c.look)
        view.addGestureRecognizer(c.zoom)
        c.apply(mode)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        let old = c.parent
        c.parent = self
        if view.scene !== scene {
            view.scene = scene
            c.reset()
            c.apply(mode, keepCamera: true)
        } else if old.mode != mode || old.resetToken != resetToken {
            c.apply(mode)
        }
        if !measuring { c.reset() }
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var parent: SceneViewer
        weak var view: SCNView?
        let look = UIPanGestureRecognizer()
        let zoom = UIPinchGestureRecognizer()
        private let camera = SCNNode()
        private var yaw: Float = 0, pitch: Float = 0
        private var lastTime: TimeInterval = 0
        private var points: [SCNVector3] = []
        private let markers = SCNNode()

        init(_ parent: SceneViewer) {
            self.parent = parent
            super.init()
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.03
            camera.camera?.zFar = 500
            camera.name = "viewer-camera"
        }

        private var bounds: (SIMD3<Float>, SIMD3<Float>) {
            guard let scene = view?.scene else { return (.zero, .zero) }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for child in scene.rootNode.childNodes where child !== camera && child !== markers {
                let (a, b) = child.boundingBox
                if a.x > b.x { continue }
                let p = child.simdConvertPosition(SIMD3(a.x, a.y, a.z), to: nil), q = child.simdConvertPosition(SIMD3(b.x, b.y, b.z), to: nil)
                lo = simd_min(lo, simd_min(p, q)); hi = simd_max(hi, simd_max(p, q))
            }
            return lo.x > hi.x ? (.zero, .zero) : (lo, hi)
        }

        /// Puts the camera in the starting spot for the mode.
        func apply(_ mode: ViewMode, keepCamera: Bool = false) {
            guard let view, let scene = view.scene else { return }
            if camera.parent !== scene.rootNode { camera.removeFromParentNode(); scene.rootNode.addChildNode(camera) }
            let (lo, hi) = bounds
            let center = (lo + hi) / 2
            let radius = max(simd_length(hi - lo) / 2, 0.3)
            look.isEnabled = mode == .inside
            zoom.isEnabled = mode == .inside
            if mode == .inside {
                view.allowsCameraControl = false
                camera.camera?.fieldOfView = 75
                if !keepCamera {
                    yaw = 0; pitch = 0
                    camera.simdPosition = SIMD3(center.x, parent.floorY + 1.5, center.z)
                }
                updateOrientation()
            } else {
                camera.camera?.fieldOfView = 50
                camera.simdPosition = center + SIMD3(radius * 0.9, radius * 1.1, radius * 0.9)
                camera.simdLook(at: center)
                view.allowsCameraControl = true
                view.defaultCameraController.interactionMode = .orbitTurntable
                view.defaultCameraController.target = SCNVector3(center.x, center.y, center.z)
            }
            view.pointOfView = camera
        }

        private func updateOrientation() {
            camera.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        }

        @objc func looked(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            let fov = Float(camera.camera?.fieldOfView ?? 75)
            let k = fov / 75 * 0.005
            yaw += Float(t.x) * k
            pitch = max(-1.4, min(1.4, pitch + Float(t.y) * k))
            updateOrientation()
        }

        @objc func zoomed(_ g: UIPinchGestureRecognizer) {
            guard let cam = camera.camera else { return }
            cam.fieldOfView = max(25, min(100, cam.fieldOfView / g.scale))
            g.scale = 1
        }

        // MARK: Per frame: walking and dollhouse walls

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let dt = Float(lastTime == 0 ? 0 : min(0.1, time - lastTime))
            lastTime = time
            let mode = parent.mode, move = parent.move
            if mode == .inside && simd_length(move) > 0.05 {
                let forward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw)), right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
                camera.simdPosition += (forward * move.y + right * move.x) * 1.4 * dt
            }
            guard let scene = renderer.scene, let pov = renderer.pointOfView else { return }
            let eye = pov.presentation.simdWorldPosition
            for case let wall as WallNode in scene.rootNode.childNodes {
                let hide = mode == .outside && simd_dot(eye - wall.center, wall.outward) > 0
                if wall.isHidden != hide { wall.isHidden = hide }
            }
        }

        // MARK: Measuring

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
            let dot = SCNNode(geometry: SCNSphere(radius: CGFloat(markerSize())))
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
                parent.onMeasure(simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)))
            } else {
                parent.onMeasure(nil)
            }
        }

        private func markerSize() -> Float {
            let (lo, hi) = bounds
            let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
            return max(0.005, min(0.03, size / 200))
        }
    }
}

/// On-screen joystick for walking in the inside view.
struct Joystick: View {
    @Binding var value: SIMD2<Float>
    @State private var knob: CGSize = .zero
    private let radius: CGFloat = 46

    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial).frame(width: radius * 2, height: radius * 2)
            Circle().fill(Color.white.opacity(0.85)).frame(width: 40, height: 40).offset(knob)
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                var v = g.translation
                let len = sqrt(v.width * v.width + v.height * v.height)
                if len > radius { v = CGSize(width: v.width / len * radius, height: v.height / len * radius) }
                knob = v
                value = SIMD2(Float(v.width / radius), Float(-v.height / radius))
            }
            .onEnded { _ in
                withAnimation(.spring(duration: 0.2)) { knob = .zero }
                value = .zero
            })
    }
}
