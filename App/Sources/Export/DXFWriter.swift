import Foundation
import simd

/// Writes AutoCAD R12 ASCII DXF, which AutoCAD, Revit (Import CAD), BricsCAD and most CAD tools open.
final class DXFWriter {
    struct Layer { var name: String; var color: Int }

    private let out: TextFileWriter
    private let scale: Float

    init(url: URL, unit: CADUnit, layers: [Layer], extents: (SIMD3<Float>, SIMD3<Float>)) throws {
        out = try TextFileWriter(url: url)
        scale = unit.scale
        pair(0, "SECTION"); pair(2, "HEADER")
        pair(9, "$ACADVER"); pair(1, "AC1009")
        pair(9, "$INSUNITS"); pair(70, "\(unit.dxfCode)")
        pair(9, "$EXTMIN"); point(10, extents.0)
        pair(9, "$EXTMAX"); point(10, extents.1)
        pair(0, "ENDSEC")
        pair(0, "SECTION"); pair(2, "TABLES")
        pair(0, "TABLE"); pair(2, "LTYPE"); pair(70, "1")
        pair(0, "LTYPE"); pair(2, "CONTINUOUS"); pair(70, "0"); pair(3, "Solid line"); pair(72, "65"); pair(73, "0"); pair(40, "0.0")
        pair(0, "ENDTAB")
        pair(0, "TABLE"); pair(2, "LAYER"); pair(70, "\(layers.count)")
        for l in layers {
            pair(0, "LAYER"); pair(2, l.name); pair(70, "0"); pair(62, "\(l.color)"); pair(6, "CONTINUOUS")
        }
        pair(0, "ENDTAB")
        pair(0, "TABLE"); pair(2, "STYLE"); pair(70, "1")
        pair(0, "STYLE"); pair(2, "STANDARD"); pair(70, "0"); pair(40, "0.0"); pair(41, "1.0"); pair(50, "0.0"); pair(71, "0"); pair(42, "0.2"); pair(3, "txt"); pair(4, "")
        pair(0, "ENDTAB")
        pair(0, "ENDSEC")
        pair(0, "SECTION"); pair(2, "ENTITIES")
    }

    func finish() {
        pair(0, "ENDSEC"); pair(0, "EOF")
        out.close()
    }

    // MARK: Entities (all inputs in metres)

    func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, layer: String) {
        pair(0, "LINE"); pair(8, layer); point(10, a); point(11, b)
    }

    func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, z: Float = 0, layer: String) {
        line(SIMD3(a, z), SIMD3(b, z), layer: layer)
    }

    func polyline(_ pts: [SIMD2<Float>], closed: Bool, z: Float = 0, layer: String) {
        guard pts.count >= 2 else { return }
        pair(0, "POLYLINE"); pair(8, layer); pair(66, "1")
        pair(10, "0.0"); pair(20, "0.0"); pair(30, num(z * scale))
        pair(70, closed ? "1" : "0")
        for p in pts {
            pair(0, "VERTEX"); pair(8, layer); point(10, SIMD3(p, z))
        }
        pair(0, "SEQEND"); pair(8, layer)
    }

    /// Counter-clockwise arc; angles in degrees.
    func arc(center: SIMD2<Float>, radius: Float, from: Float, to: Float, layer: String) {
        pair(0, "ARC"); pair(8, layer); point(10, SIMD3(center, 0))
        pair(40, num(radius * scale)); pair(50, num(from, 100)); pair(51, num(to, 100))
    }

    func circle(center: SIMD2<Float>, radius: Float, layer: String) {
        pair(0, "CIRCLE"); pair(8, layer); point(10, SIMD3(center, 0)); pair(40, num(radius * scale))
    }

    /// Text centred on `at`. Height in metres, rotation in degrees.
    func text(_ s: String, at p: SIMD2<Float>, height: Float, rotation: Float = 0, layer: String) {
        let clean = s.unicodeScalars.map { $0.isASCII ? String($0) : ($0 == "²" ? "2" : "?") }.joined()
        pair(0, "TEXT"); pair(8, layer); point(10, SIMD3(p, 0))
        pair(40, num(height * scale)); pair(1, clean)
        if rotation != 0 { pair(50, num(rotation, 100)) }
        pair(72, "4"); point(11, SIMD3(p, 0))
    }

    func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>? = nil, layer: String) {
        pair(0, "3DFACE"); pair(8, layer)
        point(10, a); point(11, b); point(12, c); point(13, d ?? c)
    }

    // MARK: Low level

    private func pair(_ code: Int, _ value: String) {
        out.write(code < 10 ? "  \(code)\n" : (code < 100 ? " \(code)\n" : "\(code)\n"))
        out.write(value); out.write("\n")
    }

    /// Writes a point with group codes base, base+10, base+20 (e.g. 10/20/30).
    private func point(_ base: Int, _ p: SIMD3<Float>) {
        pair(base, num(p.x * scale)); pair(base + 10, num(p.y * scale)); pair(base + 20, num(p.z * scale))
    }
}

