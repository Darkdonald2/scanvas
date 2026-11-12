import SwiftUI
import ARKit
import RealityKit
import CoreImage

/// Guided 360 capture. Dots float around the user where photos are needed; lining the centre circle up with a
/// dot and holding still takes a full-resolution photo. ARKit tracks where the phone points (gyro plus camera),
/// and each photo is saved with that direction for the stitcher.
final class PanoramaCaptureModel: NSObject, ObservableObject, ARSessionDelegate {
    struct Target {
        let yaw: Double          // degrees, relative to where the user first faced
        let pitch: Double        // degrees, up positive
        var done = false
    }

    /// 12 at the horizon, 8 looking up, 8 looking down, then straight up and straight down. With the phone
    /// held upright the main camera sees about 54° across and 69° up and down, so neighbours overlap by
    /// about a third, which the stitcher needs to line them up.
    static func layout() -> [Target] {
        var t: [Target] = []
        for k in 0..<12 { t.append(Target(yaw: Double(k) * 30, pitch: 0)) }
        for k in 0..<8 { t.append(Target(yaw: Double(k) * 45 + 22.5, pitch: 45)) }
        for k in 0..<8 { t.append(Target(yaw: Double(k) * 45 + 22.5, pitch: -45)) }
        t.append(Target(yaw: 0, pitch: 89))
        t.append(Target(yaw: 0, pitch: -89))
        return t
    }

    @Published private(set) var targets = PanoramaCaptureModel.layout()
    @Published private(set) var shotsTaken = 0
    @Published private(set) var hold: Double = 0             // 0…1 while lined up and still
    @Published private(set) var arrow: Double?               // radians clockwise from up, toward the next dot
    @Published private(set) var started = false
    @Published private(set) var moved = false
    @Published private(set) var tooFast = false
    @Published var errorMessage: String?

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let folder: URL

    private var origin: SIMD3<Float>?
    private var yaw0: Double = 0
    private var anchor: AnchorEntity?
    private var dots: [ModelEntity] = []
    private var highlighted = -1
    private var shots: [PanoShot] = []
    private var alignedSince: TimeInterval?
    private var lastForward: SIMD3<Float>?
    private var lastTime: TimeInterval = 0
    private var busy = false
    private var exposureLocked = false
    private let writer = DispatchQueue(label: "scanvas.pano.writer", qos: .userInitiated)
    private let ciContext = CIContext()

    private static let alignDegrees = 2.5
    private static let holdSeconds = 0.4

    init(folder: URL) {
        self.folder = folder
        super.init()
    }

    var allDone: Bool { !targets.contains { !$0.done } }

