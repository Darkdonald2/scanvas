import ARKit
import RealityKit
import CoreImage
import UIKit
import simd

/// A downscaled camera image plus depth, kept during a scan so the mesh can be coloured afterwards.
struct Keyframe {
    static let width = 256, height = 192
    var rgb: [UInt8]              // width × height × 3
    var depth: [Float32]          // width × height, metres (empty if unavailable)
    var worldToCamera: simd_float4x4
    var cameraPosition: SIMD3<Float>
    var fx: Float, fy: Float, cx: Float, cy: Float
    /// Index of the sharp photo saved for this keyframe (`photo_<n>.jpg`), or −1.
    var photo = -1
    /// Image sharpness (variance of the Laplacian); low means motion blur.
    var sharpness: Float = 1

    static let photoWidth = 1600, photoHeight = 1200
    static func photoName(_ n: Int) -> String { "photo_\(n).jpg" }
}

/// Large-space LiDAR scanning: ARKit scene reconstruction with live mesh, keyframes for colour.
final class MeshScanner: NSObject, ObservableObject, ARSessionDelegate {
    @Published var triangleCount = 0
    @Published var trackingMessage: String?
    @Published var isScanning = false
    @Published var keyframeCount = 0
    @Published var elapsed: TimeInterval = 0
    /// True while the phone moves or turns too fast for sharp photos.
    @Published var tooFast = false

    let arView: ARView
    var captureColour = true
    var maxKeyframes = 700

    private var keyframes: [Keyframe] = []
    private var lastKeyTransform: simd_float4x4?
    private var lastKeyTime: TimeInterval = 0
    private var lastStatsTime: TimeInterval = 0
    private var startTime = Date()
    private let lock = NSLock()
    /// Where sharp photos are written while scanning (nil = colour only).
    var photoDirectory: URL?
    private var photoCount = 0
    /// Every mesh anchor seen so far. Kept here so the scan survives the app being paused
    /// (screenshot, notification, app switcher), when ARKit can drop anchors from the session.
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private let anchorLock = NSLock()
    private var sharpnessMean: Float = 0
    private var motionPose: simd_float4x4?
    private var motionTime: TimeInterval = 0
    private var linearSpeed: Float = 0, angularSpeed: Float = 0
    private var fastSince: TimeInterval?, slowSince: TimeInterval?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let photoQueue = DispatchQueue(label: "scanvas.photos", qos: .utility)