// MARK: - Floor plans

enum DXFExport {
    static let planLayers: [DXFWriter.Layer] = [
        .init(name: "A-WALL", color: 7), .init(name: "A-DOOR", color: 30), .init(name: "A-GLAZ", color: 4),
        .init(name: "A-OPEN", color: 8), .init(name: "A-FURN", color: 3), .init(name: "A-FLOR", color: 9),
        .init(name: "A-ANNO-DIMS", color: 2), .init(name: "A-ANNO-TEXT", color: 7),
    ]

    /// 2D architectural floor plan: walls with door/window gaps, door swings, windows, furniture, dimensions and labels.
    static func floorPlan(_ plan: PlanModel, to url: URL, unit: CADUnit, units: UnitSystem) throws {
        let b = plan.bounds
        let dxf = try DXFWriter(url: url, unit: unit, layers: planLayers,
                                extents: (SIMD3(b.min, 0), SIMD3(b.max, plan.ceilingHeight)))
        let textH: Float = 0.12

        for floor in plan.floors { dxf.polyline(floor, closed: true, layer: "A-FLOR") }

        for wall in plan.walls {
            let t = max(wall.size.y, plan.wallThickness)
            let n = wall.normal * t / 2
            // Solid wall pieces between the gaps.
            for (s, e) in plan.solidSpans(of: wall) {
                let a = wall.center2D + wall.axis * s, c = wall.center2D + wall.axis * e
                dxf.polyline([a - n, c - n, c + n, a + n], closed: true, layer: "A-WALL")
            }
            // Doors, windows and openings in this wall.
            for g in plan.gaps(in: wall) {
                let a = wall.center2D + wall.axis * g.from, c = wall.center2D + wall.axis * g.to
                let w = g.to - g.from
                switch g.element.kind {
                case .door:
                    let hinge = a + n
                    let leafEnd = hinge + wall.normal * w
                    dxf.line(hinge, leafEnd, layer: "A-DOOR")
                    let yawDeg = wall.yaw * 180 / .pi
                    dxf.arc(center: hinge, radius: w, from: yawDeg, to: yawDeg + 90, layer: "A-DOOR")
                    dxf.line(a - n, a + n, layer: "A-DOOR"); dxf.line(c - n, c + n, layer: "A-DOOR")
                case .window:
                    dxf.polyline([a - n, c - n, c + n, a + n], closed: true, layer: "A-GLAZ")
                    dxf.line(a, c, layer: "A-GLAZ")
                default:
                    dxf.line(a - n, a + n, layer: "A-OPEN"); dxf.line(c - n, c + n, layer: "A-OPEN")
                }
            }
            // Dimension: a line with ticks outside the wall and the length above it.
            let off = wall.normal * (t / 2 + 0.3)
            let p0 = wall.start + off, p1 = wall.end + off
            dxf.line(p0, p1, layer: "A-ANNO-DIMS")
            for p in [p0, p1] { dxf.line(p - wall.normal * 0.08, p + wall.normal * 0.08, layer: "A-ANNO-DIMS") }
            var rot = wall.yaw * 180 / .pi
            rot = rot.truncatingRemainder(dividingBy: 360); if rot < 0 { rot += 360 }
            if rot > 90 && rot <= 270 { rot -= 180 }
            dxf.text(units.length(wall.size.x), at: (p0 + p1) / 2 + wall.normal * 0.12, height: textH, rotation: rot, layer: "A-ANNO-DIMS")
        }

        for obj in plan.objects {
            dxf.polyline(obj.footprint, closed: true, layer: "A-FURN")
            dxf.text(obj.label.capitalized, at: obj.center2D, height: textH * 0.8, layer: "A-FURN")
        }

        for l in plan.labels { dxf.text(l.text, at: l.position, height: textH * 1.6, layer: "A-ANNO-TEXT") }
        for outline in plan.outlines where plan.labels.isEmpty {
            dxf.text("Area " + units.area(abs(Geometry.polygonArea(outline))), at: Geometry.centroid(outline) - SIMD2(0, 0.3),
                     height: textH * 1.2, layer: "A-ANNO-TEXT")
        }
        dxf.finish()
    }

