import Foundation
import simd

/// "Refining cameras": moves each photo's camera to where its LiDAR depth fits the finished mesh
/// (point-to-plane ICP, coarse to fine).
///
/// ARKit keeps correcting its map while scanning and rebuilds the mesh to match, but each photo keeps the
/// position it was taken at. On a real scan the early photos were 10–25 cm away from where the mesh says
/// they should be, which paints textures in the wrong place and doubles edges. So this starts with a wide
/// search (matches up to 50 cm away) and narrows down to 3 cm. Photos that still fit badly get another try
/// starting from the correction their neighbours in time needed, and photos that fit nowhere are left out of
/// texturing. The same method, prototyped on that scan, took the share of depth points lying on the mesh
/// from 20–80 % to 80–97 % for the affected photos.
enum CameraRefiner {
    struct Outcome {
        var frames: [Keyframe]
        /// False for photos that fit the mesh nowhere and should not be used for texturing.
        var keep: [Bool]
        var corrected = 0
        var dropped = 0
        var fitBefore: Float = 0
        var fitAfter: Float = 0
        var largestMove: Float = 0

        var summary: String {
            String(format: "refined cameras: %d of %d moved (largest %.0f cm), %d left out, fit to mesh %.2f -> %.2f",
                   corrected, frames.count, Double(largestMove * 100), dropped, Double(fitBefore), Double(fitAfter))
        }
    }

    // MARK: Target: triangle centres and normals, searchable at three scales

    private struct Grid {
        let cell: Float
        var cells: [Int64: [Int32]] = [:]

        init(cell: Float) { self.cell = cell }

        static func key(_ x: Int, _ y: Int, _ z: Int) -> Int64 {
            (Int64(x) & 0x1FFFFF) << 42 | (Int64(y) & 0x1FFFFF) << 21 | (Int64(z) & 0x1FFFFF)
        }

        func key(_ p: SIMD3<Float>) -> Int64 {
            Self.key(Int(floor(p.x / cell)), Int(floor(p.y / cell)), Int(floor(p.z / cell)))
        }

        mutating func insert(_ index: Int32, _ p: SIMD3<Float>) {
            cells[key(p), default: []].append(index)
        }

