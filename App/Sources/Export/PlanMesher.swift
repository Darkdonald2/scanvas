import Foundation
import simd

/// Turns a room plan into 3D meshes (walls with door/window holes, floor, doors, windows, furniture)
/// in ARKit-style coordinates (Y up, floor at 0), so rooms can use every mesh format.
enum PlanMesher {
    static let wallColor = SIMD3<UInt8>(232, 228, 220), floorColor = SIMD3<UInt8>(168, 128, 92)
    static let doorColor = SIMD3<UInt8>(140, 90, 60), glassColor = SIMD3<UInt8>(140, 200, 235)

    static func parts(_ plan: PlanModel) -> [(String, MeshData)] {
        var walls = MeshData(), floor = MeshData(), doors = MeshData(), windows = MeshData(), furniture = MeshData()
        for wall in plan.walls {
            let w = wallParts(wall, plan: plan)
            walls.append(w.wall); doors.append(w.doors); windows.append(w.windows)
        }
        floor = floorMesh(plan)
        for obj in plan.objects { furniture.append(objectMesh(obj)) }
        return [("Walls", walls), ("Floor", floor), ("Doors", doors), ("Windows", windows), ("Furniture", furniture)]
            .filter { !$0.1.isEmpty }
    }

    /// One wall with its door/window holes, plus the doors and windows that sit in it.
    static func wallParts(_ wall: PlanElement, plan: PlanModel) -> (wall: MeshData, doors: MeshData, windows: MeshData) {
        var walls = MeshData(), doors = MeshData(), windows = MeshData()
        let t = max(wall.size.y, plan.wallThickness)
        let H = wall.size.z
        func piece(_ from: Float, _ to: Float, _ z0: Float, _ z1: Float) {
            guard to - from > 0.001, z1 - z0 > 0.001 else { return }
            let c = wall.center2D + wall.axis * ((from + to) / 2)
            walls.append(box(center: SIMD3(c, wall.bottom + (z0 + z1) / 2), yaw: wall.yaw,
                             size: SIMD3(to - from, t, z1 - z0), color: wallColor))
        }
        for (s, e) in plan.solidSpans(of: wall) { piece(s, e, 0, H) }
        for g in plan.gaps(in: wall) {
            piece(g.from, g.to, 0, g.bottom)          // sill
            piece(g.from, g.to, g.top, H)             // lintel
            let w = g.to - g.from, h = g.top - g.bottom
            let c = wall.center2D + wall.axis * ((g.from + g.to) / 2)
            let center = SIMD3(c, wall.bottom + (g.bottom + g.top) / 2)
            switch g.element.kind {
            case .door: doors.append(box(center: center, yaw: wall.yaw, size: SIMD3(w, 0.04, h), color: doorColor))
            case .window: windows.append(box(center: center, yaw: wall.yaw, size: SIMD3(w, 0.02, h), color: glassColor))
            default: break
            }
        }
        return (walls, doors, windows)
    }

    static func floorMesh(_ plan: PlanModel) -> MeshData {
        var floor = MeshData()
        for outline in plan.outlines where outline.count >= 3 {
            floor.append(prism(outline, bottom: -0.02, top: 0, color: floorColor))
        }
        return floor
    }

    static func objectMesh(_ obj: PlanElement) -> MeshData {
        box(center: obj.center, yaw: obj.yaw, size: obj.size, color: color(for: obj.label))
    }

    static func combined(_ plan: PlanModel) -> MeshData {
        parts(plan).reduce(into: MeshData()) { $0.append($1.1) }
    }

