import Foundation
import ARKit
import RealityKit
import Combine
import CoreImage
import ImageIO
import SwiftUI

/// A label pinned to a 3D point, drawn by SwiftUI over the camera view.
struct ScreenLabel: Identifiable {
    let id: String
    var point: CGPoint
    var text: String
    var color: Color
}

/// What the readout panel shows; refreshed about 15 times a second.
struct TraceHUD {
    var hasAim = false
    var steady = false
    var distance: Float = 0
    var segmentLength: Float?
    var segmentFall: Float?
    var segmentGradient: Float?
    var segmentStatus: PipeSegment.Status?
    var aboveFloor: Float?
    var belowCeiling: Float?
    var runLength: Float = 0
}

/// Traces drainage pipes: aims with LiDAR depth at the screen centre, steadies the reading,
/// places points on the pipe centre line, sizes the pipe and takes survey photos.
final class PipeTracer: ObservableObject {
    let scanner = MeshScanner()

    @Published var survey = PipeSurvey()
    @Published var currentRun = 0
    @Published var kind: PipePoint.Kind = .point
    @Published var hud = TraceHUD()
    @Published var labels: [ScreenLabel] = []
    @Published var toast: String?
    @Published var sizing = false
    @Published var edgeStep = 0          // 0 = off, 1 = waiting for first edge, 2 = waiting for second
    @Published var snapToCentre = true
    @Published var photosTaken = 0

    /// Folder of the project being captured (photos are written into it).
    var folder: URL?

    private var history: [(t: TimeInterval, hit: SIMD3<Float>, dir: SIMD3<Float>)] = []
    private var aimHit: SIMD3<Float>?
    private var rayDir = SIMD3<Float>(0, 0, -1)
    private var cameraPos = SIMD3<Float>(repeating: 0)
    private var sizeSamples: [Float] = []
    private var sizeStarted: TimeInterval = 0
    private var edgeFirst: SIMD3<Float>?
    private var lastHUD: TimeInterval = 0
    private var nextPhoto = 0
    private var toastTask: DispatchWorkItem?
    private var bag: Set<AnyCancellable> = []

    private let root = AnchorEntity(world: .zero)
    private let pipesEntity = Entity()
    private let band = ModelEntity(mesh: .generateBox(size: 1), materials: [UnlitMaterial(color: .white)])
    private let marker = ModelEntity(mesh: .generateSphere(radius: 0.01), materials: [UnlitMaterial(color: .white)])
    private var bandStatus: PipeSegment.Status?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let photoQueue = DispatchQueue(label: "scanvas.pipephotos", qos: .userInitiated)

    init() {
        let metric = UnitSystem.current == .metric
        survey.runs = [PipeRun(name: "WP-1", system: "WP", diameter: metric ? 0.110 : 0.114)]
        scanner.detectPlanes = true
        scanner.maxKeyframes = 500
        scanner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        scanner.arView.scene.addAnchor(root)
        root.addChild(pipesEntity)
        band.isEnabled = false
        root.addChild(band)
        root.addChild(marker)
        marker.isEnabled = false
        scanner.frameHandler = { [weak self] frame in self?.update(frame) }
    }

    var run: PipeRun { survey.runs[min(currentRun, survey.runs.count - 1)] }
    private var radius: Float { max(run.diameter / 2, 0.005) }
    private var units: UnitSystem { UnitSystem.current }

    /// The point that would be added now: on the pipe centre line, or snapped onto an existing point.
    private func candidate() -> (SIMD3<Float>, PipePoint?)? {
        guard let hit = aimHit else { return nil }
        let p = snapToCentre ? hit + rayDir * radius : hit
        let lastID = run.points.last?.id
        var best: (PipePoint, Float)?
        for (ri, r) in survey.runs.enumerated() {
            for q in r.points where !(ri == currentRun && q.id == lastID) {
                let d = simd_distance(q.position, p)
                if d < 0.08 && (best == nil || d < best!.1) { best = (q, d) }
            }
        }
        if let b = best { return (b.0.position, b.0) }
        return (p, nil)
    }

    // MARK: Frame updates

