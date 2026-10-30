import SceneKit
import UIKit
import simd

enum SceneExport {
    /// SceneKit geometry for a mesh (vertex colours when present).
    static func geometry(_ m: MeshData, wireframe: Bool = false) -> SCNGeometry {
        let vertices = SCNGeometrySource(vertices: m.positions.map { SCNVector3($0.x, $0.y, $0.z) })
        var sources = [vertices]
        if m.hasNormals {
            sources.append(SCNGeometrySource(normals: m.normals.map { SCNVector3($0.x, $0.y, $0.z) }))
        }
        if m.hasColors {
            var floats = [Float](); floats.reserveCapacity(m.vertexCount * 3)
            for c in m.colors { floats += [Float(c.x) / 255, Float(c.y) / 255, Float(c.z) / 255] }
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: m.vertexCount, usesFloatComponents: true,
                                             componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12))
        }
        let element = SCNGeometryElement(indices: m.indices, primitiveType: .triangles)
        let g = SCNGeometry(sources: sources, elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = m.hasColors ? UIColor.white : UIColor(white: 0.75, alpha: 1)
        mat.lightingModel = .lambert
        mat.isDoubleSided = true
        mat.fillMode = wireframe ? .lines : .fill
        g.materials = [mat]
        return g
    }

    static func scene(parts: [(String, MeshData)], wireframe: Bool = false) -> SCNScene {
        let scene = SCNScene()
        for (name, m) in parts where !m.isEmpty {
            let node = SCNNode(geometry: geometry(m, wireframe: wireframe))
            node.name = name
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    static func usdz(parts: [(String, MeshData)], to url: URL) throws {
        let ok = scene(parts: parts).write(to: url, options: nil, delegate: nil, progressHandler: nil)
        if !ok { throw CocoaError(.fileWriteUnknown) }
    }

    /// Renders a 3/4 view of a scene to a JPEG thumbnail.
    static func thumbnail(of scene: SCNScene, size: CGSize = CGSize(width: 480, height: 360)) -> Data? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true
        let (lo, hi) = scene.rootNode.boundingBox
        let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let radius = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 0.2)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zFar = Double(radius * 20)
        cam.camera?.zNear = 0.01
        cam.position = SCNVector3(center.x + radius * 0.8, center.y + radius * 1.1, center.z + radius * 0.8)
        cam.look(at: center)
        scene.rootNode.addChildNode(cam)
        defer { cam.removeFromParentNode() }
        renderer.pointOfView = cam
        scene.background.contents = UIColor(white: 0.12, alpha: 1)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image.jpegData(compressionQuality: 0.8)
    }

    /// Reads every triangle mesh in a model file (e.g. an Object Capture USDZ) into world-space MeshData.
    static func meshData(fromModelAt url: URL) throws -> MeshData {
        let scene = try SCNScene(url: url, options: nil)
        var result = MeshData()
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            let world = node.simdWorldTransform
            guard let vs = g.sources(for: .vertex).first else { return }
            let positions = read3(vs).map { p -> SIMD3<Float> in
                let w = world * SIMD4(p, 1)
                return SIMD3(w.x, w.y, w.z)
            }
            var part = MeshData()
            part.positions = positions
            if let ns = g.sources(for: .normal).first, ns.vectorCount == positions.count {
                let rot = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                        SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                        SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
                part.normals = read3(ns).map { simd_normalize(rot * $0) }
            }
            for el in g.elements where el.primitiveType == .triangles {
                let n = el.primitiveCount * 3
                el.data.withUnsafeBytes { raw in
                    for i in 0..<n {
                        let v: UInt32
                        switch el.bytesPerIndex {
                        case 2: v = UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                        case 1: v = UInt32(raw.load(fromByteOffset: i, as: UInt8.self))
                        default: v = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                        }
                        part.indices.append(v)
                    }
                }
            }
            if !part.isEmpty { result.append(part) }
        }
        if !result.hasNormals { result.computeNormals() }
        return result
    }

    private static func read3(_ s: SCNGeometrySource) -> [SIMD3<Float>] {
        var out = [SIMD3<Float>](); out.reserveCapacity(s.vectorCount)
        s.data.withUnsafeBytes { raw in
            for i in 0..<s.vectorCount {
                let base = s.dataOffset + i * s.dataStride
                if s.usesFloatComponents && s.bytesPerComponent == 4 {
                    out.append(SIMD3(raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)))
                } else if s.usesFloatComponents && s.bytesPerComponent == 8 {
                    out.append(SIMD3(Float(raw.loadUnaligned(fromByteOffset: base, as: Double.self)),
                                     Float(raw.loadUnaligned(fromByteOffset: base + 8, as: Double.self)),
                                     Float(raw.loadUnaligned(fromByteOffset: base + 16, as: Double.self))))
                } else {
                    out.append(.zero)
                }
            }
        }
        return out
    }
}