    func start() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't make a folder for the photos: \(error.localizedDescription)"
            return
        }
        let config = ARWorldTrackingConfiguration()
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
        arView.session.delegate = self
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        setExposureLock(false)
        arView.session.pause()
    }

    // MARK: Directions

    /// World direction of a target (ARKit: y up, "forward" is -z).
    private func direction(_ t: Target) -> SIMD3<Float> {
        let h = yaw0 + t.yaw * .pi / 180, p = t.pitch * .pi / 180
        return SIMD3(Float(cos(p) * sin(h)), Float(sin(p)), Float(-cos(p) * cos(h)))
    }

    private func placeDots(at origin: SIMD3<Float>) {
        let a = AnchorEntity(world: origin)
        dots = targets.map { t in
            let dot = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [UnlitMaterial(color: .white)])
            dot.position = direction(t) * 1.5
            a.addChild(dot)
            return dot
        }
        arView.scene.addAnchor(a)
        anchor = a
    }

    private func paint(_ i: Int) {
        guard dots.indices.contains(i) else { return }
        let colour: UIColor = targets[i].done ? .systemGreen : (i == highlighted ? .systemYellow : .white)
        dots[i].model?.materials = [UnlitMaterial(color: colour)]
        dots[i].scale = SIMD3(repeating: targets[i].done ? 0.6 : (i == highlighted ? 1.4 : 1))
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        guard case .normal = frame.camera.trackingState else {
            alignedSince = nil
            if hold != 0 { hold = 0 }
            return
        }
        let t = frame.camera.transform
        let position = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        if origin == nil {
            origin = position
            yaw0 = atan2(Double(forward.x), Double(-forward.z))
            placeDots(at: position)
            started = true
        }
        let away = simd_distance(position, origin ?? position) > 0.3
        if away != moved { moved = away }

        // How fast the phone is turning (degrees a second).
        var speed = 0.0
        if let last = lastForward, now > lastTime {
            speed = Double(acos(max(-1, min(1, simd_dot(last, forward))))) * 180 / .pi / (now - lastTime)
        }
        lastForward = forward
        lastTime = now
        let fast = speed > 60
        if fast != tooFast { tooFast = fast }

        // The pending dot nearest to where the camera points.
        var next = -1
        var best: Float = -2
        for (i, target) in targets.enumerated() where !target.done {
            let d = simd_dot(direction(target), forward)
            if d > best { best = d; next = i }
        }
        if next != highlighted {
            let old = highlighted
            highlighted = next
            paint(old)
            paint(next)
        }
        guard next >= 0 else { arrow = nil; return }
        let off = Double(acos(max(-1, min(1, best)))) * 180 / .pi

        // An arrow when the dot is out of view. Camera axes: x along the sensor's long side, which points down
        // the screen when the phone is upright; y points to the screen's right.
        if off > 22 {
            let c = simd_transpose(simd_float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                                                 SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                                                 SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))) * direction(targets[next])
            let right = Double(c.y), up = Double(-c.x)
            arrow = atan2(right, up)
        } else if arrow != nil {
            arrow = nil
        }

        // Lined up and still: count down, then take the photo.
        if off < Self.alignDegrees && speed < 12 && !busy {
            if alignedSince == nil { alignedSince = now }
            let h = min(1, (now - (alignedSince ?? now)) / Self.holdSeconds)
            hold = h
            if h >= 1 { capture(next) }
        } else {
            alignedSince = nil
            if hold != 0 { hold = 0 }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.errorMessage = "The camera stopped: \(error.localizedDescription)" }
    }

    // MARK: Taking a photo

    private func capture(_ index: Int) {
        busy = true
        alignedSince = nil
        hold = 0
        arView.session.captureHighResolutionFrame { [weak self] frame, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let frame = frame ?? self.arView.session.currentFrame {
                    self.save(frame, for: index)
                } else {
                    self.busy = false
                }
            }
        }
    }

    private func save(_ frame: ARFrame, for index: Int) {
        let buffer = frame.capturedImage
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let sx = Double(w) / Double(res.width), sy = Double(h) / Double(res.height)
        let t = frame.camera.transform
        let r = simd_double3x3(columns: (SIMD3(Double(t.columns.0.x), Double(t.columns.0.y), Double(t.columns.0.z)),
                                         SIMD3(Double(t.columns.1.x), Double(t.columns.1.y), Double(t.columns.1.z)),
                                         SIMD3(Double(t.columns.2.x), Double(t.columns.2.y), Double(t.columns.2.z))))
        let name = String(format: "shot_%02d.jpg", shots.count)
        var shot = PanoShot(file: name, width: w, height: h,
                            fx: Double(k[0][0]) * sx, fy: Double(k[1][1]) * sy,
                            cx: Double(k[2][0]) * sx, cy: Double(k[2][1]) * sy,
                            rotation: [Double](repeating: 0, count: 9))
        shot.matrix = r

        targets[index].done = true
        paint(index)
        shotsTaken += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // The first photo sets the exposure; the rest use the same, so their brightness matches.
        if !exposureLocked { setExposureLock(true) }

        let url = folder.appendingPathComponent(name)
        let image = CIImage(cvPixelBuffer: buffer)
        writer.async { [weak self] in
            guard let self else { return }
            var ok = true
            do {
                try self.ciContext.writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                           options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                self.busy = false
                guard ok else {
                    self.targets[index].done = false
                    self.shotsTaken -= 1
                    self.paint(index)
                    return
                }
                self.shots.append(shot)
                self.writeList()
            }
        }
    }

    /// Saved after every photo, so nothing is lost if the app is closed half way.
    private func writeList() {
        let capture = PanoCapture(shots: shots)
        if let data = try? JSONEncoder().encode(capture) {
            try? data.write(to: folder.appendingPathComponent(PanoramaBuilder.listName), options: .atomic)
        }
    }

    var savedShots: Int { shots.count }
    var isSaving: Bool { busy }

    private func setExposureLock(_ on: Bool) {
        guard on != exposureLocked, let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if on {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
            device.unlockForConfiguration()
            exposureLocked = on
        } catch {}
    }
}

