// Checks PanoramaStitcher against a synthetic scene. Built and run by CI on a Mac:
//   swiftc -O App/Sources/Panorama/PanoramaStitcher.swift Tests/Panorama/main.swift -o pano-test && ./pano-test
//
// 30 photos are rendered from a known 360 scene, laid out like the app's guided capture (12 at the horizon,
// 8 looking up, 8 looking down, one straight up and one straight down), each with a slightly different
// brightness. Their directions are then knocked 0.5-1.2 degrees off, as ARKit's can be, and the stitcher must
// (1) find the true directions again and (2) reproduce the scene.

import Foundation
import CoreGraphics
import ImageIO
import simd

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok    " : "  FAIL  ") + what)
    if !ok { failures += 1 }
}

// MARK: Scene: coloured cells (7.5 degrees) with fine stripes, so there is detail to line up on.

func cellHash(_ i: Int, _ j: Int, _ c: Int) -> Double {
    var h = UInt64(bitPattern: Int64(i &* 73856093 ^ j &* 19349663 ^ c &* 83492791))
    h ^= h >> 33; h = h &* 0xff51afd7ed558ccd; h ^= h >> 33
    return Double(h % 1000) / 999
}

func scene(_ d: SIMD3<Double>) -> SIMD3<Double> {
    let lon = atan2(d.x, -d.z), lat = asin(max(-1, min(1, d.y)))
    let i = Int(floor((lon + .pi) / (.pi / 24))), j = Int(floor((lat + .pi / 2) / (.pi / 24)))
    let stripes = 25 * sin(lon * 37) * sin(lat * 41)
    return SIMD3(40 + 170 * cellHash(i, j, 0) + stripes, 40 + 170 * cellHash(i, j, 1) + stripes, 40 + 170 * cellHash(i, j, 2) - stripes)
}

func rotY(_ a: Double) -> simd_double3x3 { simd_double3x3(rows: [SIMD3(cos(a), 0, sin(a)), SIMD3(0, 1, 0), SIMD3(-sin(a), 0, cos(a))]) }
func rotX(_ a: Double) -> simd_double3x3 { simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(a), -sin(a)), SIMD3(0, sin(a), cos(a))]) }
func rotZ(_ a: Double) -> simd_double3x3 { simd_double3x3(rows: [SIMD3(cos(a), -sin(a), 0), SIMD3(sin(a), cos(a), 0), SIMD3(0, 0, 1)]) }
func angle(_ a: simd_double3x3, _ b: simd_double3x3) -> Double {
    let d = a * b.transpose
    return acos(max(-1, min(1, (d[0][0] + d[1][1] + d[2][2] - 1) / 2))) * 180 / .pi
}

var seed: UInt64 = 12345
func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }

// MARK: Photos

let W = 640, H = 480, F = 480.0                           // about 67 x 53 degrees, held in portrait
let cx = Double(W - 1) / 2, cy = Double(H - 1) / 2
var layout: [(yaw: Double, pitch: Double)] = []
for k in 0..<12 { layout.append((Double(k) * 30, 0)) }
for k in 0..<8 { layout.append((Double(k) * 45 + 22.5, 45)) }
for k in 0..<8 { layout.append((Double(k) * 45 + 22.5, -45)) }
layout.append((0, 89.9)); layout.append((0, -89.9))

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pano-test-\(getpid())")
try? FileManager.default.removeItem(at: folder)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func writePNG(_ pixels: [UInt8], _ w: Int, _ h: Int, _ url: URL) {
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    _ = CGImageDestinationFinalize(dest)
}

print("Rendering \(layout.count) photos…")
var truth: [simd_double3x3] = []
var shots: [PanoShot] = []
for (n, l) in layout.enumerated() {
    let R = rotY(-l.yaw * .pi / 180) * rotX(l.pitch * .pi / 180) * rotZ(-.pi / 2)
    truth.append(R)
    let gain = 0.92 + 0.16 * random()
    var px = [UInt8](repeating: 255, count: W * H * 4)
    for v in 0..<H {
        for u in 0..<W {
            var c = SIMD3<Double>(repeating: 0)
            for (du, dv) in [(-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)] {
                let k = SIMD3((Double(u) + du - cx) / F, -(Double(v) + dv - cy) / F, -1)
                c += scene(simd_normalize(R * k))
            }
            c = c / 4 * gain
            let p = (v * W + u) * 4
            px[p] = UInt8(max(0, min(255, c.x))); px[p + 1] = UInt8(max(0, min(255, c.y))); px[p + 2] = UInt8(max(0, min(255, c.z)))
        }
    }
    let name = String(format: "shot_%02d.png", n)
    writePNG(px, W, H, folder.appendingPathComponent(name))
    var s = PanoShot(file: name, width: W, height: H, fx: F, fy: F, cx: cx, cy: cy, rotation: [Double](repeating: 0, count: 9))
    s.matrix = R
    shots.append(s)
}

