import SceneKit
import UIKit
import simd

enum SceneExport {
    /// SceneKit geometry for a mesh (vertex colours when present).
    static func geometry(_ m: MeshData, wireframe: Bool = false, dollhouse: Bool = false) -> SCNGeometry {
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
        mat.fillMode = wireframe ? .lines : .fill
        if dollhouse && !wireframe {
            // LiDAR surfaces face the scanner. Hiding their back sides lets you look through
            // the walls nearest you into the space, and still see every surface from inside.
            mat.isDoubleSided = false
            mat.cullMode = facesTowardNormals(m) ? .back : .front
        } else {
            mat.isDoubleSided = true
        }
        g.materials = [mat]
        return g
    }

    /// True when counter-clockwise triangles face the same way as the vertex normals.
    static func facesTowardNormals(_ m: MeshData) -> Bool {
        guard m.hasNormals, m.triangleCount > 0 else { return true }
        var score: Float = 0
        let step = max(1, m.triangleCount / 5000)
        for t in stride(from: 0, to: m.triangleCount, by: step) {
            let n = m.normals[Int(m.indices[3 * t])] + m.normals[Int(m.indices[3 * t + 1])] + m.normals[Int(m.indices[3 * t + 2])]
            score += simd_dot(m.faceNormal(t), n)
        }
        return score >= 0
    }

    static func scene(parts: [(String, MeshData)], wireframe: Bool = false, dollhouse: Bool = false) -> SCNScene {
        let scene = SCNScene()
        for (name, m) in parts where !m.isEmpty {
            let node = SCNNode(geometry: geometry(m, wireframe: wireframe, dollhouse: dollhouse))
            node.name = name
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    /// A room with one node per wall, so the viewer can hide the walls between the camera and the room.
    static func roomScene(_ plan: PlanModel, wireframe: Bool, recolour: ((String, MeshData) -> MeshData)? = nil) -> SCNScene {
        let scene = SCNScene()
        func add(_ name: String, _ m: MeshData, to parent: SCNNode) {
            guard !m.isEmpty else { return }
            let mesh = recolour?(name, m) ?? m
            let node = SCNNode(geometry: geometry(mesh, wireframe: wireframe))
            node.name = name
            parent.addChildNode(node)
        }
        let centroid = Geometry.centroid(plan.outlines.flatMap { $0 })
        for wall in plan.walls {
            let parts = PlanMesher.wallParts(wall, plan: plan)
            var n = wall.normal
            if simd_dot(wall.center2D - centroid, n) < 0 { n = -n }
            let node = WallNode()
            node.outward = SIMD3(n.x, 0, -n.y)
            node.center = PlanMesher.world(SIMD3(wall.center2D, wall.center.z))
            add("Walls", parts.wall, to: node)
            add("Doors", parts.doors, to: node)
            add("Windows", parts.windows, to: node)
            scene.rootNode.addChildNode(node)
        }
        add("Floor", PlanMesher.floorMesh(plan), to: scene.rootNode)
        add("Furniture", plan.objects.reduce(into: MeshData()) { $0.append(PlanMesher.objectMesh($1)) }, to: scene.rootNode)
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

/// A room wall the viewer can hide when the camera is outside it (dollhouse view).
final class WallNode: SCNNode {
    var outward = SIMD3<Float>(0, 0, 1)
    var center = SIMD3<Float>(0, 0, 0)
}
