import SwiftUI
import SceneKit
import CoreMotion
import Photos

/// Look around inside a 360 panorama: drag to turn, pinch to zoom, or turn on "Move phone" to look around by
/// moving the phone.
struct PanoramaViewer: UIViewRepresentable {
    let image: UIImage
    @Binding var useMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        let scene = SCNScene()
        let sphere = SCNNode(geometry: Self.sphere(texture: image))
        scene.rootNode.addChildNode(sphere)
        let camera = SCNCamera()
        camera.fieldOfView = 75
        camera.zNear = 0.1
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        view.scene = scene
        view.pointOfView = cameraNode
        view.isPlaying = true
        context.coordinator.attach(view: view, camera: cameraNode)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.setMotion(useMotion)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.setMotion(false)
    }

    /// A sphere seen from inside, with texture coordinates in the same convention the stitcher writes:
    /// longitude 0 (the middle of the image) is straight ahead (-z), latitude up is the top row.
    static func sphere(texture: UIImage) -> SCNGeometry {
        let cols = 128, rows = 64, radius: Float = 10
        var vertices: [SCNVector3] = []
        var uvs: [CGPoint] = []
        for r in 0...rows {
            let v = Double(r) / Double(rows)
            let lat = Double.pi / 2 - v * .pi
            for c in 0...cols {
                let u = Double(c) / Double(cols)
                let lon = u * 2 * .pi - .pi
                vertices.append(SCNVector3(Float(cos(lat) * sin(lon)) * radius, Float(sin(lat)) * radius, Float(-cos(lat) * cos(lon)) * radius))
                uvs.append(CGPoint(x: u, y: v))
            }
        }
        var indices: [UInt32] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let a = UInt32(r * (cols + 1) + c), b = a + 1, d = a + UInt32(cols + 1), e = d + 1
                indices += [a, d, b, b, d, e]
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: uvs)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = texture
        material.diffuse.mipFilter = .linear
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    final class Coordinator: NSObject {
        private weak var view: SCNView?
        private var camera: SCNNode?
        private var yaw: Float = 0
        private var pitch: Float = 0
        private var motion: CMMotionManager?
        private var motionYawOffset: Float?

        func attach(view: SCNView, camera: SCNNode) {
            self.view = view
            self.camera = camera
            view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
            apply()
        }

        private func apply() {
            camera?.eulerAngles = SCNVector3(pitch, yaw, 0)
        }

        @objc private func pan(_ g: UIPanGestureRecognizer) {
            guard let view, let cam = camera?.camera else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            // Drag the picture with the finger: about one screen height per field of view.
            let k = Float(cam.fieldOfView * .pi / 180) / Float(max(1, view.bounds.height))
            if motion != nil {
                motionYawOffset = (motionYawOffset ?? 0) + Float(t.x) * k
            } else {
                yaw += Float(t.x) * k
                pitch = max(-Float.pi / 2 + 0.01, min(Float.pi / 2 - 0.01, pitch + Float(t.y) * k))
                apply()
            }
        }

        @objc private func pinch(_ g: UIPinchGestureRecognizer) {
            guard let cam = camera?.camera else { return }
            cam.fieldOfView = max(30, min(110, cam.fieldOfView / g.scale))
            g.scale = 1
        }

        func setMotion(_ on: Bool) {
            if on, motion == nil {
                let m = CMMotionManager()
                guard m.isDeviceMotionAvailable else { return }
                m.deviceMotionUpdateInterval = 1.0 / 60
                motionYawOffset = nil
                m.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
                    guard let self, let q = data?.attitude.quaternion, let camera = self.camera else { return }
                    // The phone's attitude has z up; the scene has y up. The back camera looks along the phone's -z.
                    let attitude = simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
                    let upright = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)) * attitude
                    if self.motionYawOffset == nil {
                        // Keep looking where the viewer was looking when motion was turned on.
                        let f = upright.act(SIMD3<Float>(0, 0, -1))
                        let heading = atan2(-f.x, -f.z)
                        self.motionYawOffset = self.yaw - heading
                    }
                    camera.simdOrientation = simd_quatf(angle: self.motionYawOffset ?? 0, axis: SIMD3(0, 1, 0)) * upright
                }
                motion = m
            } else if !on, let m = motion {
                m.stopDeviceMotionUpdates()
                motion = nil
                // Carry on from where motion left the view.
                if let camera {
                    let f = camera.simdOrientation.act(SIMD3<Float>(0, 0, -1))
                    yaw = atan2(-f.x, -f.z)
                    pitch = asin(max(-1, min(1, f.y)))
                    apply()
                }
            }
        }
    }
}

