import Foundation
import UIKit
import CoreImage
import simd

/// Builds photo textures for a scanned mesh: every triangle takes its pixels from the photo
/// that saw it best (sharp, close, head-on, not blocked), and the used parts of the photos are
/// packed into a few large texture pages.
enum Texturer {
    static let pageSize = 4096
    static let maxPages = 8

    struct Progress { var message: String; var fraction: Double }

    static func build(mesh: MeshData, keyframes: [Keyframe], photos: URL, output folder: URL,
                      progress: (Progress) -> Void) throws -> TexturedMesh {
        let frames = keyframes.filter { FileManager.default.fileExists(atPath: photos.appendingPathComponent(Keyframe.photoName($0.photo)).path) }
        let triCount = mesh.triangleCount
        guard !frames.isEmpty, triCount > 0 else { return TexturedMesh() }
        let W = Float(Keyframe.photoWidth), H = Float(Keyframe.photoHeight)
        let k = W / Float(Keyframe.width)               // keyframe → photo pixel scale
        let dw = Keyframe.width, dh = Keyframe.height
        let flip: Float = SceneExport.facesTowardNormals(mesh) ? 1 : -1
        let meanSharpness = frames.reduce(0) { $0 + $1.sharpness } / Float(frames.count)
        let sharpWeight = frames.map { min(1.5, max(0.4, ($0.sharpness / max(meanSharpness, 1)).squareRoot())) }

        /// Score of seeing triangle t in frame f (0 = not usable), and its three photo pixel positions.
        func score(_ t: Int, _ fi: Int) -> Float {
            let f = frames[fi]
            let a = mesh.positions[Int(mesh.indices[3 * t])], b = mesh.positions[Int(mesh.indices[3 * t + 1])], c = mesh.positions[Int(mesh.indices[3 * t + 2])]
            var zs = SIMD3<Float>()
            for (i, p) in [a, b, c].enumerated() {
                let q = f.worldToCamera * SIMD4(p, 1)
                let z = -q.z
                guard z > 0.15 else { return 0 }
                let u = (f.fx * q.x / z + f.cx) * k, v = (f.cy - f.fy * q.y / z) * k
                guard u > 3, v > 3, u < W - 3, v < H - 3 else { return 0 }
                zs[i] = z
            }
            let centre = (a + b + c) / 3
            let qc = f.worldToCamera * SIMD4(centre, 1)
            let zc = -qc.z
            if !f.depth.isEmpty {
                let ui = Int(f.fx * qc.x / zc + f.cx), vi = Int(f.cy - f.fy * qc.y / zc)
                if ui >= 0, vi >= 0, ui < dw, vi < dh {
                    let d = f.depth[vi * dw + ui]
                    if d > 0 && abs(d - zc) > 0.05 + 0.03 * zc { return 0 }
                }
            }
            let n = mesh.faceNormal(t) * flip
            let facing = simd_dot(n, simd_normalize(f.cameraPosition - centre))
            guard facing > 0.2 else { return 0 }
            // Head-on and close wins; a view near the image centre is a little sharper.
            let u = (f.fx * qc.x / zc + f.cx) / Float(dw) - 0.5, v = (f.cy - f.fy * qc.y / zc) / Float(dh) - 0.5
            let centred = 1 - 0.4 * (u * u + v * v)
            return facing * facing * centred * sharpWeight[fi] / (0.3 + zc)
        }

        // Pass 1: best view per triangle, counted as votes per photo.
        progress(Progress(message: "Choosing the best photo for each surface…", fraction: 0))
        var best = [Int32](repeating: -1, count: triCount)
        var bestScore = [Float](repeating: 0, count: triCount)
        let chunks = max(1, min(64, triCount / 2000))
        let chunkSize = (triCount + chunks - 1) / chunks
        best.withUnsafeMutableBufferPointer { bestBuf in
            bestScore.withUnsafeMutableBufferPointer { scoreBuf in
                DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                    for t in (ci * chunkSize)..<min(triCount, (ci + 1) * chunkSize) {
                        var bs: Float = 0, bi: Int32 = -1
                        for fi in frames.indices {
                            let s = score(t, fi)
                            if s > bs { bs = s; bi = Int32(fi) }
                        }
                        bestBuf[t] = bi; scoreBuf[t] = bs
                    }
                }
            }
        }
        progress(Progress(message: "Choosing the best photo for each surface…", fraction: 0.4))