        /// Nearest point within `maxDist` (which must not be larger than the cell).
        func nearest(_ p: SIMD3<Float>, maxDist: Float, in centres: [SIMD3<Float>]) -> Int? {
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

    private struct Target {
        var centres: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var fine = Grid(cell: 0.06)        // every point: matches up to 6 cm
        var medium = Grid(cell: 0.12)      // one point per 3 cm: matches up to 12 cm
        var coarse = Grid(cell: 0.5)       // one point per 12 cm: matches up to 50 cm

        init(mesh: MeshData) {
            let tris = mesh.triangleCount
            let step = max(1, tris / 1_500_000)
            centres.reserveCapacity(tris / step)
            normals.reserveCapacity(tris / step)
            var seenMedium = Set<Int64>(), seenCoarse = Set<Int64>()
            for t in stride(from: 0, to: tris, by: step) {
                let a = mesh.positions[Int(mesh.indices[3 * t])], b = mesh.positions[Int(mesh.indices[3 * t + 1])], c = mesh.positions[Int(mesh.indices[3 * t + 2])]
                let n = simd_cross(b - a, c - a)
                let len = simd_length(n)
                guard len > 1e-8 else { continue }
                let centre = (a + b + c) / 3
                let index = Int32(centres.count)
                centres.append(centre)
                normals.append(n / len)
                fine.insert(index, centre)
                if seenMedium.insert(Grid.key(Int(floor(centre.x / 0.03)), Int(floor(centre.y / 0.03)), Int(floor(centre.z / 0.03)))).inserted {
                    medium.insert(index, centre)
                }
                if seenCoarse.insert(Grid.key(Int(floor(centre.x / 0.12)), Int(floor(centre.y / 0.12)), Int(floor(centre.z / 0.12)))).inserted {
                    coarse.insert(index, centre)
                }
            }
        }

        func grid(for maxDist: Float) -> Grid {
            maxDist <= 0.06 ? fine : (maxDist <= 0.12 ? medium : coarse)
        }
    }

    private struct Fit {
        var share: Float = 0       // share of the photo's depth points lying on the mesh (within 4 cm)
        var error: Float = 1       // their mean distance from it
    }

    /// Search distance and number of rounds at each stage.
    private static let fullLadder: [(Float, Int)] = [(0.5, 5), (0.25, 5), (0.12, 5), (0.06, 6), (0.03, 6)]
    private static let fineLadder: [(Float, Int)] = [(0.06, 6), (0.03, 6)]

    // MARK: Entry

    static func refine(_ frames: [Keyframe], mesh: MeshData, progress: (Double) -> Void) -> Outcome {
        var outcome = Outcome(frames: frames, keep: [Bool](repeating: true, count: frames.count))
        guard mesh.triangleCount > 0, !frames.isEmpty else { return outcome }
        let target = Target(mesh: mesh)
        let count = frames.count
        let original = frames.map { $0.worldToCamera.inverse }
        var samples = [[SIMD3<Float>]](repeating: [], count: count)
        var pose = original
        var fit0 = [Fit](repeating: Fit(), count: count)
        var fit = fit0
        var corrected = [Bool](repeating: false, count: count)
        var usable = [Bool](repeating: false, count: count)

        // Pass 1: every photo on its own, starting from where ARKit put it.
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let s = depthSamples(frames[i])
            var before = Fit(), after = Fit()
            var result: simd_float4x4?
            if s.count >= 200 {
                before = fitness(s, original[i], target)
                after = before
                if let p = icp(s, original[i], target, before.share >= 0.85 ? fineLadder : fullLadder) {
                    let f = fitness(s, p, target)
                    if accept(original[i], p, before, f) { result = p; after = f }
                }
            }
            lock.lock()
            samples[i] = s
            usable[i] = s.count >= 200
            fit0[i] = before
            fit[i] = after
            if let result { pose[i] = result; corrected[i] = true }
            done += 1
            let d = done
            lock.unlock()
            if d % 25 == 0 { progress(0.7 * Double(d) / Double(count)) }
        }

        // Pass 2 (twice): photos that still fit badly start again from what their neighbours in time needed.
        for round in 0..<2 {
            let typical = median(fit.indices.filter { usable[$0] }.map { fit[$0].share })
            let poor = (0..<count).filter { usable[$0] && fit[$0].share < 0.8 * typical }
            guard !poor.isEmpty else { break }
            let good = (0..<count).filter { corrected[$0] && fit[$0].share >= 0.8 * typical }
            let poseNow = pose, fitNow = fit
            var updates = [(Int, simd_float4x4, Fit)]()
            DispatchQueue.concurrentPerform(iterations: poor.count) { n in
                let i = poor[n]
                let near = good.filter { $0 != i }.sorted { abs($0 - i) < abs($1 - i) }.prefix(4)
                var best: (simd_float4x4, Fit)?
                for j in near {
                    let start = poseNow[j] * original[j].inverse * original[i]
                    guard let p = icp(samples[i], start, target, Array(fullLadder.dropFirst())) else { continue }
                    let f = fitness(samples[i], p, target)
                    if best == nil || f.share > best!.1.share { best = (p, f) }
                }
                if let best, best.1.share > fitNow[i].share, accept(original[i], best.0, fit0[i], best.1) {
                    lock.lock(); updates.append((i, best.0, best.1)); lock.unlock()
                }
            }
            for (i, p, f) in updates { pose[i] = p; fit[i] = f; corrected[i] = true }
            progress(0.7 + 0.15 * Double(round + 1))
            if updates.isEmpty { break }
        }

        // Photos that still fit far worse than the rest would only paint things in the wrong place.
        let shares = fit.indices.filter { usable[$0] }.map { fit[$0].share }
        let typical = median(shares)
        var keep = [Bool](repeating: true, count: count)
        var dropped = 0
        for i in 0..<count where usable[i] && fit[i].share < max(0.25, 0.6 * typical) {
            keep[i] = false
            dropped += 1
        }
        outcome.fitBefore = median(fit0.indices.filter { usable[$0] }.map { fit0[$0].share })
        guard Double(dropped) <= 0.35 * Double(count) else {
            // The mesh and the photos disagree too widely to judge by; leave everything as it was.
            return outcome
        }
        outcome.fitAfter = typical
        outcome.keep = keep
        outcome.dropped = dropped
        for i in 0..<count where corrected[i] && keep[i] {
            var f = frames[i]
            f.worldToCamera = pose[i].inverse
            f.cameraPosition = SIMD3(pose[i].columns.3.x, pose[i].columns.3.y, pose[i].columns.3.z)
            outcome.frames[i] = f
            outcome.corrected += 1
            outcome.largestMove = max(outcome.largestMove, simd_distance(f.cameraPosition, frames[i].cameraPosition))
        }
        progress(1)
        return outcome
    }

