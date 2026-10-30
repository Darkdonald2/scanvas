import Foundation
import simd

/// A CAD-friendly description of a scanned room, independent of RoomPlan.
///
/// Plan coordinates: X to the right, Y forward, Z up, in metres, with the floor at Z = 0.
/// (ARKit world → plan is `(x, -z, y - floorY)`.)
struct PlanElement: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case wall, door, window, opening, object }

    var id: UUID
    var parentID: UUID?
    var kind: Kind
    var label: String
    /// Centre of the box in plan coordinates.
    var center: SIMD3<Float>
    /// Rotation of the box's local X axis around Z, in radians.
    var yaw: Float
    /// Width (local X), depth (local Y), height (Z).
    var size: SIMD3<Float>
    var isOpen = false

    var axis: SIMD2<Float> { SIMD2(cos(yaw), sin(yaw)) }
    var normal: SIMD2<Float> { SIMD2(-sin(yaw), cos(yaw)) }
    var center2D: SIMD2<Float> { SIMD2(center.x, center.y) }
    var bottom: Float { center.z - size.z / 2 }
    var top: Float { center.z + size.z / 2 }

    /// Start and end points of the centre line along local X.
    var start: SIMD2<Float> { center2D - axis * size.x / 2 }
    var end: SIMD2<Float> { center2D + axis * size.x / 2 }

    /// Four corners of the footprint, counter-clockwise.
    var footprint: [SIMD2<Float>] {
        let a = axis * size.x / 2, n = normal * size.y / 2
        let c = center2D
        return [c - a - n, c + a - n, c + a + n, c - a + n]
    }
}

struct PlanLabel: Codable, Hashable {
    var text: String
    var position: SIMD2<Float>
}

struct PlanModel: Codable {
    var elements: [PlanElement] = []
    var floors: [[SIMD2<Float>]] = []
    var labels: [PlanLabel] = []
    var wallThickness: Float = 0.12

    var walls: [PlanElement] { elements.filter { $0.kind == .wall } }
    var doors: [PlanElement] { elements.filter { $0.kind == .door } }
    var windows: [PlanElement] { elements.filter { $0.kind == .window } }
    var openings: [PlanElement] { elements.filter { $0.kind == .opening } }
    var objects: [PlanElement] { elements.filter { $0.kind == .object } }

    var floorArea: Float { floors.reduce(0) { $0 + abs(Geometry.polygonArea($1)) } }

    var wallLength: Float { walls.reduce(0) { $0 + $1.size.x } }

    var ceilingHeight: Float { walls.map { $0.top }.max() ?? 0 }

    /// Floor outlines, or the hull of the walls when RoomPlan gave no floor.
    var outlines: [[SIMD2<Float>]] {
        if !floors.isEmpty { return floors }
        let pts = walls.flatMap { [$0.start, $0.end] }
        return pts.count >= 3 ? [Geometry.convexHull(pts)] : []
    }

    var bounds: (min: SIMD2<Float>, max: SIMD2<Float>) {
        var pts = elements.flatMap { $0.footprint } + floors.flatMap { $0 }
        if pts.isEmpty { pts = [.zero] }
        return Geometry.bounds(pts)
    }

    var summary: String {
        var parts = ["\(walls.count) walls"]
        if !doors.isEmpty { parts.append("\(doors.count) doors") }
        if !windows.isEmpty { parts.append("\(windows.count) windows") }
        if !objects.isEmpty { parts.append("\(objects.count) objects") }
        return parts.joined(separator: " · ")
    }

    /// Gaps cut into a wall by its doors, windows and openings, in the wall's local X (−L/2…L/2).
    struct Gap { var from: Float; var to: Float; var bottom: Float; var top: Float; var element: PlanElement }

    func gaps(in wall: PlanElement) -> [Gap] {
        let L = wall.size.x
        var result: [Gap] = []
        for e in elements where e.kind == .door || e.kind == .window || e.kind == .opening {
            if let p = e.parentID, p != wall.id { continue }
            let d = e.center2D - wall.center2D
            let along = simd_dot(d, wall.axis)
            if e.parentID == nil {
                // No parent from RoomPlan: accept it if it sits on this wall's line.
                let across = abs(simd_dot(d, wall.normal))
                let parallel = abs(simd_dot(e.axis, wall.axis))
                if across > 0.25 || parallel < 0.9 || abs(along) > L / 2 + 0.05 { continue }
            }
            let from = max(-L / 2, along - e.size.x / 2)
            let to = min(L / 2, along + e.size.x / 2)
            if to - from > 0.02 {
                result.append(Gap(from: from, to: to, bottom: max(0, e.bottom - wall.bottom),
                                  top: min(wall.size.z, e.top - wall.bottom), element: e))
            }
        }
        return result.sorted { $0.from < $1.from }
    }

    /// The solid pieces of a wall left after cutting its gaps: (from, to) along local X.
    func solidSpans(of wall: PlanElement) -> [(Float, Float)] {
        let L = wall.size.x
        var spans: [(Float, Float)] = []
        var cursor = -L / 2
        for g in gaps(in: wall) {
            if g.from > cursor + 0.005 { spans.append((cursor, g.from)) }
            cursor = max(cursor, g.to)
        }
        if L / 2 > cursor + 0.005 { spans.append((cursor, L / 2)) }
        return spans
    }
}

enum Geometry {
    static func polygonArea(_ p: [SIMD2<Float>]) -> Float {
        guard p.count >= 3 else { return 0 }
        var a: Float = 0
        for i in 0..<p.count {
            let j = (i + 1) % p.count
            a += p[i].x * p[j].y - p[j].x * p[i].y
        }
        return a / 2
    }

    static func centroid(_ p: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !p.isEmpty else { return .zero }
        return p.reduce(.zero, +) / Float(p.count)
    }

    static func bounds(_ p: [SIMD2<Float>]) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for q in p { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        if p.isEmpty { return (.zero, .zero) }
        return (lo, hi)
    }

    static func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count >= 3 else { return p }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
