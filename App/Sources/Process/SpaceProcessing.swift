import Foundation
import SceneKit

/// Turns a finished LiDAR scan into the saved project files: smoothing, vertex colour, photo textures.
/// Shared by Space scans and Pipe surveys.
enum SpaceProcessing {
    /// Writes mesh.bin (and textured.bin + textures when photos were captured) into `folder`.
    /// Returns the final mesh and a scene suitable for the thumbnail.
    static func process(_ collected: MeshData, scanner: MeshScanner, folder: URL, smooth: Bool, colour: Bool,
                        report: @escaping (String, Double) -> Void) throws -> (MeshData, SCNScene) {
        var mesh = collected
        var log = ["collected: \(collected.triangleCount) triangles, \(collected.vertexCount) vertices, classes \(collected.faceClasses.count)"]
        let defaults = UserDefaults.standard
        let clean = defaults.object(forKey: "cleanMesh") as? Bool ?? false
        let refine = defaults.object(forKey: "refineCameras") as? Bool ?? false
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
        if colour {
            report("Colouring mesh…", 0.02)
            scanner.colourize(&mesh) { p in report("Colouring mesh…", 0.02 + 0.08 * p) }
        }
        try mesh.write(to: folder.appendingPathComponent(ProjectFile.mesh))
        var scene: SCNScene?
        if colour {
            var frames = scanner.photoKeyframes()
            log.append("photo keyframes: \(frames.count)")
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
            log.append("texturing: " + Texturer.lastStats)
            if !textured.pages.isEmpty {
                try textured.write(to: folder.appendingPathComponent(ProjectFile.textured))
                scene = SceneExport.texturedScene(textured, folder: folder, dollhouse: false)
            }
        }
        scanner.clearKeyframes()
        try? FileManager.default.removeItem(at: photos)
        report("Saving…", 0.97)
        let settings = "settings: clean \(clean), refine \(refine), smooth \(smooth), compact \(Texturer.compactCharts), full-res \(Keyframe.fullResolution)"
        try? ([settings] + log).joined(separator: "\n").write(to: folder.appendingPathComponent("processing.txt"), atomically: true, encoding: .utf8)
        if let scene { return (mesh, scene) }
        let preview = mesh.triangleCount > 300_000 ? mesh.simplified(cell: 0.05) : mesh
        return (mesh, SceneExport.scene(parts: [("Scan", preview)]))
    }
}