        // Pass 2: among near-best views prefer popular photos, which gives larger, seamless patches.
        var votes = [Int](repeating: 0, count: frames.count)
        for b in best where b >= 0 { votes[Int(b)] += 1 }
        let maxVotes = Float(max(1, votes.max() ?? 1))
        var choice = best
        choice.withUnsafeMutableBufferPointer { choiceBuf in
            DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                for t in (ci * chunkSize)..<min(triCount, (ci + 1) * chunkSize) where best[t] >= 0 {
                    var bs: Float = 0, bi = best[t]
                    for fi in frames.indices where votes[fi] > 0 {
                        let s = score(t, fi)
                        guard s > bestScore[t] * 0.7 else { continue }
                        let w = s * (0.6 + 0.4 * Float(votes[fi]) / maxVotes)
                        if w > bs { bs = w; bi = Int32(fi) }
                    }
                    choiceBuf[t] = bi
                }
            }
        }
        progress(Progress(message: "Blending photo seams…", fraction: 0.6))

        // Pass 3: let each triangle follow its neighbours' photo when that photo also sees it well,
        // which removes small islands and most visible seams.
        var edgeTris: [UInt64: [Int32]] = [:]
        edgeTris.reserveCapacity(triCount * 2)
        for t in 0..<triCount {
            for j in 0..<3 {
                let a = mesh.indices[3 * t + j], b = mesh.indices[3 * t + (j + 1) % 3]
                edgeTris[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: []].append(Int32(t))
            }
        }
        var adjacency = [[Int32]](repeating: [], count: triCount)
        for (_, tris) in edgeTris where tris.count == 2 {
            adjacency[Int(tris[0])].append(tris[1]); adjacency[Int(tris[1])].append(tris[0])
        }
        edgeTris = [:]
        for _ in 0..<4 {
            for t in 0..<triCount where choice[t] >= 0 && !adjacency[t].isEmpty {
                var counts: [Int32: Int] = [:]
                for nb in adjacency[Int(t)] where choice[Int(nb)] >= 0 { counts[choice[Int(nb)], default: 0] += 1 }
                guard let top = counts.max(by: { $0.value < $1.value }), top.key != choice[t], top.value >= 2 else { continue }
                if score(t, Int(top.key)) >= bestScore[t] * 0.45 { choice[t] = top.key }
            }
        }

        // Exposure: a brightness/colour gain per photo so neighbouring photos match.
        progress(Progress(message: "Matching photo brightness…", fraction: 0.66))
        let gains = exposureGains(mesh: mesh, frames: frames)

        progress(Progress(message: "Packing photo textures…", fraction: 0.7))

        // Group triangles by photo and find the part of each photo they use.
        var groups = [[Int]](repeating: [], count: frames.count)
        var untextured: [Int] = []
        for t in 0..<triCount { if choice[t] >= 0 { groups[Int(choice[t])].append(t) } else { untextured.append(t) } }

        func pixel(_ p: SIMD3<Float>, _ f: Keyframe) -> SIMD2<Float> {
            let q = f.worldToCamera * SIMD4(p, 1)
            let z = -q.z
            return SIMD2((f.fx * q.x / z + f.cx) * k, (f.cy - f.fy * q.y / z) * k)
        }

        struct Crop { var frame: Int; var rect: CGRect; var page = 0; var origin = CGPoint.zero }
        var crops: [Crop] = []
        for (fi, tris) in groups.enumerated() where !tris.isEmpty {
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for t in tris {
                for j in 0..<3 {
                    let px = pixel(mesh.positions[Int(mesh.indices[3 * t + j])], frames[fi])
                    lo = simd_min(lo, px); hi = simd_max(hi, px)
                }
            }
            let pad: Float = 6
            lo = simd_max(lo - pad, .zero); hi = simd_min(hi + pad, SIMD2(W, H))
            crops.append(Crop(frame: fi, rect: CGRect(x: CGFloat(lo.x.rounded(.down)), y: CGFloat(lo.y.rounded(.down)),
                                                      width: CGFloat((hi.x - lo.x).rounded(.up)), height: CGFloat((hi.y - lo.y).rounded(.up)))))
        }

        // Shrink everything evenly if the photos would need more than `maxPages` pages.
        let page = CGFloat(pageSize)
        let area = crops.reduce(CGFloat(0)) { $0 + ($1.rect.width + 2) * ($1.rect.height + 2) }
        var scale = min(1, sqrt(page * page * CGFloat(maxPages) * 0.8 / max(area, 1)))
        var pages = 1
        func pack() -> Bool {
            pages = 1
            var x: CGFloat = 0, y: CGFloat = 0, shelf: CGFloat = 0
            for i in crops.indices.sorted(by: { crops[$0].rect.height > crops[$1].rect.height }) {
                let w = (crops[i].rect.width * scale).rounded(.up) + 2, h = (crops[i].rect.height * scale).rounded(.up) + 2
                if x + w > page { x = 0; y += shelf; shelf = 0 }
                if y + h > page { pages += 1; x = 0; y = 0; shelf = 0 }
                if pages > maxPages { return false }
                crops[i].page = pages - 1
                crops[i].origin = CGPoint(x: x + 1, y: y + 1)
                x += w; shelf = max(shelf, h)
            }
            return true
        }
        while !pack() { scale *= 0.9 }

        // Draw the pages.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let ci = CIContext(options: [.cacheIntermediates: false])
        for p in 0..<pages {
            progress(Progress(message: "Building texture \(p + 1) of \(pages)…", fraction: 0.75 + 0.2 * Double(p) / Double(pages)))
            try autoreleasepool {
                let image = UIGraphicsImageRenderer(size: CGSize(width: page, height: page), format: format).image { ctx in
                    UIColor(white: 0.5, alpha: 1).setFill()
                    ctx.fill(CGRect(x: 0, y: 0, width: page, height: page))
                    for crop in crops where crop.page == p {
                        autoreleasepool {
                            let url = photos.appendingPathComponent(Keyframe.photoName(frames[crop.frame].photo))
                            guard let photo = UIImage(contentsOfFile: url.path)?.cgImage,
                                  var part = photo.cropping(to: crop.rect) else { return }
                            let g = gains[crop.frame]
                            if abs(g.x - 1) + abs(g.y - 1) + abs(g.z - 1) > 0.02 {
                                let image = CIImage(cgImage: part).applyingFilter("CIColorMatrix", parameters: [
                                    "inputRVector": CIVector(x: CGFloat(g.x), y: 0, z: 0, w: 0),
                                    "inputGVector": CIVector(x: 0, y: CGFloat(g.y), z: 0, w: 0),
                                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(g.z), w: 0),
                                ])
                                if let adjusted = ci.createCGImage(image, from: image.extent) { part = adjusted }
                            }
                            UIImage(cgImage: part).draw(in: CGRect(x: crop.origin.x, y: crop.origin.y,
                                                                   width: crop.rect.width * scale, height: crop.rect.height * scale))
                        }
                    }
                }
                guard let data = image.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: folder.appendingPathComponent(TexturedMesh.textureName(p)), options: .atomic)
            }
        }

        // Build the textured geometry (vertices are per triangle so each can have its own UVs).
        var result = TexturedMesh()
        result.pages = Array(repeating: TexturedMesh.Page(), count: pages)
        for crop in crops {
            let f = frames[crop.frame]
            // Move the page out so appends don't copy it.
            var pg = result.pages[crop.page]
            result.pages[crop.page] = TexturedMesh.Page()
            for t in groups[crop.frame] {
                for j in 0..<3 {
                    let vi = Int(mesh.indices[3 * t + j])
                    let px = pixel(mesh.positions[vi], f)
                    let u = (CGFloat(px.x) - crop.rect.minX) * scale + crop.origin.x
                    let v = (CGFloat(px.y) - crop.rect.minY) * scale + crop.origin.y
                    pg.indices.append(UInt32(pg.positions.count))
                    pg.positions.append(mesh.positions[vi])
                    if mesh.hasNormals { pg.normals.append(mesh.normals[vi]) }
                    pg.uvs.append(SIMD2(Float(u / page), Float(v / page)))
                }
            }
            result.pages[crop.page] = pg
        }
        var rest = MeshData()
        for t in untextured {
            for j in 0..<3 {
                let vi = Int(mesh.indices[3 * t + j])
                rest.indices.append(UInt32(rest.positions.count))
                rest.positions.append(mesh.positions[vi])
                if mesh.hasNormals { rest.normals.append(mesh.normals[vi]) }
                if mesh.hasColors { rest.colors.append(mesh.colors[vi]) }
            }
        }
        result.untextured = rest
        progress(Progress(message: "Saving…", fraction: 0.97))
        return result
    }

    /// Per-photo RGB gains that bring every photo's view of shared surfaces to the average of all views.
    static func exposureGains(mesh: MeshData, frames: [Keyframe]) -> [SIMD3<Float>] {
        let w = Keyframe.width, h = Keyframe.height
        var num = [SIMD3<Float>](repeating: .zero, count: frames.count)
        var den = [SIMD3<Float>](repeating: .zero, count: frames.count)
        let stride = max(1, mesh.vertexCount / 15000)
        var obs: [(Int, SIMD3<Float>)] = []
        for i in Swift.stride(from: 0, to: mesh.vertexCount, by: stride) {
            let p = mesh.positions[i]
            obs.removeAll(keepingCapacity: true)
            for (fi, f) in frames.enumerated() {
                let q = f.worldToCamera * SIMD4(p, 1)
                let z = -q.z
                guard z > 0.15 else { continue }
                let u = f.fx * q.x / z + f.cx, v = f.cy - f.fy * q.y / z
                guard u >= 1, v >= 1, u < Float(w - 1), v < Float(h - 1) else { continue }
                let ui = Int(u), vi = Int(v)
                if !f.depth.isEmpty {
                    let d = f.depth[vi * w + ui]
                    if d > 0 && abs(d - z) > 0.05 + 0.03 * z { continue }
                }
                let o = (vi * w + ui) * 3
                let c = SIMD3<Float>(Float(f.rgb[o]), Float(f.rgb[o + 1]), Float(f.rgb[o + 2]))
                // Ignore clipped and near-black pixels; they carry no exposure information.
                if c.max() > 250 || c.min() < 8 { continue }
                obs.append((fi, c))
            }
            guard obs.count >= 2 else { continue }
            let mean = obs.reduce(SIMD3<Float>.zero) { $0 + $1.1 } / Float(obs.count)
            for (fi, c) in obs { num[fi] += mean; den[fi] += c }
        }
        return zip(num, den).map { pair -> SIMD3<Float> in
            let (n, d) = pair
            guard d.x > 0, d.y > 0, d.z > 0 else { return SIMD3(1, 1, 1) }
            let g = n / d
            return SIMD3(min(1.6, max(0.6, g.x)), min(1.6, max(0.6, g.y)), min(1.6, max(0.6, g.z)))
        }
    }
}
