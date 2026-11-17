import SwiftUI
import SceneKit
import CoreMotion
import Photos

/// Shows a 360 panorama from the inside and lets the viewer look around: drag, pinch, an on-screen joystick,
/// or by moving the phone. Tours use the same scene and add floor arrows toward the neighbouring stops.
final class PanoSceneController: NSObject, ObservableObject {
    struct Marker {
        var id: Int
        /// Where the other stop is, relative to this one (metres, ARKit axes).
        var offset: SIMD3<Float>
    }

    enum StickMode {
        /// Left and right turn, up and down zoom (a single 360 photo).
        case look
        /// Left and right turn; up and down are passed to `onStickMove` (a tour, to step between stops).
        case walk
    }

    let view = SCNView()
    /// Which way the viewer is looking: radians, 0 = the panorama's middle (-z), growing toward +x.
    @Published private(set) var heading: Double = 0
    var stickMode = StickMode.look
    var onTapMarker: ((Int) -> Void)?
    /// Called about 60 times a second in walk mode with the joystick's forward amount (-1…1).
    var onStickMove: ((Float) -> Void)?
    /// How high the viewer's eye is above the floor, for placing the arrows.
    var eyeHeight: Float = 1.45

    private let cameraNode = SCNNode()
    private let sphereA: SCNNode
    private let sphereB: SCNNode
    private let markers = SCNNode()
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var stick = SIMD2<Float>(0, 0)
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var lastHeading = CACurrentMediaTime()
    private var motion: CMMotionManager?
    private var motionYawOffset: Float?
    private let baseFOV: CGFloat = 75

    override init() {
        sphereA = SCNNode(geometry: Self.sphere(radius: 10))
        sphereB = SCNNode(geometry: Self.sphere(radius: 9.6))
        super.init()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        let scene = SCNScene()
        sphereA.renderingOrder = -10
        sphereB.renderingOrder = -9
        sphereB.opacity = 0
        scene.rootNode.addChildNode(sphereA)
        scene.rootNode.addChildNode(sphereB)
        scene.rootNode.addChildNode(markers)
        let camera = SCNCamera()
        camera.fieldOfView = baseFOV
        camera.zNear = 0.05
        camera.zFar = 200
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        view.scene = scene
        view.pointOfView = cameraNode
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        apply()
    }

    // MARK: Content

    /// Shows a panorama. `rotation` turns it about the vertical axis (radians), for tour stops whose position
    /// ARKit corrected after they were taken.
    func show(_ image: UIImage, rotation: Float = 0, animated: Bool = false) {
        guard animated, let camera = cameraNode.camera else {
            sphereA.geometry?.firstMaterial?.diffuse.contents = image
            sphereA.eulerAngles.y = rotation
            return
        }
        sphereB.geometry?.firstMaterial?.diffuse.contents = image
        sphereB.eulerAngles.y = rotation
        let fov = camera.fieldOfView
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        SCNTransaction.completionBlock = { [weak self] in
            guard let self else { return }
            self.sphereA.geometry?.firstMaterial?.diffuse.contents = image
            self.sphereA.eulerAngles.y = rotation
            self.sphereB.opacity = 0
            self.sphereB.geometry?.firstMaterial?.diffuse.contents = nil
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.25
            camera.fieldOfView = fov
            SCNTransaction.commit()
        }
        sphereB.opacity = 1
        camera.fieldOfView = fov * 0.8          // a small push forward while the next stop fades in
        SCNTransaction.commit()
    }