    /// 3D DXF made of 3DFACEs, one layer per part (e.g. walls, floor, furniture).
    static func mesh(parts: [(String, MeshData)], to url: URL, unit: CADUnit, floor: Float) throws {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for (_, m) in parts where !m.positions.isEmpty {
            let b = m.bounds
            for p in [b.min, b.max] { let q = MeshData.toCAD(p, floor: floor); lo = simd_min(lo, q); hi = simd_max(hi, q) }
        }
        if lo.x > hi.x { lo = .zero; hi = .zero }
        let palette = [7, 9, 3, 30, 4, 5, 6, 1, 2, 8]
        let layers = parts.enumerated().map { DXFWriter.Layer(name: layerName($1.0), color: palette[$0 % palette.count]) }
        let dxf = try DXFWriter(url: url, unit: unit, layers: layers, extents: (SIMD3(min(lo.x, hi.x), min(lo.y, hi.y), min(lo.z, hi.z)), hi))
        for (name, m) in parts {
            let layer = layerName(name)
            for t in 0..<m.triangleCount {
                let a = MeshData.toCAD(m.positions[Int(m.indices[3 * t])], floor: floor)
                let b = MeshData.toCAD(m.positions[Int(m.indices[3 * t + 1])], floor: floor)
                let c = MeshData.toCAD(m.positions[Int(m.indices[3 * t + 2])], floor: floor)
                dxf.face(a, b, c, layer: layer)
            }
        }
        dxf.finish()
    }

    /// Plan section of a mesh (e.g. at 1.2 m) as lines, for drafting over in AutoCAD.
    static func section(_ segments: [(SIMD2<Float>, SIMD2<Float>)], floorOutline: [(SIMD2<Float>, SIMD2<Float>)] = [],
                        to url: URL, unit: CADUnit) throws {
        let pts = segments.flatMap { [$0.0, $0.1] }
        let b = Geometry.bounds(pts)
        let dxf = try DXFWriter(url: url, unit: unit,
                                layers: [.init(name: "SCAN-SECTION", color: 7), .init(name: "SCAN-FLOOR", color: 8)],
                                extents: (SIMD3(b.min, 0), SIMD3(b.max, 0)))
        for (a, c) in segments { dxf.line(a, c, layer: "SCAN-SECTION") }
        for (a, c) in floorOutline { dxf.line(a, c, layer: "SCAN-FLOOR") }
        dxf.finish()
    }

    static func layerName(_ s: String) -> String {
        let up = s.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "SCAN-" + String(up)
    }
}