    private func update(_ frame: ARFrame) {
        let now = frame.timestamp
        let t = frame.camera.transform
        cameraPos = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        if case .normal = frame.camera.trackingState, let s = depthSample(frame) ?? raycastSample() {
            history.append((now, s.0, s.1))
        }
        history.removeAll { now - $0.t > 0.35 }
        var steady = false
        if history.isEmpty {
            aimHit = nil
        } else {
            let xs = history.map { $0.hit.x }.sorted(), ys = history.map { $0.hit.y }.sorted(), zs = history.map { $0.hit.z }.sorted()
            let m = history.count / 2
            let med = SIMD3(xs[m], ys[m], zs[m])
            let spread = history.map { simd_distance($0.hit, med) }.max() ?? 1
            aimHit = med
            rayDir = simd_normalize(history.reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.dir })
            steady = history.count >= 4 && spread < 0.008
        }
        if sizing, let w = diameterSample(frame) { sizeSamples.append(w) }
        if sizing && (sizeSamples.count >= 12 || now - sizeStarted > 3) { finishSizing() }
        if !survey.floorMeasured, let f = scanner.floorEstimate { survey.floorY = f }
        if let c = scanner.ceilingEstimate, survey.ceilingY != c { survey.ceilingY = c }
        updateBand()
        if now - lastHUD > 0.066 {
            lastHUD = now
            refreshHUD(steady: steady)
        }
    }

    /// Median LiDAR depth around the screen centre, unprojected to a world point.
    private func depthSample(_ frame: ARFrame) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth, case let (u, v)? = centrePixel(frame, depth.depthMap) else { return nil }
        let map = depth.depthMap
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map)?.assumingMemoryBound(to: Float32.self) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(map) / 4
        var conf: UnsafeMutablePointer<UInt8>?
        var confStride = 0
        if let c = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(c, .readOnly)
            conf = CVPixelBufferGetBaseAddress(c)?.assumingMemoryBound(to: UInt8.self)
            confStride = CVPixelBufferGetBytesPerRow(c)
        }
        defer { if let c = depth.confidenceMap { CVPixelBufferUnlockBaseAddress(c, .readOnly) } }
        let ui = Int(u), vi = Int(v)
        var zs: [Float] = []
        for dy in -2...2 {
            for dx in -2...2 {
                let x = ui + dx, y = vi + dy
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                if let conf, conf[y * confStride + x] < 1 { continue }
                let z = base[y * stride + x]
                if z > 0.1 && z < 6 { zs.append(z) }
            }
        }
        guard zs.count >= 5 else { return nil }
        zs.sort()
        let p = unproject(frame, u, v, zs[zs.count / 2], w, h)
        return (p, simd_normalize(p - cameraPos))
    }

    private func raycastSample() -> (SIMD3<Float>, SIMD3<Float>)? {
        let view = scanner.arView
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let r = view.raycast(from: centre, allowing: .estimatedPlane, alignment: .any).first else { return nil }
        let p = SIMD3(r.worldTransform.columns.3.x, r.worldTransform.columns.3.y, r.worldTransform.columns.3.z)
        return (p, simd_normalize(p - cameraPos))
    }

    /// Depth-map pixel under the screen centre.
    private func centrePixel(_ frame: ARFrame, _ map: CVPixelBuffer) -> (Float, Float)? {
        let view = scanner.arView
        guard view.bounds.width > 0 else { return nil }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let toView = frame.displayTransform(for: orientation, viewportSize: view.bounds.size)
        let n = CGPoint(x: 0.5, y: 0.5).applying(toView.inverted())
        return (Float(n.x) * Float(CVPixelBufferGetWidth(map)), Float(n.y) * Float(CVPixelBufferGetHeight(map)))
    }

    private func unproject(_ frame: ARFrame, _ u: Float, _ v: Float, _ z: Float, _ w: Int, _ h: Int) -> SIMD3<Float> {
        let res = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy, cx = k[2][0] * sx, cy = k[2][1] * sy
        let cam = SIMD4<Float>((u - cx) / fx * z, -(v - cy) / fy * z, -z, 1)
        let p = frame.camera.transform * cam
        return SIMD3(p.x, p.y, p.z)
    }

    /// Pipe width from where the depth jumps away behind the pipe, across and along the screen.
    private func diameterSample(_ frame: ARFrame) -> Float? {
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth, case let (u, v)? = centrePixel(frame, depth.depthMap) else { return nil }
        let map = depth.depthMap
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map)?.assumingMemoryBound(to: Float32.self) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(map) / 4
        let ui = Int(u), vi = Int(v)
        guard ui > 0, ui < w, vi > 0, vi < h else { return nil }
        let z0 = base[vi * stride + ui]
        guard z0 > 0.1 && z0 < 4 else { return nil }
        func edge(_ dx: Int, _ dy: Int) -> (Int, Int, Float)? {
            var lx = ui, ly = vi, lz = z0
            for k in 1...70 {
                let x = ui + dx * k, y = vi + dy * k
                guard x >= 0, x < w, y >= 0, y < h else { return nil }
                let z = base[y * stride + x]
                if z > lz + 0.05 { return (lx, ly, lz) }   // background behind the pipe
                if z < z0 - 0.06 { return nil }           // something in front
                lx = x; ly = y; lz = z
            }
            return nil
        }
        let res = frame.camera.imageResolution
        let fx = frame.camera.intrinsics[0][0] * Float(w) / Float(res.width)
        var widths: [Float] = []
        for (dx, dy) in [(1, 0), (0, 1)] {
            guard let a = edge(dx, dy), let b = edge(-dx, -dy) else { continue }
            let pa = unproject(frame, Float(a.0), Float(a.1), a.2, w, h), pb = unproject(frame, Float(b.0), Float(b.1), b.2, w, h)
            widths.append(simd_distance(pa, pb) + z0 / fx)
        }
        return widths.min()
    }

    // MARK: Actions

    func addPoint() {
        if edgeStep > 0 { recordEdge(); return }
        guard case let (p, joined)? = candidate() else { show("Aim the circle at the pipe"); return }
        var point = PipePoint(position: p, kind: kind)
        if let joined, kind == .point, joined.kind == .point { point.kind = .wye }
        survey.runs[currentRun].points.append(point)
        kind = .point
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if joined != nil {
            show("Joined to an existing pipe")
        } else if !hud.steady {
            show("Tip: hold still for a moment for the most accurate point")
        }
        rebuild()
    }

    func undo() {
        if !survey.runs[currentRun].points.isEmpty {
            survey.runs[currentRun].points.removeLast()
        } else if survey.runs.count > 1 {
            survey.runs.remove(at: currentRun)
            currentRun = survey.runs.count - 1
        }
        rebuild()
    }

    func newRun(system: String) {
        let n = survey.runs.filter { $0.system == system }.count + 1
        if run.points.isEmpty {
            survey.runs[currentRun].system = system
            survey.runs[currentRun].name = "\(system)-\(n)"
        } else {
            survey.runs.append(PipeRun(name: "\(system)-\(n)", system: system, diameter: run.diameter))
            currentRun = survey.runs.count - 1
        }
        show("Started \(run.name). Begin at its upstream end.")
        rebuild()
    }

    func select(run index: Int) {
        currentRun = index
        show("Continuing \(run.name)")
        rebuild()
    }

    func setDiameter(_ d: Float) {
        survey.runs[currentRun].diameter = d
        show("\(run.name): " + units.diameter(d))
        rebuild()
    }

    func startSizing() {
        sizeSamples = []
        sizeStarted = (scanner.arView.session.currentFrame?.timestamp ?? 0)
        sizing = true
        show("Hold the circle on the pipe…")
    }

    private func finishSizing() {
        sizing = false
        guard sizeSamples.count >= 4 else {
            show("Couldn't see both edges of the pipe. Use “Tap both edges” instead.")
            return
        }
        let sorted = sizeSamples.sorted()
        applyMeasuredDiameter(sorted[sorted.count / 2])
    }

    func startEdges() {
        edgeFirst = nil
        edgeStep = 1
        show("Aim at one side edge of the pipe and tap +")
    }

    private func recordEdge() {
        guard let hit = aimHit else { show("Aim at the pipe edge"); return }
        if edgeStep == 1 {
            edgeFirst = hit
            edgeStep = 2
            show("Now the opposite edge, and tap +")
        } else if let first = edgeFirst {
            edgeStep = 0
            applyMeasuredDiameter(simd_distance(first, hit))
        }
    }

    private func applyMeasuredDiameter(_ raw: Float) {
        let presets = (units == .metric ? PipeSize.metric : PipeSize.imperial).map { $0.1 }
        let nearest = presets.min { abs($0 - raw) < abs($1 - raw) } ?? raw
        let d = abs(nearest - raw) / nearest < 0.2 ? nearest : (raw * 1000).rounded() / 1000
        survey.runs[currentRun].diameter = d
        show("Measured \(units.diameter(raw)) → using \(units.diameter(d))")
        rebuild()
    }

    func setFloorHere() {
        guard let hit = aimHit else { show("Aim at the floor"); return }
        survey.floorY = hit.y
        survey.floorMeasured = true
        show("Floor level set")
    }

    func setCeilingHere() {
        guard let hit = aimHit else { show("Aim at the soffit"); return }
        survey.ceilingY = hit.y
        show("Soffit level set")
    }

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    // MARK: Photos

    /// Takes a full-resolution photo and keeps the camera pose so the pipe lines can be drawn on it later.
    func takePhoto() {
        guard let folder else { return }
        let orientation = scanner.arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let rotation: Int
        switch orientation {
        case .landscapeRight: rotation = 0
        case .landscapeLeft: rotation = 180
        case .portraitUpsideDown: rotation = 270
        default: rotation = 90
        }
        let target = aimHit
        var pointID: UUID?
        if let t = target,
           let near = survey.allPoints.min(by: { simd_distance($0.position, t) < simd_distance($1.position, t) }),
           simd_distance(near.position, t) < 0.6 {
            pointID = near.id
        }
        let index = nextPhoto
        nextPhoto += 1
        let caption = run.name + (run.points.isEmpty ? "" : " · P\(run.points.count)")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        scanner.arView.session.captureHighResolutionFrame { [weak self] frame, _ in
            DispatchQueue.main.async {
                guard let self, let f = frame ?? self.scanner.arView.session.currentFrame else { return }
                self.save(f, index: index, rotation: rotation, target: target, point: pointID, caption: caption, folder: folder)
            }
        }
    }

    private func save(_ frame: ARFrame, index: Int, rotation: Int, target: SIMD3<Float>?, point: UUID?, caption: String, folder: URL) {
        let buffer = frame.capturedImage
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let res = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        let file = "\(ProjectFile.pipePhotos)/photo_\(index).jpg"
        var photo = PipePhoto(file: file, worldToCamera: frame.camera.transform.inverse,
                              fx: k[0][0] * sx, fy: k[1][1] * sy, cx: k[2][0] * sx, cy: k[2][1] * sy,
                              sensorWidth: w, sensorHeight: h, rotation: rotation)
        photo.caption = caption
        photo.target = target
        photo.point = point
        let orientation: CGImagePropertyOrientation = rotation == 90 ? .right : rotation == 180 ? .down : rotation == 270 ? .left : .up
        let url = folder.appendingPathComponent(file)
        let context = ciContext
        photoQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9]
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let data = context.jpegRepresentation(of: image, colorSpace: space, options: options),
                  (try? data.write(to: url)) != nil else { return }
            DispatchQueue.main.async {
                self.survey.photos.append(photo)
                self.photosTaken = self.survey.photos.count
                self.show("Photo saved (\(w)×\(h))")
            }
        }
    }

    /// Waits for photos still being written.
    func flushPhotos() { photoQueue.sync {} }

    // MARK: AR preview

    private func entity(_ m: MeshData, color: UIColor) -> ModelEntity? {
        guard !m.isEmpty else { return nil }
        var d = MeshDescriptor(name: "pipe")
        d.positions = MeshBuffers.Positions(m.positions)
        d.normals = MeshBuffers.Normals(m.normals)
        d.primitives = .triangles(m.indices)
        guard let resource = try? MeshResource.generate(from: [d]) else { return nil }
        return ModelEntity(mesh: resource, materials: [UnlitMaterial(color: color)])
    }

    private static func uiColor(_ c: SIMD3<Float>) -> UIColor { UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1) }

    /// Rebuilds the thin centre-line tubes shown over the real pipes, coloured by fall.
    func rebuild() {
        for child in Array(pipesEntity.children) { child.removeFromParent() }
        var buckets: [PipeSegment.Status: MeshData] = [:]
        var joints: [String: MeshData] = [:]
        for run in survey.runs {
            let r = max(0.006, run.diameter * 0.15)
            for s in run.segments {
                let st = s.status(minFall: survey.minFall)
                PipeGeometry.tube(s.from.position, s.to.position, radius: r, color: .zero, into: &buckets[st, default: MeshData()])
            }
            for p in run.points {
                let key = p.kind == .point ? run.system : "fitting"
                PipeGeometry.sphere(p.position, radius: p.kind == .point ? r * 2 : r * 3, color: .zero, into: &joints[key, default: MeshData()])
            }
        }
        for (st, m) in buckets {
            if let e = entity(m, color: Self.uiColor(PipeGeometry.statusColor(st))) { pipesEntity.addChild(e) }
        }
        for (key, m) in joints {
            let c = key == "fitting" ? UIColor.white : Self.uiColor(PipeSystem.color(key))
            if let e = entity(m, color: c) { pipesEntity.addChild(e) }
        }
    }

    private func updateBand() {
        guard case let (p, _)? = candidate() else { band.isEnabled = false; marker.isEnabled = false; return }
        marker.isEnabled = true
        marker.position = p
        guard edgeStep == 0, let last = run.points.last else { band.isEnabled = false; return }
        let v = p - last.position
        let len = simd_length(v)
        guard len > 0.01 else { band.isEnabled = false; return }
        band.isEnabled = true
        let thick = max(0.006, run.diameter * 0.12)
        band.position = (p + last.position) / 2
        band.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: v / len)
        band.scale = SIMD3(thick, thick, len)
        let status = PipeSegment(from: last, to: PipePoint(position: p)).status(minFall: survey.minFall)
        if status != bandStatus {
            bandStatus = status
            band.model?.materials = [UnlitMaterial(color: Self.uiColor(PipeGeometry.statusColor(status)).withAlphaComponent(0.9))]
        }
    }

    private func refreshHUD(steady: Bool) {
        var h = TraceHUD()
        let cand = candidate()
        h.hasAim = cand != nil
        h.steady = steady
        h.runLength = run.length
        if case let (p, _)? = cand {
            h.distance = aimHit.map { simd_distance($0, cameraPos) } ?? 0
            if let last = run.points.last, edgeStep == 0 {
                let s = PipeSegment(from: last, to: PipePoint(position: p))
                h.segmentLength = s.length
                h.segmentFall = s.fallPercent
                h.segmentGradient = s.gradient
                h.segmentStatus = s.status(minFall: survey.minFall)
            }
            if survey.floorMeasured || scanner.floorEstimate != nil { h.aboveFloor = p.y - survey.floorY }
            if let c = survey.ceilingY { h.belowCeiling = c - (p.y + radius) }
        }
        hud = h

        // Labels on every nearby segment, plus the live one.
        let view = scanner.arView
        var out: [ScreenLabel] = []
        for run in survey.runs {
            for (i, s) in run.segments.enumerated() {
                let mid = (s.from.position + s.to.position) / 2
                guard simd_distance(mid, cameraPos) < 8, let pt = view.project(mid), view.bounds.contains(pt) else { continue }
                let st = s.status(minFall: survey.minFall)
                let text = units.length(s.length) + (st == .vertical ? " ↓" : " · " + units.fall(s.fallPercent))
                out.append(ScreenLabel(id: "\(run.id)-\(i)", point: pt, text: text, color: Self.statusSwiftUI(st)))
            }
            for p in run.points where p.kind != .point {
                guard simd_distance(p.position, cameraPos) < 8, let pt = view.project(p.position), view.bounds.contains(pt) else { continue }
                out.append(ScreenLabel(id: p.id.uuidString, point: CGPoint(x: pt.x, y: pt.y - 22), text: p.kind.code, color: .white.opacity(0.9)))
            }
        }
        if case let (p, _)? = cand, let last = run.points.last, let len = h.segmentLength, edgeStep == 0,
           let pt = view.project((p + last.position) / 2), view.bounds.contains(pt) {
            let text = units.length(len) + " · " + units.fall(h.segmentFall ?? 0)
            out.append(ScreenLabel(id: "live", point: pt, text: text, color: Self.statusSwiftUI(h.segmentStatus ?? .good)))
        }
        labels = out
    }

    static func statusSwiftUI(_ s: PipeSegment.Status) -> Color {
        let c = PipeGeometry.statusColor(s)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}