// Knock every direction but the first off by 0.5-1.2 degrees.
var off = shots
var initialError: [Double] = []
for k in 1..<off.count {
    var axis = SIMD3(random() - 0.5, random() - 0.5, random() - 0.5)
    axis = simd_normalize(axis)
    let w = axis * ((0.5 + 0.7 * random()) * .pi / 180)
    off[k].matrix = PanoramaStitcher.exp(w) * truth[k]
    initialError.append(angle(off[k].matrix, truth[k]))
}

// MARK: Stitch three ways and compare with the scene

let outW = 2048, outH = 1024
let forward = truth[0] * SIMD3<Double>(0, 0, -1)
let yaw0 = atan2(forward.x, -forward.z)

func pixels(_ img: CGImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return buf
}

/// Mean difference from the scene (0-255), away from the poles; and the share of pixels more than 40 out
/// (doubled edges show up there).
func compare(_ img: CGImage) -> (mean: Double, bad: Double) {
    let px = pixels(img)
    var total = 0.0, n = 0.0, bad = 0.0
    for y in stride(from: 0, to: outH, by: 2) {
        let lat = Double.pi / 2 - (Double(y) + 0.5) / Double(outH) * .pi
        guard abs(lat) < 75 * .pi / 180 else { continue }
        for x in stride(from: 0, to: outW, by: 2) {
            let lon = (Double(x) + 0.5) / Double(outW) * 2 * .pi - .pi + yaw0
            let s = scene(SIMD3(cos(lat) * sin(lon), sin(lat), -cos(lat) * cos(lon)))
            let p = (y * outW + x) * 4
            let e = (abs(Double(px[p]) - s.x) + abs(Double(px[p + 1]) - s.y) + abs(Double(px[p + 2]) - s.z)) / 3
            total += e; n += 1
            if e > 40 { bad += 1 }
        }
    }
    return (total / n, bad / n)
}

var options = PanoramaStitcher.Options()
options.width = outW

print("Stitching with the true directions…")
options.refine = false
let exact = try PanoramaStitcher.stitch(folder: folder, shots: shots, options: options)
let eExact = compare(exact.image)

print("Stitching with directions 0.5-1.2° off, no fine-tuning…")
let rough = try PanoramaStitcher.stitch(folder: folder, shots: off, options: options)
let eRough = compare(rough.image)

print("Stitching with directions 0.5-1.2° off, fine-tuned…")
options.refine = true
let tuned = try PanoramaStitcher.stitch(folder: folder, shots: off, options: options)
let eTuned = compare(tuned.image)
let tunedError = (1..<truth.count).map { angle(tuned.rotations[$0], truth[$0]) }

print("")
print(tuned.report.summary)
print("")
print(String(format: "direction error: %.2f° before, %.2f° after (worst %.2f°)",
             PanoramaStitcher.median(initialError), PanoramaStitcher.median(tunedError), tunedError.max() ?? 0))
print(String(format: "difference from the scene:  true directions %.1f (%.2f%% bad)   off %.1f (%.2f%% bad)   fine-tuned %.1f (%.2f%% bad)",
             eExact.mean, eExact.bad * 100, eRough.mean, eRough.bad * 100, eTuned.mean, eTuned.bad * 100))
print(String(format: "time for the fine-tuned stitch: %.1f s", tuned.report.seconds))
print("")

check(tuned.report.refinementKept, "fine-tuning was kept")
check(PanoramaStitcher.median(tunedError) < 0.35 * PanoramaStitcher.median(initialError), "fine-tuning removes most of the direction error")
check(eTuned.mean < eRough.mean * 0.8, "fine-tuned panorama is closer to the scene than the rough one")
check(eTuned.bad < eRough.bad * 0.5, "fine-tuning removes most doubled edges")
check(eTuned.mean < eExact.mean * 1.5 + 2, "fine-tuned panorama is nearly as good as with the true directions")
check(eExact.mean < 12, "with the true directions the panorama matches the scene")
check(tuned.report.uncoveredFraction < 0.02, "the whole sphere is covered")

// The saved file must carry the tags 360 viewers look for.
let jpeg = folder.appendingPathComponent("pano.jpg")
try PanoramaStitcher.writeJPEG(tuned.image, to: jpeg)
let source = CGImageSourceCreateWithURL(jpeg as CFURL, nil)!
let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
let projection = meta.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "GPano:ProjectionType" as CFString) as String? }
check(projection == "equirectangular", "saved JPEG is tagged as a 360 panorama")

try? FileManager.default.removeItem(at: folder)
if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("All panorama checks passed")