    /// Floor arrows toward the neighbouring stops, and a disc where each one is.
    func setMarkers(_ list: [Marker]) {
        markers.childNodes.forEach { $0.removeFromParentNode() }
        for m in list {
            let flat = SIMD2(m.offset.x, m.offset.z)
            let dist = simd_length(flat)
            guard dist > 0.2 else { continue }
            let h = atan2(m.offset.x, -m.offset.z)
            let dir = flat / dist
            // Arrow on the floor a couple of steps away, pointing at the stop.
            let near = min(2.6, max(1.2, dist * 0.7))
            let holder = SCNNode()
            holder.position = SCNVector3(dir.x * near, -eyeHeight, dir.y * near)
            holder.eulerAngles.y = -h
            let plane = SCNPlane(width: 0.8, height: 0.8)
            plane.firstMaterial = Self.overlayMaterial(Self.arrowImage)
            let arrow = SCNNode(geometry: plane)
            arrow.eulerAngles.x = -.pi / 2
            arrow.name = "stop:\(m.id)"
            arrow.renderingOrder = 10
            holder.addChildNode(arrow)
            markers.addChildNode(holder)
            // Disc at the stop itself (skipped when it would sit under the arrow or is far away).
            if dist > near + 0.8 && dist < 14 {
                let disc = SCNPlane(width: 0.6, height: 0.6)
                disc.firstMaterial = Self.overlayMaterial(Self.discImage)
                let node = SCNNode(geometry: disc)
                node.position = SCNVector3(m.offset.x, m.offset.y - eyeHeight, m.offset.z)
                node.eulerAngles.x = -.pi / 2
                node.name = "stop:\(m.id)"
                node.renderingOrder = 9
                markers.addChildNode(node)
            }
        }
    }

    // MARK: Looking around

    func setStick(_ value: SIMD2<Float>) {
        stick = value
        if timer == nil {
            lastTick = CACurrentMediaTime()
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTick))
        lastTick = now
        if abs(stick.x) > 0.08 {
            let turn = stick.x * abs(stick.x) * 1.9 * dt          // gentle near the middle, up to about 110° a second
            if motion != nil { motionYawOffset = (motionYawOffset ?? 0) - turn } else { yaw -= turn; apply() }
        }
        switch stickMode {
        case .look:
            if abs(stick.y) > 0.08, let camera = cameraNode.camera {
                camera.fieldOfView = max(30, min(110, camera.fieldOfView - CGFloat(stick.y * 45 * dt)))
            }
        case .walk:
            onStickMove?(stick.y)
        }
        if stick == .zero && stickMode == .look {
            timer?.invalidate()
            timer = nil
        }
        publishHeading(now)
    }

    private func publishHeading(_ now: CFTimeInterval, force: Bool = false) {
        guard force || now - lastHeading > 0.1 else { return }
        lastHeading = now
        let f = cameraNode.simdOrientation.act(SIMD3<Float>(0, 0, -1))
        let h = Double(atan2(f.x, -f.z))
        if abs(h - heading) > 0.01 { heading = h }
    }

    /// Which way the viewer is looking right now (see `heading`), read directly.
    var currentHeading: Double {
        let f = cameraNode.simdOrientation.act(SIMD3<Float>(0, 0, -1))
        return Double(atan2(f.x, -f.z))
    }

    private func apply() {
        cameraNode.eulerAngles = SCNVector3(pitch, yaw, 0)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        guard let camera = cameraNode.camera else { return }
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        // Drag the picture with the finger: about one screen height per field of view.
        let k = Float(camera.fieldOfView * .pi / 180) / Float(max(1, view.bounds.height))
        if motion != nil {
            motionYawOffset = (motionYawOffset ?? 0) + Float(t.x) * k
        } else {
            yaw += Float(t.x) * k
            pitch = max(-Float.pi / 2 + 0.01, min(Float.pi / 2 - 0.01, pitch + Float(t.y) * k))
            apply()
        }
        publishHeading(CACurrentMediaTime(), force: g.state == .ended)
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        guard let camera = cameraNode.camera else { return }
        camera.fieldOfView = max(30, min(110, camera.fieldOfView / g.scale))
        g.scale = 1
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        let hits = view.hitTest(g.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        for hit in hits {
            if let name = hit.node.name, name.hasPrefix("stop:"), let id = Int(name.dropFirst(5)) {
                onTapMarker?(id)
                return
            }
        }
    }

    func setMotion(_ on: Bool) {
        if on, motion == nil {
            let m = CMMotionManager()
            guard m.isDeviceMotionAvailable else { return }
            m.deviceMotionUpdateInterval = 1.0 / 60
            motionYawOffset = nil
            m.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
                guard let self, let q = data?.attitude.quaternion else { return }
                // The phone's attitude has z up; the scene has y up. The back camera looks along the phone's -z.
                let attitude = simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
                let upright = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)) * attitude
                if self.motionYawOffset == nil {
                    // Keep looking where the viewer was looking when motion was turned on.
                    let f = upright.act(SIMD3<Float>(0, 0, -1))
                    self.motionYawOffset = self.yaw - atan2(-f.x, -f.z)
                }
                self.cameraNode.simdOrientation = simd_quatf(angle: self.motionYawOffset ?? 0, axis: SIMD3(0, 1, 0)) * upright
                self.publishHeading(CACurrentMediaTime())
            }
            motion = m
        } else if !on, let m = motion {
            m.stopDeviceMotionUpdates()
            motion = nil
            // Carry on from where motion left the view.
            let f = cameraNode.simdOrientation.act(SIMD3<Float>(0, 0, -1))
            yaw = atan2(-f.x, -f.z)
            pitch = asin(max(-1, min(1, f.y)))
            apply()
        }
    }

    /// Stops timers and motion updates (call when the screen goes away).
    func stop() {
        setMotion(false)
        timer?.invalidate()
        timer = nil
    }

    // MARK: Pieces

    /// A sphere seen from inside, with texture coordinates in the same convention the stitcher writes:
    /// longitude 0 (the middle of the image) is straight ahead (-z), latitude up is the top row.
    static func sphere(radius: Float) -> SCNGeometry {
        let cols = 128, rows = 64
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
        material.diffuse.contents = UIColor.black
        material.diffuse.mipFilter = .linear
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    private static func overlayMaterial(_ image: UIImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = image
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        return m
    }

    /// A chevron pointing up the image, white with a dark edge so it shows on any floor.
    private static let arrowImage: UIImage = {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 48, y: 170))
            path.addLine(to: CGPoint(x: 128, y: 70))
            path.addLine(to: CGPoint(x: 208, y: 170))
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.addPath(path)
            c.setStrokeColor(UIColor(white: 0, alpha: 0.55).cgColor)
            c.setLineWidth(58)
            c.strokePath()
            c.addPath(path)
            c.setStrokeColor(UIColor(white: 1, alpha: 0.95).cgColor)
            c.setLineWidth(40)
            c.strokePath()
        }
    }()

    private static let discImage: UIImage = {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 1, alpha: 0.35).cgColor)
            c.fillEllipse(in: CGRect(x: 10, y: 10, width: 108, height: 108))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.95).cgColor)
            c.setLineWidth(10)
            c.strokeEllipse(in: CGRect(x: 14, y: 14, width: 100, height: 100))
        }
    }()
}

