import Foundation
import CoreGraphics
import ImageIO
import simd

// Turns the photos of a 360 capture into one equirectangular panorama (2:1, longitude across, latitude down).
// Only Foundation, CoreGraphics, ImageIO and simd are used, so the same file also builds into a command-line
// test on a Mac (Tests/Panorama), which checks it against a synthetic scene.
//
// Steps:
//  1. Load every photo at the resolution the output needs.
//  2. Fine-tune where each photo points. ARKit's directions are good but often a fraction of a degree off,
//     which shows as doubled edges. For every pair of overlapping photos, both are projected onto a shared
//     flat patch where they overlap, and the shift that lines them up best is measured (normalised cross-
//     correlation). One small rotation per photo is then solved that agrees with all those shifts. If that
//     makes things worse, ARKit's directions are kept.
//  3. Even out brightness between photos (one gain per photo and colour, from the overlaps).
//  4. Paint the panorama: each output pixel is a weighted mix of the photos that see it, weighted toward
//     each photo's centre so changes from one photo to the next are gradual.
//  5. Fill anything no photo saw (usually straight down) with the surrounding colours.

/// One photo of a 360 capture: where the camera pointed and its lens, in ARKit's conventions.
struct PanoShot: Codable {
    var file: String
    /// Size of the image the intrinsics below refer to.
    var width: Int
    var height: Int
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    /// Camera-to-world rotation, row-major. Camera axes: x right, y up (in the image), looking along -z.
    var rotation: [Double]

    var matrix: simd_double3x3 {
        get {
            simd_double3x3(rows: [SIMD3<Double>(rotation[0], rotation[1], rotation[2]),
                                  SIMD3<Double>(rotation[3], rotation[4], rotation[5]),
                                  SIMD3<Double>(rotation[6], rotation[7], rotation[8])])
        }
        set {
            var r = [Double](repeating: 0, count: 9)
            for row in 0..<3 { for col in 0..<3 { r[row * 3 + col] = newValue[col][row] } }
            rotation = r
        }
    }
}

/// What is saved next to the photos (shots.json).
struct PanoCapture: Codable {
    var version = 1
    var created = Date()
    var shots: [PanoShot]
}

enum PanoramaError: LocalizedError {
    case noShots
    case unreadable(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noShots: return "There are no photos to stitch."
        case .unreadable(let name): return "The photo \(name) couldn't be read."
        case .writeFailed: return "The panorama couldn't be saved."
        }
    }
}

struct PanoramaStitcher {
    struct Options {
        /// Output width in pixels (height is half). 8192 is what most 360 viewers expect.
        var width = 8192
        /// Fine-tune the photo directions by matching overlaps.
        var refine = true
        /// Even out brightness between photos.
        var gainCompensation = true
        /// Higher = narrower changeover between photos (less ghosting, more visible seams).
        var blendPower = 3
    }

    struct Report {
        var shots = 0
        var pairsMeasured = 0
        var pairsUsed = 0
        /// Typical misalignment between overlapping photos, in degrees, before and after fine-tuning.
        var misalignmentBefore = 0.0
        var misalignmentAfter = 0.0
        var refinementKept = false
        var largestCorrection = 0.0
        var gains: [SIMD3<Float>] = []
        var uncoveredFraction = 0.0
        var seconds = 0.0

        var summary: String {
            var lines = ["shots: \(shots)"]
            if pairsMeasured > 0 {
                lines.append(String(format: "overlaps measured: %d, used: %d", pairsMeasured, pairsUsed))
                lines.append(String(format: "misalignment: %.2f° before, %.2f° after (%@)", misalignmentBefore, misalignmentAfter,
                                    refinementKept ? "kept" : "not kept, ARKit's directions used"))
                lines.append(String(format: "largest correction: %.2f°", largestCorrection))
            }
            if !gains.isEmpty {
                let g = gains.map { ($0.x + $0.y + $0.z) / 3 }
                lines.append(String(format: "brightness gains: %.2f to %.2f", g.min() ?? 1, g.max() ?? 1))
            }
            lines.append(String(format: "not seen by any photo: %.1f%%", uncoveredFraction * 100))
            lines.append(String(format: "time: %.1f s", seconds))
            return lines.joined(separator: "\n")
        }
    }

    struct Output {
        var image: CGImage
        /// The directions actually used (after fine-tuning), camera-to-world, one per shot.
        var rotations: [simd_double3x3]
        var report: Report
    }

    typealias Progress = (Double, String) -> Void

    // MARK: - Stitching