    /// Plan (X, Y, Z-up) → world (X, Y-up, Z).
    @inline(__always) static func world(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, p.z, -p.y) }

    /// A box with flat-shaded faces (24 vertices) so normals stay crisp.
    static func box(center: SIMD3<Float>, yaw: Float, size: SIMD3<Float>, color: SIMD3<UInt8>) -> MeshData {
        let ax = SIMD3<Float>(cos(yaw), sin(yaw), 0), ay = SIMD3<Float>(-sin(yaw), cos(yaw), 0), az = SIMD3<Float>(0, 0, 1)
        let h = size / 2
        func corner(_ sx: Float, _ sy: Float, _ sz: Float) -> SIMD3<Float> {
            center + ax * (sx * h.x) + ay * (sy * h.y) + az * (sz * h.z)
        }
        // Each face: normal and four corners (counter-clockwise seen from outside).
        let faces: [(SIMD3<Float>, [SIMD3<Float>])] = [
            (ax, [corner(1, -1, -1), corner(1, 1, -1), corner(1, 1, 1), corner(1, -1, 1)]),
            (-ax, [corner(-1, 1, -1), corner(-1, -1, -1), corner(-1, -1, 1), corner(-1, 1, 1)]),
            (ay, [corner(1, 1, -1), corner(-1, 1, -1), corner(-1, 1, 1), corner(1, 1, 1)]),
            (-ay, [corner(-1, -1, -1), corner(1, -1, -1), corner(1, -1, 1), corner(-1, -1, 1)]),
            (az, [corner(-1, -1, 1), corner(1, -1, 1), corner(1, 1, 1), corner(-1, 1, 1)]),
            (-az, [corner(-1, 1, -1), corner(1, 1, -1), corner(1, -1, -1), corner(-1, -1, -1)]),
        ]
        var m = MeshData()
        for (n, q) in faces {
            let base = UInt32(m.positions.count)
            for p in q { m.positions.append(world(p)); m.normals.append(world(n)); m.colors.append(color) }
            m.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return m
    }

    /// An extruded polygon (fan-triangulated top and bottom; fine for the convex-ish floors RoomPlan returns).
    static func prism(_ polygon: [SIMD2<Float>], bottom: Float, top: Float, color: SIMD3<UInt8>) -> MeshData {
        let poly = Geometry.polygonArea(polygon) >= 0 ? polygon : Array(polygon.reversed())
        var m = MeshData()
        let n = poly.count
        func add(_ p: SIMD3<Float>, _ normal: SIMD3<Float>) -> UInt32 {
            m.positions.append(world(p)); m.normals.append(world(normal)); m.colors.append(color)
            return UInt32(m.positions.count - 1)
        }
        let topIdx = poly.map { add(SIMD3($0, top), SIMD3(0, 0, 1)) }
        let botIdx = poly.map { add(SIMD3($0, bottom), SIMD3(0, 0, -1)) }
        for i in 1..<(n - 1) {
            m.indices += [topIdx[0], topIdx[i], topIdx[i + 1]]
            m.indices += [botIdx[0], botIdx[i + 1], botIdx[i]]
        }
        for i in 0..<n {
            let a = poly[i], b = poly[(i + 1) % n]
            let e = b - a
            let normal = simd_length(e) > 0 ? SIMD3(simd_normalize(SIMD2(e.y, -e.x)), 0) : SIMD3<Float>(0, 0, 1)
            let i0 = add(SIMD3(a, bottom), normal), i1 = add(SIMD3(b, bottom), normal)
            let i2 = add(SIMD3(b, top), normal), i3 = add(SIMD3(a, top), normal)
            m.indices += [i0, i1, i2, i0, i2, i3]
        }
        return m
    }

    static func color(for label: String) -> SIMD3<UInt8> {
        switch label.lowercased() {
        case "bed": return SIMD3(120, 150, 220)
        case "sofa", "chair": return SIMD3(230, 140, 60)
        case "table": return SIMD3(170, 120, 80)
        case "storage": return SIMD3(200, 180, 140)
        case "refrigerator", "stove", "oven", "dishwasher", "washer dryer": return SIMD3(210, 215, 220)
        case "sink", "toilet", "bathtub": return SIMD3(245, 245, 250)
        case "television": return SIMD3(40, 40, 45)
        case "fireplace": return SIMD3(160, 70, 50)
        case "stairs": return SIMD3(150, 150, 150)
        default: return SIMD3(120, 200, 140)
        }
    }
}