struct PanoramaDetailView: View {
    @EnvironmentObject private var store: ProjectStore
    let project: ScanProject
    @State private var image: UIImage?
    @State private var useMotion = false
    @State private var building = false
    @State private var progress = 0.0
    @State private var step = ""
    @State private var showReport = false
    @State private var note: String?
    @State private var version = 0

    private var file: URL { store.url(ProjectFile.panorama, in: project) }
    private var current: ScanProject { store.projects.first { $0.id == project.id } ?? project }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if building {
                ProcessingView(progress: progress, title: step)
            } else if let image {
                PanoramaViewer(image: image, useMotion: $useMotion).id(version).ignoresSafeArea(edges: .bottom)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "pano").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("This 360 photo hasn't been stitched yet.").foregroundStyle(.secondary)
                    Button { Task { await rebuild(refine: true) } } label: { Label("Stitch now", systemImage: "wand.and.stars") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if image != nil && !building {
                    Button { useMotion.toggle() } label: {
                        Image(systemName: useMotion ? "iphone.gen3.radiowaves.left.and.right" : "hand.draw")
                    }
                    .accessibilityLabel(useMotion ? "Look around by dragging" : "Look around by moving the phone")
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                }
                Menu {
                    if image != nil {
                        Button { Task { await saveToPhotos() } } label: { Label("Save to Photos", systemImage: "photo.badge.plus") }
                    }
                    Button { Task { await rebuild(refine: true) } } label: { Label("Stitch again", systemImage: "arrow.triangle.2.circlepath") }
                    Button { Task { await rebuild(refine: false) } } label: { Label("Stitch without fine-tuning", systemImage: "scope") }
                    Button { showReport = true } label: { Label("Processing details", systemImage: "info.circle") }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(building)
            }
        }
        .task { load() }
        .sheet(isPresented: $showReport) {
            NavigationStack {
                ScrollView {
                    Text((try? String(contentsOf: store.url("processing.txt", in: project), encoding: .utf8)) ?? "No details yet.")
                        .font(.footnote.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle("Processing details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showReport = false } } }
            }
        }
        .alert("360 photo", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(note ?? "") }
    }

    private func load() {
        image = UIImage(contentsOfFile: file.path)
    }

    private func rebuild(refine: Bool) async {
        building = true
        step = "Stitching"
        progress = 0
        do {
            let result = try await PanoramaBuilder.build(folder: store.folder(for: project), refine: refine) { f, s in
                Task { @MainActor in progress = f; step = s }
            }
            var p = current
            p.summary = "360° · \(result.report.shots) photos · \(result.width) × \(result.width / 2)"
            store.save(p)
            load()
            version += 1
        } catch {
            note = "Stitching failed: \(error.localizedDescription)"
        }
        building = false
    }

    private func saveToPhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            note = "Scanvas isn't allowed to add photos. You can allow it in Settings › Scanvas › Photos."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
            }
            note = "Saved to Photos. Apple's Photos app shows it as a flat wide picture; apps such as Google Photos and Facebook show it as a 360 photo."
        } catch {
            note = "Couldn't save to Photos: \(error.localizedDescription)"
        }
    }
}
