import Foundation
import SceneKit
import simd

/// 3D tubes for pipe runs, used by the viewer, the AR preview and the mesh exports.
enum PipeGeometry {
    static let sides = 16

    /// A closed-ish tube between two points (no end caps; joints are covered by spheres).
    static func tube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius r: Float, color: SIMD3<UInt8>, into m: inout MeshData) {
        let axis = b - a
        let len = simd_length(axis)
        guard len > 0.001 else { return }
        let d = axis / len
        let helper: SIMD3<Float> = abs(d.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(d, helper)), v = simd_cross(d, u)
        let base = UInt32(m.positions.count)
        for i in 0..<sides {
            let t = Float(i) / Float(sides) * 2 * .pi
            let n = u * cos(t) + v * sin(t)
            m.positions.append(a + n * r); m.normals.append(n); m.colors.append(color)
            m.positions.append(b + n * r); m.normals.append(n); m.colors.append(color)
        }
        for i in 0..<sides {
            let j = (i + 1) % sides
            let a0 = base + UInt32(2 * i), b0 = a0 + 1, a1 = base + UInt32(2 * j), b1 = a1 + 1
            m.indices += [a0, a1, b0, b0, a1, b1]
        }
    }

    static func sphere(_ c: SIMD3<Float>, radius r: Float, color: SIMD3<UInt8>, into m: inout MeshData) {
        let rings = 8, segs = 12
        let base = UInt32(m.positions.count)
        for i in 0...rings {
            let phi = Float(i) / Float(rings) * .pi
            for j in 0...segs {
                let theta = Float(j) / Float(segs) * 2 * .pi
                let n = SIMD3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                m.positions.append(c + n * r); m.normals.append(n); m.colors.append(color)
            }
        }
        let row = UInt32(segs + 1)
        for i in 0..<UInt32(rings) {
            for j in 0..<UInt32(segs) {
                let a = base + i * row + j, b = a + row
                m.indices += [a, a + 1, b, b, a + 1, b + 1]
            }
        }
    }

    static func color8(_ c: SIMD3<Float>) -> SIMD3<UInt8> { rgb(c * 255) }

    static func statusColor(_ s: PipeSegment.Status) -> SIMD3<Float> {
        switch s {
        case .good: return SIMD3(0.20, 0.85, 0.35)
        case .flat: return SIMD3(1.00, 0.62, 0.10)
        case .backfall: return SIMD3(1.00, 0.20, 0.20)
        case .vertical: return SIMD3(0.30, 0.65, 1.00)
        }
    }

    /// Tubes for one run; fittings get a larger, lighter sphere.
    static func mesh(for run: PipeRun, colorBy status: Bool = false, minFall: Float = 1) -> MeshData {
        var m = MeshData()
        let r = max(run.diameter / 2, 0.01)
        let sys = PipeSystem.color(run.system)
        for s in run.segments {
            let c = status ? statusColor(s.status(minFall: minFall)) : sys
            tube(s.from.position, s.to.position, radius: r, color: color8(c), into: &m)
        }
        for p in run.points {
            let fitting = p.kind != .point
            let c = fitting ? sys * 0.5 + SIMD3(repeating: 0.5) : sys
            sphere(p.position, radius: fitting ? r * 1.35 : r * 1.01, color: color8(c), into: &m)
        }
        return m
    }

    static func mesh(for survey: PipeSurvey) -> MeshData {
        var m = MeshData()
        for run in survey.runs { m.append(mesh(for: run)) }
        return m
    }

    /// One part per system for OBJ/GLB groups.
    static func parts(for survey: PipeSurvey) -> [(String, MeshData)] {
        var bySystem: [String: MeshData] = [:]
        var order: [String] = []
        for run in survey.runs where run.points.count > 0 {
            let key = "Pipes-" + run.system
            if bySystem[key] == nil { order.append(key); bySystem[key] = MeshData() }
            bySystem[key]!.append(mesh(for: run))
        }
        return order.map { ($0, bySystem[$0]!) }
    }

    /// SceneKit node with every run, lit so the tubes read as round.
    static func node(for survey: PipeSurvey) -> SCNNode {
        let root = SCNNode()
        root.name = "Pipes"
        for run in survey.runs where !run.points.isEmpty {
            let m = mesh(for: run)
            guard !m.isEmpty else { continue }
            let g = SceneExport.geometry(m)
            g.materials.first?.lightingModel = .blinn
            g.materials.first?.specular.contents = UIColor(white: 0.5, alpha: 1)
            let node = SCNNode(geometry: g)
            node.name = run.name
            root.addChildNode(node)
        }
        return root
    }
}
