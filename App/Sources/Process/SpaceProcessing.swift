import Foundation
import SceneKit

/// Turns a finished LiDAR scan into the saved project files: smoothing, vertex colour, photo textures.
/// Shared by Space scans and Pipe surveys.
enum SpaceProcessing {
    /// Writes mesh.bin (and textured.bin + textures when photos were captured) into `folder`.
    /// Returns the final mesh and a scene suitable for the thumbnail.
    static func process(_ collected: MeshData, scanner: MeshScanner, folder: URL, smooth: Bool, colour: Bool,
                        report reportProgress: @escaping (String, Double) -> Void) throws -> (MeshData, SCNScene) {
        // Remember the step and memory use on disk, so if the app is closed mid-way the next launch can say where.
        func report(_ text: String, _ value: Double) {
            ProcessingMonitor.stage(text)
            reportProgress(text, value)
        }
        ProcessingMonitor.begin()
        defer { ProcessingMonitor.end() }
        var mesh = collected
        var log = ["collected: \(collected.triangleCount) triangles, \(collected.vertexCount) vertices, classes \(collected.faceClasses.count)"]
        let defaults = UserDefaults.standard
        let clean = defaults.object(forKey: "cleanMesh") as? Bool ?? false
        let refine = defaults.object(forKey: "refineCameras") as? Bool ?? true
        let photos = folder.appendingPathComponent(ProjectFile.keyframes, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if clean {
            report("Cleaning mesh…", 0.01)
            let cleaned = mesh.cleaned()
            if !cleaned.isEmpty { mesh = cleaned }
            log.append("cleaned: \(mesh.triangleCount) triangles")
        }
        if smooth {
            report("Smoothing mesh…", 0.015)
            mesh = mesh.smoothed()
            log.append("smoothed: \(mesh.triangleCount) triangles, normals match winding \(SceneExport.facesTowardNormals(mesh))")
        }
        // Face every surface towards where the scanner was (keeps the scan from turning inside out).
        let cameras = scanner.correctedKeyframes().map { $0.cameraPosition }
        if !cameras.isEmpty {
            mesh = mesh.orientedToward(cameras: cameras)
            log.append("oriented to \(cameras.count) camera positions, normals match winding \(SceneExport.facesTowardNormals(mesh))")
        }
        report("Facing surfaces…", 0.018)
        if colour {
            report("Colouring mesh…", 0.02)
            scanner.colourize(&mesh) { p in report("Colouring mesh…", 0.02 + 0.08 * p) }
        }
        try mesh.write(to: folder.appendingPathComponent(ProjectFile.mesh))
        if colour {
            var frames = scanner.photoKeyframes()
            log.append("photo keyframes: \(frames.count), memory \(ProcessingMonitor.footprintMB()) MB")
            if refine {
                report("Refining cameras…", 0.1)
                let before = frames
                frames = CameraRefiner.refine(frames, mesh: mesh) { p in
                    report("Refining cameras…", 0.1 + 0.1 * p)
                }
                let changed = zip(before, frames).filter { $0.0.worldToCamera != $0.1.worldToCamera }.count
                log.append("refined cameras: \(changed) of \(frames.count)")
            }
            let textured = try Texturer.build(mesh: mesh, keyframes: frames, photos: photos, output: folder) { p in
                report(p.message, 0.2 + 0.76 * p.fraction)
            }
            log.append("texturing: " + Texturer.lastStats + ", memory \(ProcessingMonitor.footprintMB()) MB")
            if !textured.pages.isEmpty {
                try textured.write(to: folder.appendingPathComponent(ProjectFile.textured))
            }
        }
        scanner.clearKeyframes()
        try? FileManager.default.removeItem(at: photos)
        report("Saving…", 0.97)
        let settings = "settings: clean \(clean), refine \(refine), smooth \(smooth), compact \(Texturer.compactCharts), full-res \(Keyframe.fullResolution)"
        try? ([settings] + log).joined(separator: "\n").write(to: folder.appendingPathComponent("processing.txt"), atomically: true, encoding: .utf8)
        // The thumbnail uses the coloured mesh: loading every full-size texture page just for a small picture
        // used close to a gigabyte on long scans.
        let preview = mesh.triangleCount > 300_000 ? mesh.simplified(cell: 0.05) : mesh
        return (mesh, SceneExport.scene(parts: [("Scan", preview)]))
    }
}

/// Notes the current processing step and the app's memory use, so a scan that closes the app can be traced.
enum ProcessingMonitor {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    // A small file rather than UserDefaults: it is on disk at once, even if the system closes the app a moment later.
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("processing-stage.txt")
    }
    private static var last = ""
    private static let lock = NSLock()

    static func begin() { last = ""; stage("Started") }
    static func stage(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard text != last else { return }
        last = text
        try? "\(text) (\(footprintMB()) MB in use)".write(to: url, atomically: true, encoding: .utf8)
    }
    static func end() { try? FileManager.default.removeItem(at: url) }

    /// Set when the last processing never finished: the step it reached.
    static var unfinished: String? { try? String(contentsOf: url, encoding: .utf8) }
    static func dismiss() { end() }
}