struct PanoSceneView: UIViewRepresentable {
    let controller: PanoSceneController
    func makeUIView(context: Context) -> SCNView { controller.view }
    func updateUIView(_ view: SCNView, context: Context) {}
}

/// An on-screen joystick. Reports its position as x (right positive) and y (up positive), each -1…1.
struct JoystickView: View {
    var onChange: (SIMD2<Float>) -> Void
    @State private var knob = CGSize.zero
    private let radius: CGFloat = 54

    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial).frame(width: radius * 2, height: radius * 2)
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
            Circle().fill(.white.opacity(0.85)).frame(width: 46, height: 46).offset(knob)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    var v = g.translation
                    let length = hypot(v.width, v.height)
                    if length > radius {
                        v = CGSize(width: v.width * radius / length, height: v.height * radius / length)
                    }
                    knob = v
                    onChange(SIMD2(Float(v.width / radius), Float(-v.height / radius)))
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.15)) { knob = .zero }
                    onChange(SIMD2(0, 0))
                }
        )
        .accessibilityLabel("Joystick")
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
    @StateObject private var scene = PanoSceneController()

    private var file: URL { store.url(ProjectFile.panorama, in: project) }
    private var current: ScanProject { store.projects.first { $0.id == project.id } ?? project }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if building {
                ProcessingView(progress: progress, title: step)
            } else if image != nil {
                PanoSceneView(controller: scene).ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottomTrailing) {
                        // Left and right turn, up and down zoom in and out.
                        JoystickView { scene.setStick($0) }.padding(.trailing, 22).padding(.bottom, 36)
                    }
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
        .onChange(of: useMotion) { _, on in scene.setMotion(on) }
        .onDisappear { scene.stop() }
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
        if let image { scene.show(image) }
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
