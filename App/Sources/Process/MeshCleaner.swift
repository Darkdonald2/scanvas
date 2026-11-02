import Foundation
import simd

extension MeshData {
    /// "Cleaning mesh": welds the anchor seams, drops collapsed triangles, and removes small floating
    /// fragments (bits of people walking past, reflections), without ever touching the main surfaces.
    func cleaned(minFragmentArea: Float = 0.03) -> MeshData {
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
            // Only truly collapsed triangles. LiDAR meshes describe flat walls with long thin triangles,
            // so thin is not the same as broken.
            _ = longest
            sliver[t] = area < 1e-9
            if !sliver[t] { union(ia, ib); union(ib, ic) }
        }
        var componentArea: [Int32: Float] = [:]
        var total: Float = 0
        for t in 0..<tris where !sliver[t] {
            componentArea[find(Int32(m.indices[3 * t])), default: 0] += areas[t]
            total += areas[t]
        }
        // Small objects scanned on their own are one small piece: never delete the main part of a scan.
        let threshold = min(minFragmentArea, total * 0.01)
        var keep = [Bool](repeating: false, count: tris)
        var keptArea: Float = 0
        for t in 0..<tris where !sliver[t] {
            keep[t] = (componentArea[find(Int32(m.indices[3 * t]))] ?? 0) >= threshold
            if keep[t] { keptArea += areas[t] }
        }
        // Safety net: floaters are a tiny share of a scan. If cleaning would remove more than 3% of the
        // surface, the mesh is just made of many separate pieces, so leave it as it is.
        if keptArea < total * 0.97 { return m }
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

extension MeshData {
    /// Makes triangles (winding and normals) face the side the scanner was on. LiDAR surfaces are always seen
    /// from the camera side, so the camera path is a reliable reference; guessing from stored normals
    /// can go wrong after vertices are merged, which turns the whole scan inside out.
    func orientedToward(cameras: [SIMD3<Float>]) -> MeshData {
        guard triangleCount > 0, !cameras.isEmpty else { return self }
        let cams = cameras.count > 300 ? Swift.stride(from: 0, to: cameras.count, by: cameras.count / 300).map { cameras[$0] } : cameras
        var score: Float = 0
        let step = max(1, triangleCount / 4000)
        for t in Swift.stride(from: 0, to: triangleCount, by: step) {
            let a = positions[Int(indices[3 * t])], b = positions[Int(indices[3 * t + 1])], c = positions[Int(indices[3 * t + 2])]
            let centre = (a + b + c) / 3
            guard let cam = cams.min(by: { simd_distance_squared($0, centre) < simd_distance_squared($1, centre) }) else { continue }
            let d = simd_normalize(cam - centre)
            score += simd_dot(faceNormal(t), d) > 0 ? 1 : -1
        }
        var m = self
        if score < 0 {
            for t in 0..<triangleCount { m.indices.swapAt(3 * t + 1, 3 * t + 2) }
        }
        m.computeNormals()
        return m
    }
}