    static var isSupported: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        super.init()
        arView.session.delegate = self
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion, .disableGroundingShadows]
        arView.environment.sceneUnderstanding.options = []
        arView.debugOptions = [.showSceneUnderstanding]
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.environmentTexturing = .none
        config.worldAlignment = .gravity
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        startTime = Date()
        isScanning = true
    }

    func stop() {
        isScanning = false
        arView.session.pause()
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { remember(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { remember(anchors) }

    private func remember(_ anchors: [ARAnchor]) {
        guard isScanning else { return }
        anchorLock.lock()
        for case let a as ARMeshAnchor in anchors { meshAnchors[a.identifier] = a }
        anchorLock.unlock()
    }

    /// Smoothed walking and turning speed; flags "too fast" after it lasts a moment, clears after it calms down.
    private func trackSpeed(_ t: simd_float4x4, _ now: TimeInterval) {
        defer { motionPose = t; motionTime = now }
        guard isScanning, let last = motionPose, now > motionTime else { return }
        let dt = Float(now - motionTime)
        let moved = simd_distance(SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), SIMD3(last.columns.3.x, last.columns.3.y, last.columns.3.z))
        let f0 = SIMD3(last.columns.2.x, last.columns.2.y, last.columns.2.z), f1 = SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let turned = acos(min(1, max(-1, simd_dot(f0, f1))))
        linearSpeed = linearSpeed * 0.85 + (moved / dt) * 0.15
        angularSpeed = angularSpeed * 0.85 + (turned / dt) * 0.15
        let fast = linearSpeed > 0.55 || angularSpeed > 0.9      // ~0.55 m/s or ~50°/s
        if fast { slowSince = nil; if fastSince == nil { fastSince = now } } else { fastSince = nil; if slowSince == nil { slowSince = now } }
        let warn: Bool
        if tooFast { warn = !(slowSince.map { now - $0 > 0.6 } ?? false) } else { warn = fastSince.map { now - $0 > 0.25 } ?? false }
        if warn != tooFast { DispatchQueue.main.async { self.tooFast = warn } }
    }

    /// Ask ARKit to find its old position after an interruption, so new mesh lines up with the old.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        trackSpeed(frame.camera.transform, now)
        if now - lastStatsTime > 0.5 {
            lastStatsTime = now
            anchorLock.lock()
            let tris = meshAnchors.values.reduce(0) { $0 + $1.geometry.faces.count }
            anchorLock.unlock()
            let message = Self.message(for: frame.camera.trackingState)
            let kf = keyframes.count
            DispatchQueue.main.async {
                self.triangleCount = tris
                self.trackingMessage = message
                self.keyframeCount = kf
                self.elapsed = Date().timeIntervalSince(self.startTime)
            }
        }
        guard isScanning, captureColour, case .normal = frame.camera.trackingState else { return }
        let t = frame.camera.transform
        if let last = lastKeyTransform {
            let moved = simd_distance(SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                                      SIMD3(last.columns.3.x, last.columns.3.y, last.columns.3.z))
            let turned = acos(min(1, max(-1, simd_dot(SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z),
                                                       SIMD3(last.columns.2.x, last.columns.2.y, last.columns.2.z)))))
            guard now - lastKeyTime > 0.2, moved > 0.1 || turned > 0.1 else { return }
        }
        guard var kf = Self.makeKeyframe(frame) else { return }
        // Skip motion-blurred frames unless it has been a while since the last photo.
        if sharpnessMean > 0 && kf.sharpness < sharpnessMean * 0.6 && now - lastKeyTime < 1.5 { return }
        sharpnessMean = sharpnessMean == 0 ? kf.sharpness : sharpnessMean * 0.9 + kf.sharpness * 0.1
        lastKeyTransform = t
        lastKeyTime = now
        do {
            if let dir = photoDirectory, let cg = photo(from: frame) {
                kf.photo = photoCount
                let url = dir.appendingPathComponent(Keyframe.photoName(photoCount))
                photoCount += 1
                photoQueue.async {
                    try? UIImage(cgImage: cg).jpegData(compressionQuality: 0.88)?.write(to: url)
                }
            }
            lock.lock()
            keyframes.append(kf)
            if keyframes.count > maxKeyframes {
                // Keep coverage across the whole scan: drop every other old keyframe.
                keyframes = keyframes.enumerated().filter { $0.offset % 2 == 0 || $0.offset > keyframes.count - 20 }.map { $0.element }
            }
            lock.unlock()
        }
    }

    /// The camera image scaled to 1280×960 (same framing as the keyframe).
    private func photo(from frame: ARFrame) -> CGImage? {
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        let sx = CGFloat(Keyframe.photoWidth) / image.extent.width, sy = CGFloat(Keyframe.photoHeight) / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return ciContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: Keyframe.photoWidth, height: Keyframe.photoHeight))
    }

    /// Waits for pending photo writes and returns the keyframes that have photos.
    func photoKeyframes() -> [Keyframe] {
        photoQueue.sync {}
        lock.lock(); defer { lock.unlock() }
        return keyframes.filter { $0.photo >= 0 }
    }

    static func message(for state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal: return nil
        case .notAvailable: return "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "Slow down"
            case .insufficientFeatures: return "Point at more detail or turn on lights"
            case .initializing: return "Move your phone slowly to start"
            case .relocalizing: return "Go back to where you were to resume"
            @unknown default: return "Tracking limited"
            }
        }
    }

    /// Downsamples the YCbCr camera image to 256×192 RGB and copies the depth map.
    static func makeKeyframe(_ frame: ARFrame) -> Keyframe? {
        let pb = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let W = CVPixelBufferGetWidthOfPlane(pb, 0), H = CVPixelBufferGetHeightOfPlane(pb, 0)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let w = Keyframe.width, h = Keyframe.height
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for j in 0..<h {
            let sy = min(H - 1, j * H / h)
            for i in 0..<w {
                let sx = min(W - 1, i * W / w)
                let Y = Float(yBase[sy * yStride + sx])
                let cIndex = (sy / 2) * cStride + (sx / 2) * 2
                let cb = Float(cBase[cIndex]) - 128, cr = Float(cBase[cIndex + 1]) - 128
                let o = (j * w + i) * 3
                rgb[o] = UInt8(max(0, min(255, Y + 1.402 * cr)))
                rgb[o + 1] = UInt8(max(0, min(255, Y - 0.344136 * cb - 0.714136 * cr)))
                rgb[o + 2] = UInt8(max(0, min(255, Y + 1.772 * cb)))
            }
        }

        var depth: [Float32] = []
        if let dm = frame.sceneDepth?.depthMap ?? frame.smoothedSceneDepth?.depthMap,
           CVPixelBufferGetPixelFormatType(dm) == kCVPixelFormatType_DepthFloat32 {
            CVPixelBufferLockBaseAddress(dm, .readOnly)
            let dw = CVPixelBufferGetWidth(dm), dh = CVPixelBufferGetHeight(dm)
            let stride = CVPixelBufferGetBytesPerRow(dm)
            if let base = CVPixelBufferGetBaseAddress(dm) {
                depth = [Float32](repeating: 0, count: w * h)
                for j in 0..<h {
                    let row = (base + min(dh - 1, j * dh / h) * stride).assumingMemoryBound(to: Float32.self)
                    for i in 0..<w { depth[j * w + i] = row[min(dw - 1, i * dw / w)] }
                }
            }
            CVPixelBufferUnlockBaseAddress(dm, .readOnly)
        }

        // Sharpness: variance of the Laplacian of the green channel.
        var sum: Float = 0, sum2: Float = 0, n: Float = 0
        for j in 1..<(h - 1) {
            for i in 1..<(w - 1) {
                let o = (j * w + i) * 3 + 1
                let lap = 4 * Float(rgb[o]) - Float(rgb[o - 3]) - Float(rgb[o + 3]) - Float(rgb[o - w * 3]) - Float(rgb[o + w * 3])
                sum += lap; sum2 += lap * lap; n += 1
            }
        }
        let sharpness = max(1, sum2 / n - (sum / n) * (sum / n))

        let k = frame.camera.intrinsics
        let sx = Float(w) / Float(W), sy = Float(h) / Float(H)
        let t = frame.camera.transform
        return Keyframe(rgb: rgb, depth: depth, worldToCamera: t.inverse,
                        cameraPosition: SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                        fx: k[0][0] * sx, fy: k[1][1] * sy, cx: k[2][0] * sx, cy: k[2][1] * sy, sharpness: sharpness)
    }

    // MARK: Building the result

    /// Collects every mesh anchor into one world-space mesh.
    func collectMesh() -> MeshData {
        // Latest copy of every anchor: from the live session when it has them, else the ones we kept.
        anchorLock.lock()
        var byID = meshAnchors
        anchorLock.unlock()
        for case let a as ARMeshAnchor in arView.session.currentFrame?.anchors ?? [] { byID[a.identifier] = a }
        let anchors = Array(byID.values)
        var mesh = MeshData()
        for a in anchors { mesh.append(Self.meshData(from: a)) }
        return mesh
    }

    static func meshData(from anchor: ARMeshAnchor) -> MeshData {
        let g = anchor.geometry
        let t = anchor.transform
        var m = MeshData()
        let v = g.vertices, n = g.normals
        m.positions.reserveCapacity(v.count)
        let vp = v.buffer.contents() + v.offset
        for i in 0..<v.count {
            let p = (vp + i * v.stride).assumingMemoryBound(to: Float.self)
            let w = t * SIMD4(p[0], p[1], p[2], 1)
            m.positions.append(SIMD3(w.x, w.y, w.z))
        }
        let np = n.buffer.contents() + n.offset
        let rot = simd_float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                                SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                                SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        if n.count == v.count {
            for i in 0..<n.count {
                let p = (np + i * n.stride).assumingMemoryBound(to: Float.self)
                m.normals.append(simd_normalize(rot * SIMD3(p[0], p[1], p[2])))
            }
        }
        let f = g.faces
        let fp = f.buffer.contents()
        m.indices.reserveCapacity(f.count * 3)
        for i in 0..<(f.count * f.indexCountPerPrimitive) {
            if f.bytesPerIndex == 4 {
                m.indices.append(fp.load(fromByteOffset: i * 4, as: UInt32.self))
            } else {
                m.indices.append(UInt32(fp.load(fromByteOffset: i * 2, as: UInt16.self)))
            }
        }
        if let c = g.classification, c.count == f.count {
            let cp = c.buffer.contents() + c.offset
            for i in 0..<c.count { m.faceClasses.append(cp.load(fromByteOffset: i * c.stride, as: UInt8.self)) }
        }
        return m
    }

    /// Colours each vertex from the keyframes that saw it best (visible in depth, facing the camera, closest).
    func colourize(_ mesh: inout MeshData, progress: (Double) -> Void) {
        lock.lock(); let frames = keyframes; lock.unlock()
        guard !frames.isEmpty else { return }
        let w = Keyframe.width, h = Keyframe.height
        var colors = [SIMD3<UInt8>](repeating: SIMD3(170, 170, 170), count: mesh.vertexCount)
        let hasNormals = mesh.hasNormals
        for i in 0..<mesh.vertexCount {
            if i % 20000 == 0 { progress(Double(i) / Double(max(1, mesh.vertexCount))) }
            let p = mesh.positions[i]
            var best: Float = 0
            var found = 0
            for kf in frames.reversed() {
                let c = kf.worldToCamera * SIMD4(p, 1)
                let z = -c.z
                guard z > 0.1 else { continue }
                let u = kf.fx * c.x / z + kf.cx
                let v = kf.cy - kf.fy * c.y / z
                guard u >= 0, v >= 0, u < Float(w - 1), v < Float(h - 1) else { continue }
                let ui = Int(u), vi = Int(v)
                if !kf.depth.isEmpty {
                    let d = kf.depth[vi * w + ui]
                    if d > 0 && abs(d - z) > 0.04 + 0.02 * z { continue }
                }
                var facing: Float = 1
                if hasNormals {
                    let toCam = simd_normalize(kf.cameraPosition - p)
                    facing = simd_dot(mesh.normals[i], toCam)
                    if facing < 0.15 { continue }
                }
                let score = facing / (0.3 + z)
                if score > best {
                    best = score
                    let o = (vi * w + ui) * 3
                    colors[i] = SIMD3(kf.rgb[o], kf.rgb[o + 1], kf.rgb[o + 2])
                }
                found += 1
                if found >= 4 { break }
            }
        }
        mesh.colors = colors
        progress(1)
    }

    func clearKeyframes() {
        lock.lock(); keyframes.removeAll(); lock.unlock()
    }
}
