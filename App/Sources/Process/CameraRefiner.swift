import Foundation
import simd

/// "Refining cameras": nudges each photo's camera pose so its LiDAR depth lines up with the finished mesh
/// (point-to-plane ICP). Small tracking errors otherwise shift photos across surfaces, which blurs
/// textures and breaks edges, and they grow over long scans.
enum CameraRefiner {
    private static let cell: Float = 0.06

    private struct Grid {
        var cells: [Int64: [Int32]] = [:]
        var centres: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []

        static func key(_ p: SIMD3<Float>) -> Int64 {
            let x = Int64(floor(p.x / cell)) & 0x1FFFFF, y = Int64(floor(p.y / cell)) & 0x1FFFFF, z = Int64(floor(p.z / cell)) & 0x1FFFFF
            return x << 42 | y << 21 | z
        }
        static func key(_ x: Int, _ y: Int, _ z: Int) -> Int64 {
            (Int64(x) & 0x1FFFFF) << 42 | (Int64(y) & 0x1FFFFF) << 21 | (Int64(z) & 0x1FFFFF)
        }

        /// Nearest triangle centre within `maxDist`.
        func nearest(_ p: SIMD3<Float>, maxDist: Float) -> Int? {
            let cx = Int(floor(p.x / cell)), cy = Int(floor(p.y / cell)), cz = Int(floor(p.z / cell))
            var best = -1
            var bestD = maxDist * maxDist
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                guard let list = cells[Self.key(cx + dx, cy + dy, cz + dz)] else { continue }
                for i in list {
                    let d = simd_distance_squared(centres[Int(i)], p)
                    if d < bestD { bestD = d; best = Int(i) }
                }
            } } }
            return best >= 0 ? best : nil
        }
    }

    static func refine(_ frames: [Keyframe], mesh: MeshData, progress: (Double) -> Void) -> [Keyframe] {
        guard mesh.triangleCount > 0, !frames.isEmpty else { return frames }
        var grid = Grid()
        let tris = mesh.triangleCount
        let step = max(1, tris / 1_500_000)
        grid.centres.reserveCapacity(tris / step)
        grid.normals.reserveCapacity(tris / step)
        for t in stride(from: 0, to: tris, by: step) {
            let a = mesh.positions[Int(mesh.indices[3 * t])], b = mesh.positions[Int(mesh.indices[3 * t + 1])], c = mesh.positions[Int(mesh.indices[3 * t + 2])]
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            guard len > 1e-8 else { continue }
            let centre = (a + b + c) / 3
            grid.cells[Grid.key(centre), default: []].append(Int32(grid.centres.count))
            grid.centres.append(centre)
            grid.normals.append(n / len)
        }

        var out = frames
        let lock = NSLock()
        var done = 0
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: frames.count) { i in
                if let refined = refine(frames[i], grid: grid) { buf[i] = refined }
                lock.lock(); done += 1; let d = done; lock.unlock()
                if d % 25 == 0 { progress(Double(d) / Double(frames.count)) }
            }
        }
        return out
    }

    private static func refine(_ f: Keyframe, grid: Grid) -> Keyframe? {
        let w = Keyframe.width, h = Keyframe.height
        guard f.depth.count == w * h else { return nil }
        // Camera-space samples from the depth map, skipping depth edges (unreliable "flying" pixels).
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(1500)
        for v in stride(from: 4, to: h - 4, by: 5) {
            for u in stride(from: 4, to: w - 4, by: 5) {
                let z = f.depth[v * w + u]
                guard z > 0.3, z < 4.0 else { continue }
                let n1 = f.depth[v * w + u - 2], n2 = f.depth[v * w + u + 2], n3 = f.depth[(v - 2) * w + u], n4 = f.depth[(v + 2) * w + u]
                let jump = max(abs(n1 - z), abs(n2 - z), abs(n3 - z), abs(n4 - z))
                guard jump < 0.04 * z + 0.02 else { continue }
                samples.append(SIMD3((Float(u) - f.cx) / f.fx * z, -(Float(v) - f.cy) / f.fy * z, -z))
            }
        }
        guard samples.count >= 200 else { return nil }

        let original = f.worldToCamera.inverse
        var pose = original
        var firstError: Float = -1, lastError: Float = 0, lastInliers = 0
        let radii: [Float] = [0.12, 0.08, 0.06, 0.04, 0.03, 0.03, 0.025, 0.025]
        for maxDist in radii {
            let centre = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            var A = [Double](repeating: 0, count: 36)
            var b = [Double](repeating: 0, count: 6)
            var err: Float = 0
            var inliers = 0
            for s in samples {
                let p4 = pose * SIMD4(s, 1)
                let p = SIMD3(p4.x, p4.y, p4.z)
                guard let j = grid.nearest(p, maxDist: maxDist) else { continue }
                let n = grid.normals[j]
                let r = simd_dot(n, p - grid.centres[j])
                // Huber weight keeps bad matches (moved furniture, people) from pulling the camera.
                let delta: Float = 0.015
                let wgt = abs(r) < delta ? 1 : delta / abs(r)
                let arm = simd_cross(p - centre, n)
                let J = [Double(arm.x), Double(arm.y), Double(arm.z), Double(n.x), Double(n.y), Double(n.z)]
                for a in 0..<6 {
                    b[a] -= J[a] * Double(r * wgt)
                    for c in a..<6 { A[a * 6 + c] += J[a] * J[c] * Double(wgt) }
                }
                err += abs(r); inliers += 1
            }
            guard inliers >= 120 else { return nil }
            err /= Float(inliers)
            if firstError < 0 { firstError = err }
            lastError = err; lastInliers = inliers
            for a in 0..<6 { for c in 0..<a { A[a * 6 + c] = A[c * 6 + a] }; A[a * 6 + a] += 1e-3 * Double(inliers) * 1e-3 }
            guard let x = solve6(A, b) else { return nil }
            let omega = SIMD3(Float(x[0]), Float(x[1]), Float(x[2])), t = SIMD3(Float(x[3]), Float(x[4]), Float(x[5]))
            let angle = simd_length(omega)
            let rot = angle > 1e-9 ? simd_float4x4(simd_quatf(angle: angle, axis: omega / angle)) : matrix_identity_float4x4
            let delta = translation(centre + t) * rot * translation(-centre)
            pose = delta * pose
            if angle < 1e-4 && simd_length(t) < 1e-4 { break }
        }
        _ = lastInliers
        // Accept only a modest correction that actually improved the fit.
        let moved = simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
                                  SIMD3(original.columns.3.x, original.columns.3.y, original.columns.3.z))
        let f0 = SIMD3(original.columns.2.x, original.columns.2.y, original.columns.2.z), f1 = SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        let turned = acos(min(1, max(-1, simd_dot(f0, f1))))
        guard moved < 0.15, turned < 0.08, lastError <= firstError else { return nil }
        var out = f
        out.worldToCamera = pose.inverse
        out.cameraPosition = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        return out
    }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// Solves the 6×6 system with Gaussian elimination and partial pivoting.
    private static func solve6(_ a: [Double], _ b: [Double]) -> [Double]? {
        var m = a, r = b
        for col in 0..<6 {
            var piv = col
            for row in (col + 1)..<6 where abs(m[row * 6 + col]) > abs(m[piv * 6 + col]) { piv = row }
            guard abs(m[piv * 6 + col]) > 1e-12 else { return nil }
            if piv != col {
                for k in 0..<6 { m.swapAt(col * 6 + k, piv * 6 + k) }
                r.swapAt(col, piv)
            }
            for row in (col + 1)..<6 {
                let f = m[row * 6 + col] / m[col * 6 + col]
                guard f != 0 else { continue }
                for k in col..<6 { m[row * 6 + k] -= f * m[col * 6 + k] }
                r[row] -= f * r[col]
            }
        }
        var x = [Double](repeating: 0, count: 6)
        for row in stride(from: 5, through: 0, by: -1) {
            var s = r[row]
            for k in (row + 1)..<6 { s -= m[row * 6 + k] * x[k] }
            x[row] = s / m[row * 6 + row]
        }
        return x
    }
}