    static func stitch(folder: URL, shots: [PanoShot], options: Options = Options(),
                       progress: Progress = { _, _ in }) throws -> Output {
        guard !shots.isEmpty else { throw PanoramaError.noShots }
        let start = Date()
        var report = Report()
        report.shots = shots.count
        let W = max(256, options.width / 2 * 2), H = W / 2

        // 1. Photos, at about the resolution the output needs (a little more, for sharpness).
        let pxPerRadian = Double(W) / (2 * .pi)
        var sources: [Source] = []
        for (i, shot) in shots.enumerated() {
            progress(0.25 * Double(i) / Double(shots.count), "Loading photo \(i + 1) of \(shots.count)")
            let scale = min(1.0, pxPerRadian * 1.15 / shot.fx)
            let maxPixel = Int((Double(max(shot.width, shot.height)) * scale).rounded())
            sources.append(try Source(url: folder.appendingPathComponent(shot.file), shot: shot, maxPixel: maxPixel))
        }

        // 2. Directions.
        let original = sources.map(\.rotation)
        if options.refine && sources.count > 1 {
            refine(sources, report: &report, progress: { f, s in progress(0.25 + 0.35 * f, s) })
            if !report.refinementKept {
                for (s, r) in zip(sources, original) { s.rotation = r }
            }
        }

        // 3. Brightness.
        if options.gainCompensation && sources.count > 1 {
            progress(0.62, "Matching brightness")
            let gains = gainCompensation(sources)
            for (s, g) in zip(sources, gains) { s.gain = g }
            report.gains = gains
        }

        // 4 and 5. Paint, then fill.
        progress(0.65, "Painting the panorama")
        let forward = sources[0].rotation * SIMD3<Double>(0, 0, -1)
        let yaw0 = atan2(forward.x, -forward.z)          // the first photo is the middle of the panorama
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: W * H * 4)
        defer { pixels.deallocate() }
        let covered = composite(sources, into: pixels, width: W, height: H, yaw0: yaw0, power: options.blendPower,
                                progress: { f in progress(0.65 + 0.3 * f, "Painting the panorama") })
        report.uncoveredFraction = 1 - Double(covered) / Double(W * H)
        if covered < W * H {
            progress(0.96, "Filling gaps")
            fillGaps(pixels, width: W, height: H)
        }
        guard let image = makeImage(pixels, width: W, height: H) else { throw PanoramaError.writeFailed }
        report.seconds = Date().timeIntervalSince(start)
        progress(1, "Done")
        return Output(image: image, rotations: sources.map(\.rotation), report: report)
    }

    // MARK: - Photos in memory

    final class Source {
        let w: Int, h: Int
        let fx: Double, fy: Double, cx: Double, cy: Double
        let rgba: UnsafeMutablePointer<UInt8>
        var rotation: simd_double3x3
        var gain = SIMD3<Float>(1, 1, 1)
        /// Small grey copy for alignment, with matching intrinsics.
        var grey: [Float] = []
        var gw = 0, gh = 0
        var gfx = 0.0, gfy = 0.0, gcx = 0.0, gcy = 0.0

        init(url: URL, shot: PanoShot, maxPixel: Int) throws {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PanoramaError.unreadable(shot.file) }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
                                         kCGImageSourceCreateThumbnailWithTransform: false,
                                         kCGImageSourceShouldCacheImmediately: true]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw PanoramaError.unreadable(shot.file)
            }
            w = img.width
            h = img.height
            rgba = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
            guard let ctx = CGContext(data: rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                rgba.deallocate()
                throw PanoramaError.unreadable(shot.file)
            }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            // Pixel centres are at whole numbers, so scaling keeps (c + 0.5) proportional.
            let s = Double(w) / Double(shot.width)
            fx = shot.fx * s
            fy = shot.fy * Double(h) / Double(shot.height)
            cx = (shot.cx + 0.5) * s - 0.5
            cy = (shot.cy + 0.5) * Double(h) / Double(shot.height) - 0.5
            rotation = shot.matrix
        }

        deinit { rgba.deallocate() }

        var centre: SIMD3<Double> { rotation * SIMD3<Double>(0, 0, -1) }

        /// Angle from the centre of the photo to its corner.
        var radius: Double {
            atan(sqrt(pow(Double(w) / 2 / fx, 2) + pow(Double(h) / 2 / fy, 2)))
        }

        /// Builds the small grey copy, about `focal` pixels per radian.
        func makeGrey(focal: Double) {
            let k = max(1, Int((fx / focal).rounded(.down)))
            gw = w / k
            gh = h / k
            grey = [Float](repeating: 0, count: gw * gh)
            let inv = 1 / Float(k * k)
            for y in 0..<gh {
                for x in 0..<gw {
                    var sum: Float = 0
                    for dy in 0..<k {
                        let row = rgba + ((y * k + dy) * w + x * k) * 4
                        for dx in 0..<k {
                            let p = row + dx * 4
                            sum += 0.299 * Float(p[0]) + 0.587 * Float(p[1]) + 0.114 * Float(p[2])
                        }
                    }
                    grey[y * gw + x] = sum * inv
                }
            }
            let s = 1 / Double(k)
            gfx = fx * s
            gfy = fy * s
            gcx = (cx + 0.5) * s - 0.5
            gcy = (cy + 0.5) * s - 0.5
        }
    }

    // MARK: - Fine-tuning directions

    /// Patch size (pixels) and how much of the sky it covers (radians across).
    private static let patch = 192
    private static let patchFocal = Double(patch / 2) / tan(15.0 * .pi / 180)

    private struct Pair { var i: Int; var j: Int }
    private struct Measurement {
        var i: Int, j: Int
        var right: SIMD3<Double>, up: SIMD3<Double>
        /// Shift (patch pixels) that moves photo j's content onto photo i's.
        var shift: SIMD2<Double>
        var score: Double
    }

    private static func refine(_ sources: [Source], report: inout Report, progress: Progress) {
        progress(0, "Lining photos up")
        let startRotations = sources.map(\.rotation)
        for s in sources { s.makeGrey(focal: patchFocal) }
        // Candidate pairs: photos whose centres are close enough that they may overlap.
        var pairs: [Pair] = []
        for i in 0..<sources.count {
            for j in (i + 1)..<sources.count {
                let angle = acos(max(-1, min(1, simd_dot(sources[i].centre, sources[j].centre))))
                if angle < 0.9 * (sources[i].radius + sources[j].radius) { pairs.append(Pair(i: i, j: j)) }
            }
        }
        guard !pairs.isEmpty else { return }

        let rounds = 3
        var first: [Measurement] = []
        var last: [Measurement] = []
        for round in 0...rounds {
            progress(Double(round) / Double(rounds + 1), "Lining photos up (round \(round + 1) of \(rounds + 1))")
            // The first round searches up to about ±4°; after that what's left is small.
            let found = measure(sources, pairs: pairs, reach: round == 0 ? 12 : 4)
            if round == 0 {
                first = found
                report.pairsMeasured = found.count
            }
            last = found
            if round == rounds || found.count < 1 { break }
            let (corrections, used) = solve(found, count: sources.count)
            report.pairsUsed = used
            for (k, w) in corrections.enumerated() where k > 0 {
                sources[k].rotation = exp(w) * sources[k].rotation
            }
        }
        // Compare like with like: the pairs measured in both the first and last rounds.
        let before = Dictionary(first.map { ("\($0.i)-\($0.j)", $0) }, uniquingKeysWith: { a, _ in a })
        var b: [Double] = [], a: [Double] = []
        for m in last {
            guard let m0 = before["\(m.i)-\(m.j)"] else { continue }
            b.append(simd_length(m0.shift) / patchFocal * 180 / .pi)
            a.append(simd_length(m.shift) / patchFocal * 180 / .pi)
        }
        guard !b.isEmpty else { return }
        report.misalignmentBefore = median(b)
        report.misalignmentAfter = median(a)
        report.refinementKept = report.misalignmentAfter <= report.misalignmentBefore * 1.05 && a.count >= max(1, b.count / 2)
        // How far any photo was turned, for the report.
        for (s, r0) in zip(sources, startRotations) {
            let d = s.rotation * r0.transpose
            let angle = acos(max(-1, min(1, (d[0][0] + d[1][1] + d[2][2] - 1) / 2))) * 180 / .pi
            report.largestCorrection = max(report.largestCorrection, angle)
        }
    }

    /// Measures every pair that really overlaps and has enough detail to line up.
    private static func measure(_ sources: [Source], pairs: [Pair], reach: Int) -> [Measurement] {
        var results = [Measurement?](repeating: nil, count: pairs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pairs.count) { n in
            let p = pairs[n]
            let m = measurePair(sources[p.i], sources[p.j], i: p.i, j: p.j, reach: reach)
            lock.lock(); results[n] = m; lock.unlock()
        }
        return results.compactMap { $0 }
    }

    private static func basis(_ c: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        var r = simd_cross(c, SIMD3<Double>(0, 1, 0))
        if simd_length(r) < 0.2 { r = simd_cross(c, SIMD3<Double>(1, 0, 0)) }
        r = simd_normalize(r)
        let u = simd_cross(r, c)
        return (r, u)
    }

    private static func measurePair(_ si: Source, _ sj: Source, i: Int, j: Int, reach: Int) -> Measurement? {
        let c = simd_normalize(si.centre + sj.centre)
        let (r, u) = basis(c)
        let P = patch
        let (pi, mi) = renderPatch(si, c: c, r: r, u: u, size: P, focal: patchFocal)
        let (pj, mj) = renderPatch(sj, c: c, r: r, u: u, size: P, focal: patchFocal)
        var both = 0
        for k in 0..<(P * P) where mi[k] && mj[k] { both += 1 }
        guard both > P * P / 8 else { return nil }

        // Coarse search on half-size patches, then fine search, then sub-pixel.
        let (hi, hmi) = halve(pi, mi, P)
        let (hj, hmj) = halve(pj, mj, P)
        let h = P / 2
        var best = (score: -2.0, x: 0, y: 0)
        for sy in -reach...reach {
            for sx in -reach...reach {
                let s = ncc(hi, hmi, hj, hmj, size: h, sx: sx, sy: sy, minCount: h * h / 10)
                if s > best.score { best = (s, sx, sy) }
            }
        }
        // A best match at the very edge of the search means the real shift lies beyond it.
        guard best.score > 0.3, abs(best.x) < reach, abs(best.y) < reach else { return nil }
        var fine = (score: -2.0, x: 0, y: 0)
        var grid = [Int: Double]()
        for sy in (2 * best.y - 2)...(2 * best.y + 2) {
            for sx in (2 * best.x - 2)...(2 * best.x + 2) {
                let s = ncc(pi, mi, pj, mj, size: P, sx: sx, sy: sy, minCount: P * P / 10)
                grid[sy * 1000 + sx] = s
                if s > fine.score { fine = (s, sx, sy) }
            }
        }
        guard fine.score > 0.6 else { return nil }
        // Enough detail? A plain wall gives a high score for any small shift.
        guard detail(pi, mi, mj, P) > 3 else { return nil }
        func at(_ x: Int, _ y: Int) -> Double {
            grid[y * 1000 + x] ?? ncc(pi, mi, pj, mj, size: P, sx: x, sy: y, minCount: P * P / 10)
        }
        func vertex(_ a: Double, _ b: Double, _ c: Double) -> Double {
            let d = a - 2 * b + c
            return abs(d) < 1e-9 ? 0 : max(-0.5, min(0.5, 0.5 * (a - c) / d))
        }
        let dx = vertex(at(fine.x - 1, fine.y), fine.score, at(fine.x + 1, fine.y))
        let dy = vertex(at(fine.x, fine.y - 1), fine.score, at(fine.x, fine.y + 1))
        return Measurement(i: i, j: j, right: r, up: u,
                           shift: SIMD2(Double(fine.x) + dx, Double(fine.y) + dy), score: fine.score)
    }

    /// The photo as seen on a flat patch facing `c` (a = right along r, b = down along -u).
    private static func renderPatch(_ s: Source, c: SIMD3<Double>, r: SIMD3<Double>, u: SIMD3<Double>,
                                    size: Int, focal: Double) -> ([Float], [Bool]) {
        var values = [Float](repeating: 0, count: size * size)
        var mask = [Bool](repeating: false, count: size * size)
        let rt = s.rotation.transpose
        let half = Double(size) / 2
        s.grey.withUnsafeBufferPointer { g in
            for b in 0..<size {
                for a in 0..<size {
                    let d = c + ((Double(a) - half + 0.5) / focal) * r - ((Double(b) - half + 0.5) / focal) * u
                    let cam = rt * d
                    let z = -cam.z
                    guard z > 1e-6 else { continue }
                    let x = s.gcx + s.gfx * cam.x / z
                    let y = s.gcy - s.gfy * cam.y / z
                    guard x >= 1, y >= 1, x < Double(s.gw - 2), y < Double(s.gh - 2) else { continue }
                    let x0 = Int(x), y0 = Int(y)
                    let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
                    let p = y0 * s.gw + x0
                    let top = g[p] * (1 - fx) + g[p + 1] * fx
                    let bottom = g[p + s.gw] * (1 - fx) + g[p + s.gw + 1] * fx
                    values[b * size + a] = top * (1 - fy) + bottom * fy
                    mask[b * size + a] = true
                }
            }
        }
        return (values, mask)
    }

    private static func halve(_ v: [Float], _ m: [Bool], _ size: Int) -> ([Float], [Bool]) {
        let h = size / 2
        var out = [Float](repeating: 0, count: h * h)
        var mask = [Bool](repeating: false, count: h * h)
        for y in 0..<h {
            for x in 0..<h {
                let p = 2 * y * size + 2 * x
                guard m[p], m[p + 1], m[p + size], m[p + size + 1] else { continue }
                out[y * h + x] = (v[p] + v[p + 1] + v[p + size] + v[p + size + 1]) / 4
                mask[y * h + x] = true
            }
        }
        return (out, mask)
    }

    /// Normalised cross-correlation of patch i with patch j moved by (sx, sy).
    private static func ncc(_ vi: [Float], _ mi: [Bool], _ vj: [Float], _ mj: [Bool],
                            size: Int, sx: Int, sy: Int, minCount: Int) -> Double {
        var n = 0
        var si = 0.0, sj = 0.0, sii = 0.0, sjj = 0.0, sij = 0.0
        let y0 = max(0, sy), y1 = min(size, size + sy)
        let x0 = max(0, sx), x1 = min(size, size + sx)
        guard y0 < y1, x0 < x1 else { return -2 }
        for y in y0..<y1 {
            let rowI = y * size, rowJ = (y - sy) * size - sx
            for x in x0..<x1 {
                let p = rowI + x, q = rowJ + x
                guard mi[p], mj[q] else { continue }
                let a = Double(vi[p]), b = Double(vj[q])
                n += 1
                si += a; sj += b; sii += a * a; sjj += b * b; sij += a * b
            }
        }
        guard n >= minCount else { return -2 }
        let N = Double(n)
        let cov = sij - si * sj / N
        let vi2 = sii - si * si / N, vj2 = sjj - sj * sj / N
        guard vi2 > 1e-6, vj2 > 1e-6 else { return -2 }
        return cov / sqrt(vi2 * vj2)
    }

    /// Standard deviation of the overlap in patch i: how much there is to line up on.
    private static func detail(_ v: [Float], _ mi: [Bool], _ mj: [Bool], _ size: Int) -> Double {
        var n = 0.0, s = 0.0, ss = 0.0
        for k in 0..<(size * size) where mi[k] && mj[k] {
            let a = Double(v[k]); n += 1; s += a; ss += a * a
        }
        guard n > 0 else { return 0 }
        return sqrt(max(0, ss / n - (s / n) * (s / n)))
    }

    /// One small rotation per photo (photo 0 stays put) that best explains the measured shifts.
    ///
    /// Turning photo j by a small rotation w (applied in world space) moves its content on the patch by
    /// (-f w·up, -f w·right) pixels. So each pair gives two equations:
    ///   (w_j - w_i)·up = -shift.x / f   and   (w_j - w_i)·right = -shift.y / f.
    /// Pairs that disagree badly with the rest are dropped and the rest solved again.
    private static func solve(_ ms: [Measurement], count: Int) -> ([SIMD3<Double>], Int) {
        var use = [Bool](repeating: true, count: ms.count)
        var result = [SIMD3<Double>](repeating: .zero, count: count)
        for pass in 0..<2 {
            let n = 3 * count
            var A = [Double](repeating: 0, count: n * n)
            var g = [Double](repeating: 0, count: n)
            func add(_ i: Int, _ j: Int, _ a: SIMD3<Double>, _ value: Double, _ weight: Double) {
                for p in 0..<3 {
                    for q in 0..<3 {
                        let v = a[p] * a[q] * weight
                        A[(3 * i + p) * n + 3 * i + q] += v
                        A[(3 * j + p) * n + 3 * j + q] += v
                        A[(3 * i + p) * n + 3 * j + q] -= v
                        A[(3 * j + p) * n + 3 * i + q] -= v
                    }
                    g[3 * j + p] += a[p] * value * weight
                    g[3 * i + p] -= a[p] * value * weight
                }
            }
            for (k, m) in ms.enumerated() where use[k] {
                let w = m.score * m.score
                add(m.i, m.j, m.up, -m.shift.x / patchFocal, w)
                add(m.i, m.j, m.right, -m.shift.y / patchFocal, w)
            }
            // Keep photo 0 fixed, and gently hold everything else where ARKit put it where nothing says otherwise.
            for k in 0..<n { A[k * n + k] += k < 3 ? 1e6 : 1e-3 }
            guard let x = solveLinear(A, g, n) else { return (result, 0) }
            for k in 0..<count {
                var w = SIMD3<Double>(x[3 * k], x[3 * k + 1], x[3 * k + 2])
                let angle = simd_length(w)
                let limit = 3.0 * .pi / 180                       // never more than 3° in one round
                if angle > limit { w *= limit / angle }
                result[k] = w
            }
            guard pass == 0 else { break }
            // Residual of each pair, in patch pixels.
            var residuals: [Double] = []
            for m in ms {
                let d = result[m.j] - result[m.i]
                let ex = -simd_dot(d, m.up) * patchFocal - m.shift.x
                let ey = -simd_dot(d, m.right) * patchFocal - m.shift.y
                residuals.append((ex * ex + ey * ey).squareRoot())
            }
            let limit = max(1.5, 3 * median(residuals))
            var dropped = 0
            for k in 0..<ms.count where residuals[k] > limit { use[k] = false; dropped += 1 }
            if dropped == 0 { break }
        }
        return (result, use.filter { $0 }.count)
    }

    /// Rotation matrix for a small rotation vector (axis × angle).
    static func exp(_ w: SIMD3<Double>) -> simd_double3x3 {
        let angle = simd_length(w)
        guard angle > 1e-12 else { return matrix_identity_double3x3 }
        let k = w / angle
        let K = simd_double3x3(rows: [SIMD3<Double>(0, -k.z, k.y), SIMD3<Double>(k.z, 0, -k.x), SIMD3<Double>(-k.y, k.x, 0)])
        return matrix_identity_double3x3 + sin(angle) * K + (1 - cos(angle)) * (K * K)
    }

    /// Gaussian elimination with partial pivoting; A is n×n, row-major.
    static func solveLinear(_ A0: [Double], _ b0: [Double], _ n: Int) -> [Double]? {
        var A = A0, b = b0
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<max(col + 1, n) where abs(A[row * n + col]) > abs(A[pivot * n + col]) { pivot = row }
            guard abs(A[pivot * n + col]) > 1e-15 else { return nil }
            if pivot != col {
                for k in 0..<n { A.swapAt(col * n + k, pivot * n + k) }
                b.swapAt(col, pivot)
            }
            let inv = 1 / A[col * n + col]
            for row in (col + 1)..<max(col + 1, n) {
                let f = A[row * n + col] * inv
                guard f != 0 else { continue }
                for k in col..<n { A[row * n + k] -= f * A[col * n + k] }
                b[row] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = b[row]
            for k in (row + 1)..<max(row + 1, n) { s -= A[row * n + k] * x[k] }
            x[row] = s / A[row * n + row]
        }
        return x
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: - Brightness

    /// One gain per photo and colour channel, so that photos agree where they overlap (the method of Brown and
    /// Lowe, as used by OpenCV): differences in overlaps are weighed against keeping gains near 1.
    private static func gainCompensation(_ sources: [Source]) -> [SIMD3<Float>] {
        let n = sources.count
        let W = 720, H = 360
        // Mean colour of photo i where it overlaps photo j, and how many samples.
        var sum = [SIMD3<Double>](repeating: .zero, count: n * n)
        var count = [Double](repeating: 0, count: n * n)
        let rts = sources.map { $0.rotation.transpose }
        for y in 0..<H {
            let lat = Double.pi / 2 - (Double(y) + 0.5) / Double(H) * .pi
            for x in 0..<W {
                let lon = (Double(x) + 0.5) / Double(W) * 2 * .pi - .pi
                let d = SIMD3<Double>(cos(lat) * sin(lon), sin(lat), -cos(lat) * cos(lon))
                var seen: [(Int, SIMD3<Double>)] = []
                for (k, s) in sources.enumerated() {
                    guard simd_dot(d, s.centre) > cos(s.radius) else { continue }
                    if let c = sample(s, rts[k], d, edge: 0.1) { seen.append((k, c)) }
                }
                guard seen.count > 1 else { continue }
                for (a, ca) in seen {
                    for (b, _) in seen where b != a {
                        sum[a * n + b] += ca
                        count[a * n + b] += 1
                    }
                }
            }
        }
        let sigmaN = 10.0, sigmaG = 0.1
        var gains = [SIMD3<Float>](repeating: SIMD3<Float>(1, 1, 1), count: n)
        for ch in 0..<3 {
            var A = [Double](repeating: 0, count: n * n)
            var b = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var total = 0.0
                for j in 0..<n where j != i && count[i * n + j] > 0 {
                    let N = count[i * n + j]
                    let Iij = sum[i * n + j][ch] / N
                    let Iji = sum[j * n + i][ch] / count[j * n + i]
                    A[i * n + i] += N * (Iij * Iij / (sigmaN * sigmaN) + 1 / (sigmaG * sigmaG))
                    A[i * n + j] -= N * Iij * Iji / (sigmaN * sigmaN)
                    b[i] += N / (sigmaG * sigmaG)
                    total += N
                }
                if total == 0 { A[i * n + i] = 1; b[i] = 1 }
            }
            guard let g = solveLinear(A, b, n) else { continue }
            for i in 0..<n { gains[i][ch] = Float(max(0.5, min(2, g[i]))) }
        }
        return gains
    }

    /// Colour of photo s in direction d, or nil when outside it (or within `edge` of its border, as a fraction).
    private static func sample(_ s: Source, _ rt: simd_double3x3, _ d: SIMD3<Double>, edge: Double) -> SIMD3<Double>? {
        let cam = rt * d
        let z = -cam.z
        guard z > 1e-6 else { return nil }
        let x = s.cx + s.fx * cam.x / z
        let y = s.cy - s.fy * cam.y / z
        let mx = Double(s.w) * edge, my = Double(s.h) * edge
        guard x >= mx, y >= my, x < Double(s.w - 1) - mx, y < Double(s.h - 1) - my else { return nil }
        let p = s.rgba + (Int(y) * s.w + Int(x)) * 4
        return SIMD3<Double>(Double(p[0]), Double(p[1]), Double(p[2]))
    }

    // MARK: - Painting

    /// Fills `pixels` (RGBA, alpha 255 where some photo was seen, 0 elsewhere). Returns how many pixels were seen.
    private static func composite(_ sources: [Source], into pixels: UnsafeMutablePointer<UInt8>, width W: Int, height H: Int,
                                  yaw0: Double, power: Int, progress: (Double) -> Void) -> Int {
        let tile = 64
        let tilesX = W / tile + (W % tile == 0 ? 0 : 1)
        let tilesY = H / tile + (H % tile == 0 ? 0 : 1)
        // Directions per column and per row, worked out once.
        var sinLon = [Float](repeating: 0, count: W), cosLon = [Float](repeating: 0, count: W)
        for x in 0..<W {
            let lon = (Double(x) + 0.5) / Double(W) * 2 * .pi - .pi + yaw0
            sinLon[x] = Float(sin(lon)); cosLon[x] = Float(cos(lon))
        }
        var sinLat = [Float](repeating: 0, count: H), cosLat = [Float](repeating: 0, count: H)
        for y in 0..<H {
            let lat = Double.pi / 2 - (Double(y) + 0.5) / Double(H) * .pi
            sinLat[y] = Float(sin(lat)); cosLat[y] = Float(cos(lat))
        }
        let cams: [Cam] = sources.map { s in
            let rt = s.rotation.transpose
            func f3(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) }
            let f = simd_float3x3(columns: (f3(rt.columns.0), f3(rt.columns.1), f3(rt.columns.2)))
            return Cam(rt: f, fx: Float(s.fx), fy: Float(s.fy), cx: Float(s.cx), cy: Float(s.cy),
                       hw: Float(s.w - 1) / 2, hh: Float(s.h - 1) / 2, w: s.w, h: s.h, gain: s.gain,
                       rgba: s.rgba, centre: s.centre, radius: s.radius)
        }
        let grid = Grid(width: W, height: H, tile: tile, yaw0: yaw0, power: power,
                        sinLon: sinLon, cosLon: cosLon, sinLat: sinLat, cosLat: cosLat)
        let lock = NSLock()
        var done = 0
        var covered = 0
        DispatchQueue.concurrentPerform(iterations: tilesY) { ty in
            var seen = 0
            for tx in 0..<tilesX {
                seen += paintTile(tx: tx, ty: ty, grid: grid, cams: cams, pixels: pixels)
            }
            lock.lock()
            covered += seen
            done += 1
            if done % 8 == 0 { progress(Double(done) / Double(tilesY)) }
            lock.unlock()
        }
        return covered
    }

    private struct Cam {
        var rt: simd_float3x3
        var fx: Float, fy: Float, cx: Float, cy: Float
        var hw: Float, hh: Float
        var w: Int, h: Int
        var gain: SIMD3<Float>
        var rgba: UnsafeMutablePointer<UInt8>
        var centre: SIMD3<Double>
        var radius: Double
    }

    private struct Grid {
        var width: Int, height: Int, tile: Int
        var yaw0: Double
        var power: Int
        var sinLon: [Float], cosLon: [Float], sinLat: [Float], cosLat: [Float]
    }

    /// Paints one tile of the panorama; returns how many of its pixels some photo saw.
    private static func paintTile(tx: Int, ty: Int, grid: Grid, cams: [Cam], pixels: UnsafeMutablePointer<UInt8>) -> Int {
        let W = grid.width, H = grid.height, tile = grid.tile
        let x0 = tx * tile, y0 = ty * tile
        let x1 = min(W, x0 + tile), y1 = min(H, y0 + tile)
        let lonC: Double = (Double(x0 + x1) / 2) / Double(W) * 2 * Double.pi - Double.pi + grid.yaw0
        let latC: Double = Double.pi / 2 - (Double(y0 + y1) / 2) / Double(H) * Double.pi
        let dc = SIMD3<Double>(cos(latC) * sin(lonC), sin(latC), -cos(latC) * cos(lonC))
        let spanLon: Double = Double(tile) / Double(W) * 2 * Double.pi
        let spanLat: Double = Double(tile) / Double(H) * Double.pi
        let tileRadius: Double = 0.5 * (spanLon * spanLon + spanLat * spanLat).squareRoot()
        let near = cams.filter { cam in
            acos(max(-1, min(1, simd_dot(dc, cam.centre)))) <= cam.radius + tileRadius
        }
        var seen = 0
        for y in y0..<y1 {
            let cl = grid.cosLat[y], sl = grid.sinLat[y]
            for x in x0..<x1 {
                let d = SIMD3<Float>(cl * grid.sinLon[x], sl, -cl * grid.cosLon[x])
                var acc = SIMD3<Float>(repeating: 0)
                var wsum: Float = 0
                for cam in near {
                    if let hit = sample(cam, d, power: grid.power) {
                        acc += hit.0 * hit.1
                        wsum += hit.1
                    }
                }
                let o = pixels + (y * W + x) * 4
                if wsum > 0 {
                    let c = acc / wsum
                    o[0] = byte(c.x); o[1] = byte(c.y); o[2] = byte(c.z); o[3] = 255
                    seen += 1
                } else {
                    o[0] = 0; o[1] = 0; o[2] = 0; o[3] = 0
                }
            }
        }
        return seen
    }

    @inline(__always) private static func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v)).rounded()) }

    /// Colour (with the photo's gain) and blend weight of one photo in direction d, or nil if it doesn't see it.
    @inline(__always) private static func sample(_ cam: Cam, _ d: SIMD3<Float>, power: Int) -> (SIMD3<Float>, Float)? {
        let c = cam.rt * d
        let z = -c.z
        guard z > 1e-6 else { return nil }
        let u: Float = cam.cx + cam.fx * c.x / z
        let v: Float = cam.cy - cam.fy * c.y / z
        guard u >= 0, v >= 0, u < Float(cam.w - 1), v < Float(cam.h - 1) else { return nil }
        let nx: Float = (u - cam.hw) / cam.hw
        let ny: Float = (v - cam.hh) / cam.hh
        let t: Float = (1 - nx * nx) * (1 - ny * ny)
        guard t > 0 else { return nil }
        var weight: Float = 1
        for _ in 0..<power { weight *= t }
        let ix = Int(u), iy = Int(v)
        let fx: Float = u - Float(ix), fy: Float = v - Float(iy)
        let p = cam.rgba + (iy * cam.w + ix) * 4
        let q = p + cam.w * 4
        let w00: Float = (1 - fx) * (1 - fy), w10: Float = fx * (1 - fy)
        let w01: Float = (1 - fx) * fy, w11: Float = fx * fy
        let r: Float = Float(p[0]) * w00 + Float(p[4]) * w10 + Float(q[0]) * w01 + Float(q[4]) * w11
        let g: Float = Float(p[1]) * w00 + Float(p[5]) * w10 + Float(q[1]) * w01 + Float(q[5]) * w11
        let b: Float = Float(p[2]) * w00 + Float(p[6]) * w10 + Float(q[2]) * w01 + Float(q[6]) * w11
        return (SIMD3<Float>(r, g, b) * cam.gain, weight)
    }

    /// Gives every unseen pixel the colour of the nearest seen area: averaged at low resolution, spread outward
    /// level by level (push-pull), then sampled smoothly.
    private static func fillGaps(_ pixels: UnsafeMutablePointer<UInt8>, width W: Int, height H: Int) {
        var lw = min(W, 512), lh = lw / 2
        let cell = W / lw
        lw = W / cell; lh = H / cell
        var colour = [SIMD3<Float>](repeating: .zero, count: lw * lh)
        var weight = [Float](repeating: 0, count: lw * lh)
        for y in 0..<(lh * cell) {
            for x in 0..<(lw * cell) {
                let p = pixels + (y * W + x) * 4
                guard p[3] > 0 else { continue }
                let k = (y / cell) * lw + x / cell
                colour[k] += SIMD3<Float>(Float(p[0]), Float(p[1]), Float(p[2]))
                weight[k] += 1
            }
        }
        // Pyramid of averages.
        var levels: [(c: [SIMD3<Float>], w: [Float], width: Int, height: Int)] = [(colour, weight, lw, lh)]
        while levels.last!.width > 2 && levels.last!.height > 1 {
            let prev = levels.last!
            let nw = prev.width / 2, nh = max(1, prev.height / 2)
            var c = [SIMD3<Float>](repeating: .zero, count: nw * nh)
            var w = [Float](repeating: 0, count: nw * nh)
            for y in 0..<nh {
                for x in 0..<nw {
                    for dy in 0..<2 where 2 * y + dy < prev.height {
                        for dx in 0..<2 {
                            let k = (2 * y + dy) * prev.width + 2 * x + dx
                            c[y * nw + x] += prev.c[k]
                            w[y * nw + x] += prev.w[k]
                        }
                    }
                }
            }
            levels.append((c, w, nw, nh))
        }
        // Down again: empty cells take the coarser level's colour.
        var filled = levels.last!.c.enumerated().map { k, c in levels.last!.w[k] > 0 ? c / levels.last!.w[k] : SIMD3<Float>(repeating: 0) }
        for li in stride(from: levels.count - 2, through: 0, by: -1) {
            let L = levels[li], coarse = levels[li + 1]
            var next = [SIMD3<Float>](repeating: .zero, count: L.width * L.height)
            for y in 0..<L.height {
                for x in 0..<L.width {
                    let k = y * L.width + x
                    if L.w[k] > 0 {
                        next[k] = L.c[k] / L.w[k]
                    } else {
                        let cx = min(coarse.width - 1, x / 2), cy = min(coarse.height - 1, y / 2)
                        next[k] = filled[cy * coarse.width + cx]
                    }
                }
            }
            filled = next
        }
        // Unseen pixels: smooth sample of the filled low-resolution picture.
        DispatchQueue.concurrentPerform(iterations: H) { y in
            let fy = max(0, min(Float(lh - 1), (Float(y) + 0.5) / Float(cell) - 0.5))
            let y0 = Int(fy), y1 = min(lh - 1, y0 + 1), ty = fy - Float(y0)
            for x in 0..<W {
                let p = pixels + (y * W + x) * 4
                guard p[3] == 0 else { continue }
                let fx = max(0, min(Float(lw - 1), (Float(x) + 0.5) / Float(cell) - 0.5))
                let x0 = Int(fx), x1 = min(lw - 1, x0 + 1), tx = fx - Float(x0)
                let top: SIMD3<Float> = filled[y0 * lw + x0] * (1 - tx) + filled[y0 * lw + x1] * tx
                let bottom: SIMD3<Float> = filled[y1 * lw + x0] * (1 - tx) + filled[y1 * lw + x1] * tx
                let c: SIMD3<Float> = top * (1 - ty) + bottom * ty
                p[0] = byte(c.x); p[1] = byte(c.y); p[2] = byte(c.z)
                p[3] = 255
            }
        }
    }

    private static func makeImage(_ pixels: UnsafeMutablePointer<UInt8>, width W: Int, height H: Int) -> CGImage? {
        let data = Data(bytes: pixels, count: W * H * 4) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Saving

    /// Saves as JPEG with the Google "GPano" tags that 360 viewers (Google Photos, Facebook, Kuula, …) look for.
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw PanoramaError.writeFailed
        }
        let meta = CGImageMetadataCreateMutable()
        let ns = "http://ns.google.com/photos/1.0/panorama/" as CFString
        guard CGImageMetadataRegisterNamespaceForPrefix(meta, ns, "GPano" as CFString, nil) else { throw PanoramaError.writeFailed }
        let values: [(String, String)] = [
            ("ProjectionType", "equirectangular"),
            ("UsePanoramaViewer", "True"),
            ("CroppedAreaImageWidthPixels", "\(image.width)"),
            ("CroppedAreaImageHeightPixels", "\(image.height)"),
            ("FullPanoWidthPixels", "\(image.width)"),
            ("FullPanoHeightPixels", "\(image.height)"),
            ("CroppedAreaLeftPixels", "0"),
            ("CroppedAreaTopPixels", "0"),
        ]
        for (key, value) in values {
            CGImageMetadataSetValueWithPath(meta, nil, "GPano:\(key)" as CFString, value as CFString)
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImageAndMetadata(dest, image, meta, options)
        guard CGImageDestinationFinalize(dest) else { throw PanoramaError.writeFailed }
    }
}
