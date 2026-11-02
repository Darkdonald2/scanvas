import Foundation
import simd

extension MeshData {
    /// "Cleaning mesh": welds the anchor seams, drops collapsed and long sliver triangles (LiDAR stretches these
    /// across gaps, and they smear textures), and removes small floating fragments such as people walking past.
    func cleaned(minFragmentArea: Float = 0.08) -> MeshData {
        let m = welded()
        let tris = m.triangleCount
        guard tris > 0 else { return m }

        var parent = [Int32](0..<Int32(m.vertexCount))
        func find(_ x: Int32) -> Int32 {
            var r = x
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = x
            while parent[Int(c)] != r { let n = parent[Int(c)]; parent[Int(c)] = r; c = n }
            return r
        }
        func union(_ a: UInt32, _ b: UInt32) {
            let ra = find(Int32(a)), rb = find(Int32(b))
            if ra != rb { parent[Int(max(ra, rb))] = min(ra, rb) }
        }

        var areas = [Float](repeating: 0, count: tris)
        var sliver = [Bool](repeating: false, count: tris)
        for t in 0..<tris {
            let ia = m.indices[3 * t], ib = m.indices[3 * t + 1], ic = m.indices[3 * t + 2]
            let a = m.positions[Int(ia)], b = m.positions[Int(ib)], c = m.positions[Int(ic)]
            let area = simd_length(simd_cross(b - a, c - a)) / 2
            let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
            areas[t] = area
            // A triangle at least 30 cm long but under 1 cm wide is a stretched gap, not a surface.
            sliver[t] = area < 1e-8 || (longest > 0.3 && 2 * area / longest < 0.01)
            if !sliver[t] { union(ia, ib); union(ib, ic) }
        }
        var componentArea: [Int32: Float] = [:]
        var total: Float = 0
        for t in 0..<tris where !sliver[t] {
            componentArea[find(Int32(m.indices[3 * t])), default: 0] += areas[t]
            total += areas[t]
        }
        // Small objects scanned on their own are one small piece: never delete the main part of a scan.
        let threshold = min(minFragmentArea, total * 0.05)
        var keep = [Bool](repeating: false, count: tris)
        for t in 0..<tris where !sliver[t] {
            keep[t] = (componentArea[find(Int32(m.indices[3 * t]))] ?? 0) >= threshold
        }
        return m.keeping(keep)
    }

    /// The mesh with only the triangles marked `true`, unused vertices removed.
    func keeping(_ keep: [Bool]) -> MeshData {
        var remap = [Int32](repeating: -1, count: vertexCount)
        var out = MeshData()
        let keepClasses = faceClasses.count == triangleCount
        for t in 0..<triangleCount where keep[t] {
            for j in 0..<3 {
                let v = Int(indices[3 * t + j])
                if remap[v] < 0 {
                    remap[v] = Int32(out.positions.count)
                    out.positions.append(positions[v])
                    if hasNormals { out.normals.append(normals[v]) }
                    if hasColors { out.colors.append(colors[v]) }
                }
                out.indices.append(UInt32(remap[v]))
            }
            if keepClasses { out.faceClasses.append(faceClasses[t]) }
        }
        return out
    }
}