    // MARK: Pieces

    /// Camera-space points from the photo's depth map, skipping depth edges (unreliable "flying" pixels).
    private static func depthSamples(_ f: Keyframe) -> [SIMD3<Float>] {
        let w = Keyframe.width, h = Keyframe.height
        guard f.depth.count == w * h else { return [] }
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(2000)
        for v in stride(from: 4, to: h - 4, by: 5) {
            for u in stride(from: 4, to: w - 4, by: 5) {
                let z = Float(f.depth[v * w + u])
                guard z > 0.3, z < 4.0 else { continue }
                let n1 = Float(f.depth[v * w + u - 2]), n2 = Float(f.depth[v * w + u + 2]), n3 = Float(f.depth[(v - 2) * w + u]), n4 = Float(f.depth[(v + 2) * w + u])
                guard n1 > 0, n2 > 0, n3 > 0, n4 > 0 else { continue }
                let jump = max(abs(n1 - z), abs(n2 - z), abs(n3 - z), abs(n4 - z))
                guard jump < 0.04 * z + 0.02 else { continue }
                samples.append(SIMD3((Float(u) - f.cx) / f.fx * z, -(Float(v) - f.cy) / f.fy * z, -z))
            }
        }
        return samples
    }

    private static func fitness(_ samples: [SIMD3<Float>], _ pose: simd_float4x4, _ target: Target) -> Fit {
        var inliers = 0
        var sum: Float = 0
        for s in samples {
            let p4 = pose * SIMD4(s, 1)
            let p = SIMD3(p4.x, p4.y, p4.z)
            guard let j = target.fine.nearest(p, maxDist: 0.06, in: target.centres) else { continue }
            let r = abs(simd_dot(target.normals[j], p - target.centres[j]))
            if r < 0.04 { inliers += 1; sum += r }
        }
        guard inliers > 0 else { return Fit() }
        return Fit(share: Float(inliers) / Float(samples.count), error: sum / Float(inliers))
    }

    /// A correction is taken only if it clearly improves the fit and stays within what drift can explain.
    private static func accept(_ from: simd_float4x4, _ to: simd_float4x4, _ before: Fit, _ after: Fit) -> Bool {
        let moved = simd_distance(SIMD3(to.columns.3.x, to.columns.3.y, to.columns.3.z),
                                  SIMD3(from.columns.3.x, from.columns.3.y, from.columns.3.z))
        let r0 = simd_float3x3(SIMD3(from.columns.0.x, from.columns.0.y, from.columns.0.z),
                               SIMD3(from.columns.1.x, from.columns.1.y, from.columns.1.z),
                               SIMD3(from.columns.2.x, from.columns.2.y, from.columns.2.z))
        let r1 = simd_float3x3(SIMD3(to.columns.0.x, to.columns.0.y, to.columns.0.z),
                               SIMD3(to.columns.1.x, to.columns.1.y, to.columns.1.z),
                               SIMD3(to.columns.2.x, to.columns.2.y, to.columns.2.z))
        let d = r1 * r0.transpose
        let trace: Float = d[0][0] + d[1][1] + d[2][2]
        let angle = acos(min(1, max(-1, (trace - 1) / 2)))
        let better = after.share >= before.share + 0.02 || (after.share >= before.share && after.error < before.error * 0.95)
        return after.share >= 0.45 && better && moved < 1.5 && angle < 0.35
    }

