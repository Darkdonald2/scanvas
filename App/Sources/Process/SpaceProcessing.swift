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
        let photos = folder.appendingPathComponent(ProjectFile.keyframes, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if smooth {
            report("Smoothing mesh…", 0.01)
            mesh = mesh.smoothed()
        }
        if colour {
            report("Colouring mesh…", 0.02)
            scanner.colourize(&mesh) { p in report("Colouring mesh…", 0.02 + 0.08 * p) }
        }
        try mesh.write(to: folder.appendingPathComponent(ProjectFile.mesh))
        var scene: SCNScene?
        if colour {
            let frames = scanner.photoKeyframes()
            let textured = try Texturer.build(mesh: mesh, keyframes: frames, photos: photos, output: folder) { p in
                report(p.message, 0.1 + 0.85 * p.fraction)
            }
            if !textured.pages.isEmpty {
                try textured.write(to: folder.appendingPathComponent(ProjectFile.textured))
                scene = SceneExport.texturedScene(textured, folder: folder, dollhouse: false)
            }
        }
        scanner.clearKeyframes()
        try? FileManager.default.removeItem(at: photos)
        report("Saving…", 0.97)
        if let scene { return (mesh, scene) }
        let preview = mesh.triangleCount > 300_000 ? mesh.simplified(cell: 0.05) : mesh
        return (mesh, SceneExport.scene(parts: [("Scan", preview)]))
    }
}
