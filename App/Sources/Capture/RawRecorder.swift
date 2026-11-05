import ARKit
import CoreImage
import UIKit
import simd

/// "Raw capture" for processing on a computer: while scanning, writes many more full-resolution photos than the
/// phone itself uses, each with its LiDAR depth, depth confidence, exact camera pose and lens values, straight to
/// disk (nothing is kept in memory). Scanvas Studio on a Mac or PC turns this into a denser, sharper model.
///
/// Folder layout (format "scanvas-raw", version 1):
///   capture.json            what was captured and how
///   frames.jsonl            one JSON object per frame (pose, intrinsics, exposure, nearby anchor poses,
///                           the path anchors near the camera, mapping state and how fast the phone was moving)
///   images/000000.jpg       camera photo, full camera resolution
///   depth/000000.bin        LiDAR depth, Float32 metres, depthWidth × depthHeight, row-major
///   confidence/000000.bin   LiDAR confidence, UInt8 0 low / 1 medium / 2 high
///   anchors.json            final pose of every mesh anchor (to undo tracking drift on old frames)
///   pose_anchors.json       final pose of every path anchor (dropped on the camera's path about once a second)
///   arkit_mesh.ply          the phone's own LiDAR mesh, for reference
final class RawRecorder {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "rawCapture") as? Bool ?? false }
    static var use4K: Bool { UserDefaults.standard.object(forKey: "raw4K") as? Bool ?? false }
    static let folderName = "Raw"

    let folder: URL
    private(set) var frameCount = 0
    private(set) var skipped = 0
    private(set) var blurred = 0
    private(set) var bytes: Int64 = 0
    private var imageSize = CGSize.zero
    private var depthSize = (0, 0)
    private var lastTime: TimeInterval = -10
    private var lastPose: simd_float4x4?
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "scanvas.raw", qos: .userInitiated)
    /// Photos waiting to be encoded hold ARKit's camera buffers, so only a couple may wait.
    private let pending = DispatchSemaphore(value: 2)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var log: FileHandle?
    private let started = Date()

    init(folder: URL) throws {
        self.folder = folder
        interval = Self.use4K ? 0.25 : 0.15
        let fm = FileManager.default
        for sub in ["images", "depth", "confidence"] {
            try fm.createDirectory(at: folder.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        let frames = folder.appendingPathComponent("frames.jsonl")
        fm.createFile(atPath: frames.path, contents: nil)
        log = try FileHandle(forWritingTo: frames)
    }

    /// Called for every camera frame. Keeps a frame whenever the phone has moved or turned a little,
    /// up to about 6 a second (4 a second at 4K), and at least once a second while standing still.
    /// `turning` (radians a second) and `walking` (metres a second) are the phone's smoothed speeds.
    func consider(_ frame: ARFrame, turning: Float = 0, walking: Float = 0,
                  anchors: () -> [UUID: simd_float4x4], poseAnchors: () -> [UUID: simd_float4x4] = { [:] }) {
        let now = frame.timestamp
        guard now - lastTime >= interval, case .normal = frame.camera.trackingState else { return }
        // Photos taken while swinging the phone round are smeared; wait for it to slow, but never for long.
        if (turning > 1.2 || walking > 0.9) && now - lastTime < 0.7 { blurred += 1; return }
        let t = frame.camera.transform
        if let last = lastPose, now - lastTime < 1.0 {
            let moved = simd_distance(SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), SIMD3(last.columns.3.x, last.columns.3.y, last.columns.3.z))
            let f0 = SIMD3(last.columns.2.x, last.columns.2.y, last.columns.2.z), f1 = SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let turned = acos(min(1, max(-1, simd_dot(f0, f1))))
            guard moved > 0.02 || turned > 0.035 else { return }
        }
        guard let depthData = frame.sceneDepth else { return }
        guard pending.wait(timeout: .now()) == .success else { skipped += 1; return }
        lastTime = now
        lastPose = t

        let depth = Self.copy(depthData.depthMap, bytesPerPixel: 4)
        let confidence = depthData.confidenceMap.map { Self.copy($0, bytesPerPixel: 1) }
        let dw = CVPixelBufferGetWidth(depthData.depthMap), dh = CVPixelBufferGetHeight(depthData.depthMap)
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        let size = image.extent.size
        imageSize = size
        depthSize = (dw, dh)
        let index = frameCount
        frameCount += 1
        let name = String(format: "%06d", index)
        let k = frame.camera.intrinsics
        let light = frame.lightEstimate
        var line = "{\"index\":\(index),\"timestamp\":\(String(format: "%.5f", now))"
        line += ",\"image\":\"images/\(name).jpg\",\"depth\":\"depth/\(name).bin\""
        if confidence != nil { line += ",\"confidence\":\"confidence/\(name).bin\"" }
        line += ",\"width\":\(Int(size.width)),\"height\":\(Int(size.height)),\"depthWidth\":\(dw),\"depthHeight\":\(dh)"
        line += ",\"intrinsics\":[\(k[0][0]),\(k[1][1]),\(k[2][0]),\(k[2][1])]"
        line += ",\"cameraToWorld\":\(Self.json(t))"
        line += ",\"exposureDuration\":\(frame.camera.exposureDuration),\"exposureOffset\":\(frame.camera.exposureOffset)"
        if let light {
            line += ",\"ambientIntensity\":\(light.ambientIntensity),\"colorTemperature\":\(light.ambientColorTemperature)"
        }
        let mapping: String
        switch frame.worldMappingStatus {
        case .mapped: mapping = "mapped"
        case .extending: mapping = "extending"
        case .limited: mapping = "limited"
        default: mapping = "notAvailable"
        }
        line += ",\"tracking\":\"normal\",\"mapping\":\"\(mapping)\""
        line += ",\"turnSpeed\":\(String(format: "%.3f", turning)),\"walkSpeed\":\(String(format: "%.3f", walking))"
        let path = poseAnchors()
        line += ",\"poseAnchors\":{" + path.map { "\"\($0.key.uuidString)\":\(Self.json($0.value))" }.joined(separator: ",") + "}"
        let near = anchors()
        line += ",\"anchors\":{" + near.map { "\"\($0.key.uuidString)\":\(Self.json($0.value))" }.joined(separator: ",") + "}}\n"

        let folder = self.folder
        queue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let url = folder.appendingPathComponent("images/\(name).jpg")
                try? self.ci.writeJPEGRepresentation(of: image, to: url, colorSpace: self.colorSpace,
                                                     options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
                try? depth.write(to: folder.appendingPathComponent("depth/\(name).bin"))
                try? confidence?.write(to: folder.appendingPathComponent("confidence/\(name).bin"))
                if let data = line.data(using: .utf8) { self.log?.write(data) }
                let jpg = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                self.bytes += jpg + Int64(depth.count + (confidence?.count ?? 0))
            }
            self.pending.signal()
        }
    }

    /// Waits for every frame to be written and adds the summary files.
    func finish(anchors: [UUID: simd_float4x4], poseAnchors: [UUID: simd_float4x4] = [:], mesh: MeshData, kind: String) {
        queue.sync {}
        try? log?.close()
        log = nil
        let anchorJSON = "{" + anchors.map { "\"\($0.key.uuidString)\":\(Self.json($0.value))" }.joined(separator: ",") + "}"
        try? anchorJSON.write(to: folder.appendingPathComponent("anchors.json"), atomically: true, encoding: .utf8)
        let pathJSON = "{" + poseAnchors.map { "\"\($0.key.uuidString)\":\(Self.json($0.value))" }.joined(separator: ",") + "}"
        try? pathJSON.write(to: folder.appendingPathComponent("pose_anchors.json"), atomically: true, encoding: .utf8)
        try? Self.writePLY(mesh, to: folder.appendingPathComponent("arkit_mesh.ply"))
        let iso = ISO8601DateFormatter().string(from: started)
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in String(decoding: raw.prefix(while: { byte in byte != 0 }), as: UTF8.self) }
        let info = """
        {"format":"scanvas-raw","version":1,"app":"Scanvas","kind":"\(kind)","created":"\(iso)","device":"\(model)",
        "frames":\(frameCount),"skippedFrames":\(skipped),"blurredFramesSkipped":\(blurred),"imageWidth":\(Int(imageSize.width)),"imageHeight":\(Int(imageSize.height)),
        "depthWidth":\(depthSize.0),"depthHeight":\(depthSize.1),"depthUnits":"metres","depthFormat":"float32","confidenceFormat":"uint8 0-2",
        "coordinates":"ARKit world: right-handed, metres, Y up (gravity). Camera looks along -Z with +Y up; image pixels start top-left.",
        "intrinsics":"fx, fy, cx, cy in image pixels","poses":"cameraToWorld, 4x4 column-major",
        "duration":\(String(format: "%.1f", Date().timeIntervalSince(started)))}
        """
        try? info.write(to: folder.appendingPathComponent("capture.json"), atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    private static func copy(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        var data = Data(capacity: w * h * bytesPerPixel)
        for y in 0..<h { data.append(Data(bytes: base + y * stride, count: w * bytesPerPixel)) }
        return data
    }

    private static func json(_ m: simd_float4x4) -> String {
        let c = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        return "[" + c.flatMap { [$0.x, $0.y, $0.z, $0.w] }.map { String($0) }.joined(separator: ",") + "]"
    }

    static func writePLY(_ mesh: MeshData, to url: URL) throws {
        let colours = mesh.hasColors
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(mesh.vertexCount)\nproperty float x\nproperty float y\nproperty float z\n"
        if colours { header += "property uchar red\nproperty uchar green\nproperty uchar blue\n" }
        header += "element face \(mesh.triangleCount)\nproperty list uchar uint vertex_indices\nend_header\n"
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + mesh.vertexCount * 15 + mesh.triangleCount * 13)
        for i in 0..<mesh.vertexCount {
            var p = (mesh.positions[i].x, mesh.positions[i].y, mesh.positions[i].z)
            withUnsafeBytes(of: &p) { data.append(contentsOf: $0) }
            if colours { let c = mesh.colors[i]; data.append(contentsOf: [c.x, c.y, c.z]) }
        }
        for t in 0..<mesh.triangleCount {
            data.append(3)
            var f = (mesh.indices[3 * t], mesh.indices[3 * t + 1], mesh.indices[3 * t + 2])
            withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }
}