    /// Point-to-plane ICP down the given ladder of search distances. Returns the new camera-to-world pose.
    private static func icp(_ samples: [SIMD3<Float>], _ start: simd_float4x4, _ target: Target,
                            _ ladder: [(Float, Int)]) -> simd_float4x4? {
        var pose = start
        for (maxDist, rounds) in ladder {
            let grid = target.grid(for: maxDist)
            // The wide stages only need the overall shape, so they use a third of the points.
            let skip = maxDist > 0.12 ? 3 : 1
            let needed = maxDist > 0.12 ? 60 : 120
            let delta = max(0.015, maxDist / 8)
            for _ in 0..<rounds {
                let centre = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
                var A = [Double](repeating: 0, count: 36)
                var b = [Double](repeating: 0, count: 6)
                var hits = 0
                var index = 0
                while index < samples.count {
                    let p4 = pose * SIMD4(samples[index], 1)
                    index += skip
                    let p = SIMD3(p4.x, p4.y, p4.z)
                    guard let j = grid.nearest(p, maxDist: maxDist, in: target.centres) else { continue }
                    let n = target.normals[j]
                    let r = simd_dot(n, p - target.centres[j])
                    // Huber weight keeps bad matches (moved furniture, people) from pulling the camera.
                    let weight = abs(r) < delta ? 1 : delta / abs(r)
                    let arm = simd_cross(p - centre, n)
                    let J = [Double(arm.x), Double(arm.y), Double(arm.z), Double(n.x), Double(n.y), Double(n.z)]
                    let rw = Double(r * weight), wd = Double(weight)
                    for a in 0..<6 {
                        b[a] -= J[a] * rw
                        for c in a..<6 { A[a * 6 + c] += J[a] * J[c] * wd }
                    }
                    hits += 1
                }
                guard hits >= needed else { return nil }
                for a in 0..<6 { for c in 0..<a { A[a * 6 + c] = A[c * 6 + a] } }
                // Damping, separately for turning and moving: a photo that only sees one wall or the floor can
                // slide along it without changing the fit, so directions the depth doesn't pin down stay put.
                let turn = (A[0] + A[7] + A[14]) / 3, move = (A[21] + A[28] + A[35]) / 3
                for a in 0..<3 { A[a * 6 + a] += 0.02 * turn }
                for a in 3..<6 { A[a * 6 + a] += 0.02 * move }
                guard let x = solve6(A, b), x.allSatisfy({ $0.isFinite }) else { return nil }
                var omega = SIMD3(Float(x[0]), Float(x[1]), Float(x[2])), t = SIMD3(Float(x[3]), Float(x[4]), Float(x[5]))
                let maxMove = maxDist / 2, maxTurn: Float = maxDist > 0.1 ? 0.06 : 0.02
                if simd_length(t) > maxMove { t *= maxMove / simd_length(t) }
                if simd_length(omega) > maxTurn { omega *= maxTurn / simd_length(omega) }
                let angle = simd_length(omega)
                let rot = angle > 1e-9 ? simd_float4x4(simd_quatf(angle: angle, axis: omega / angle)) : matrix_identity_float4x4
                pose = translation(centre + t) * rot * translation(-centre) * pose
                if angle < 1e-4 && simd_length(t) < 1e-4 { break }
            }
        }
        return pose
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[s.count / 2]
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