private struct PanoARContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct PanoramaCaptureView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PanoramaCaptureModel
    @State private var building = false
    @State private var progress = 0.0
    @State private var step = "Stitching"
    let project: ScanProject
    var onSaved: (ScanProject) -> Void

    init(project: ScanProject, onSaved: @escaping (ScanProject) -> Void) {
        self.project = project
        self.onSaved = onSaved
        let shots = ProjectStore.folder(for: project.id).appendingPathComponent(ProjectFile.panoShots, isDirectory: true)
        _model = StateObject(wrappedValue: PanoramaCaptureModel(folder: shots))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if building {
                ProcessingView(progress: progress, title: step)
            } else {
                PanoARContainer(arView: model.arView).ignoresSafeArea()
                reticle
                VStack(spacing: 10) {
                    HStack {
                        Button("Cancel") { cancel() }.buttonStyle(.bordered).tint(.white)
                        Spacer()
                        Text("\(model.shotsTaken) of \(model.targets.count)").font(.footnote.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding()
                    Text(message).font(.callout.weight(.semibold)).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(warning ? AnyShapeStyle(.orange.opacity(0.9)) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                        .padding(.horizontal)
                    Spacer()
                    Button { finish() } label: {
                        Label(model.allDone ? "Stitch" : "Finish early", systemImage: "checkmark.circle.fill").frame(maxWidth: 220)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.shotsTaken < 4)
                    .padding(.bottom, 30)
                }
            }
        }
        .onAppear {
            do { _ = try store.makeFolder(for: project) } catch { model.errorMessage = error.localizedDescription }
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.stop()
        }
        .onChange(of: model.allDone) { _, done in
            // Let the last photo finish saving, then stitch.
            if done { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { finish() } }
        }
        .alert("360 photo", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { if !building && model.shotsTaken == 0 { cancel() } }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var warning: Bool { model.moved || model.tooFast }

    private var message: String {
        if !model.started { return "Hold the phone upright and move it a little to start" }
        if model.moved { return "Stay in one spot: turn the phone, don't walk" }
        if model.tooFast { return "Turn more slowly" }
        if model.allDone { return "All done" }
        if model.arrow != nil { return "Turn toward the yellow dot" }
        if model.shotsTaken == 0 { return "Put the yellow dot in the circle and hold still" }
        return "Next dot. Turn around your phone, not your body, for the best result"
    }

    private var reticle: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.9), lineWidth: 3).frame(width: 64, height: 64)
            Circle().trim(from: 0, to: model.hold).stroke(.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 64, height: 64)
            if let a = model.arrow {
                Image(systemName: "arrow.up").font(.system(size: 34, weight: .bold)).foregroundStyle(.yellow)
                    .offset(y: -78).rotationEffect(.radians(a))
            }
        }
        .allowsHitTesting(false)
    }

    private func finish() {
        guard !building, model.shotsTaken >= 4 else { return }
        building = true
        step = "Saving the last photo"
        Task { @MainActor in
            // Wait for the last photo to be written.
            for _ in 0..<50 where model.isSaving { try? await Task.sleep(nanoseconds: 100_000_000) }
            model.stop()
            var p = project
            do {
                let report = try await PanoramaBuilder.build(folder: store.folder(for: project)) { f, s in
                    Task { @MainActor in progress = f; step = s }
                }
                p.summary = "360° · \(model.savedShots) photos · \(report.width) × \(report.width / 2)"
                store.save(p)
                onSaved(p)
                dismiss()
            } catch {
                building = false
                model.errorMessage = "Stitching failed: \(error.localizedDescription). The photos are kept; you can try again from the scan's page."
                p.summary = "360° · \(model.savedShots) photos · not stitched yet"
                store.save(p)
            }
        }
    }

    private func cancel() {
        model.stop()
        store.delete(project)
        dismiss()
    }
}

/// Stitches a capture's photos into panorama.jpg plus a thumbnail and a report. Used after capture and by
/// "Stitch again" on the panorama's page.
enum PanoramaBuilder {
    static let listName = "shots.json"

    struct Result {
        var width: Int
        var report: PanoramaStitcher.Report
    }

    static func build(folder: URL, refine: Bool = true, progress: @escaping (Double, String) -> Void) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let shotsFolder = folder.appendingPathComponent(ProjectFile.panoShots, isDirectory: true)
            let data = try Data(contentsOf: shotsFolder.appendingPathComponent(listName))
            let capture = try JSONDecoder().decode(PanoCapture.self, from: data)
            var options = PanoramaStitcher.Options()
            // 8192 wide needs about 1 GB while stitching; phones with less memory get 6144.
            options.width = ProcessInfo.processInfo.physicalMemory >= 6 << 30 ? 8192 : 6144
            options.refine = refine
            ProcessingMonitor.begin()
            ProcessingMonitor.stage("360 photo: stitching \(capture.shots.count) photos")
            defer { ProcessingMonitor.end() }
            let out = try PanoramaStitcher.stitch(folder: shotsFolder, shots: capture.shots, options: options, progress: progress)
            progress(0.98, "Saving")
            try PanoramaStitcher.writeJPEG(out.image, to: folder.appendingPathComponent(ProjectFile.panorama))
            writeThumbnail(out.image, to: folder.appendingPathComponent(ProjectFile.thumbnail))
            let text = "360 photo, stitched \(Date().formatted())\n\(out.report.summary)\n"
            try? text.write(to: folder.appendingPathComponent("processing.txt"), atomically: true, encoding: .utf8)
            return Result(width: options.width, report: out.report)
        }.value
    }

    /// The middle of the panorama (90° each way), small.
    private static func writeThumbnail(_ image: CGImage, to url: URL) {
        let w = image.width, h = image.height
        guard let crop = image.cropping(to: CGRect(x: w * 3 / 8, y: h / 4, width: w / 4, height: h / 2)) else { return }
        let size = 400
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let small = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
    }
}
