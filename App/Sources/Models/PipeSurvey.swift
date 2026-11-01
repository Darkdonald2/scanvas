import Foundation
import CoreGraphics
import simd

/// A drainage survey: one or more pipe runs traced point by point, with photos.
/// Positions are ARKit world coordinates (metres, Y up). Each run is ordered in the direction of flow.
struct PipeSurvey: Codable {
    var runs: [PipeRun] = []
    var photos: [PipePhoto] = []
    /// ARKit Y of the floor, for heights above/below floor.
    var floorY: Float = 0
    /// True once the floor was measured (tapped or detected) rather than guessed.
    var floorMeasured = false
    /// ARKit Y of the ceiling/soffit, when detected.
    var ceilingY: Float?
    /// Minimum acceptable fall in percent (1% ≈ 1:100).
    var minFall: Float = 1.0
    /// Places the survey in the coordinates of an existing drawing.
    var alignment = DrawingAlignment()

    var totalLength: Float { runs.reduce(0) { $0 + $1.length } }
    var allPoints: [PipePoint] { runs.flatMap { $0.points } }

    var summary: String {
        let n = runs.filter { $0.points.count > 1 }.count
        return "\(n) run\(n == 1 ? "" : "s") · " + UnitSystem.current.length(totalLength)
    }
}

struct PipeRun: Codable, Identifiable {
    var id = UUID()
    var name: String
    /// Drainage system tag, e.g. WP, SP, RWP. Used for DXF layers and colours.
    var system: String = "WP"
    /// Outside diameter in metres.
    var diameter: Float
    var points: [PipePoint] = []

    var segments: [PipeSegment] {
        zip(points, points.dropFirst()).map { PipeSegment(from: $0.0, to: $0.1) }
    }
    var length: Float { segments.reduce(0) { $0 + $1.length } }
    var drop: Float { (points.first?.position.y ?? 0) - (points.last?.position.y ?? 0) }
    /// Average fall over the whole run, percent.
    var averageFall: Float {
        let plan = segments.reduce(0) { $0 + $1.planLength }
        return plan > 0 ? drop / plan * 100 : 0
    }
    /// Distance along the run to each point.
    var chainages: [Float] {
        var c: [Float] = [0]
        for s in segments { c.append(c.last! + s.length) }
        return Array(c.prefix(points.count))
    }
    /// Worst segment status along the run.
    func status(minFall: Float) -> PipeSegment.Status {
        let all = segments.map { $0.status(minFall: minFall) }
        if all.contains(.backfall) { return .backfall }
        if all.contains(.flat) { return .flat }
        return .good
    }
}

/// Common drainage systems, each with a colour (RGB 0…1) and a DXF colour index.
enum PipeSystem {
    static let presets: [(code: String, name: String)] = [
        ("WP", "Waste pipe"), ("SP", "Soil pipe"), ("RWP", "Rainwater pipe"), ("FD", "Floor drain line"),
        ("CD", "Condensate drain"), ("VP", "Vent pipe"), ("SW", "Storm water"), ("FW", "Foul water"),
    ]

    static func color(_ code: String) -> SIMD3<Float> {
        switch code.uppercased() {
        case "WP": return SIMD3(0.20, 0.60, 1.00)
        case "SP": return SIMD3(0.75, 0.45, 0.20)
        case "RWP", "SW": return SIMD3(0.10, 0.80, 0.70)
        case "FD": return SIMD3(0.55, 0.40, 0.95)
        case "CD": return SIMD3(0.95, 0.85, 0.20)
        case "VP": return SIMD3(0.60, 0.60, 0.60)
        case "FW": return SIMD3(0.85, 0.35, 0.55)
        default:
            // Stable colour for custom codes.
            var h: UInt32 = 2166136261
            for b in code.uppercased().utf8 { h = (h ^ UInt32(b)) &* 16777619 }
            let hue = Float(h % 360) / 360
            return hsv(hue, 0.65, 0.95)
        }
    }

    static func dxfColor(_ code: String) -> Int {
        switch code.uppercased() {
        case "WP": return 5
        case "SP": return 30
        case "RWP", "SW": return 4
        case "FD": return 6
        case "CD": return 2
        case "VP": return 8
        case "FW": return 220
        default: return 3
        }
    }

    private static func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let i = Int(h * 6) % 6, f = h * 6 - Float(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}

/// Maps scan coordinates onto an existing drawing: up to two reference points with known drawing X/Y,
/// plus the level of the floor. Drawing units are metres; doubles keep millimetres exact at large coordinates.
struct DrawingAlignment: Codable {
    struct Reference: Codable, Identifiable {
        var id = UUID()
        /// The survey point used as reference.
        var point: UUID
        var x: Double
        var y: Double
    }
    var references: [Reference] = []
    /// Extra rotation in degrees (counter-clockwise), used when there are fewer than two references.
    var rotation: Double = 0
    /// Level of the floor in the drawing (e.g. FFL), metres.
    var floorLevel: Double = 0

    var isAligned: Bool { !references.isEmpty }

    /// Plan coordinates of a world point before alignment: X right, Y forward (as in the CAD exports).
    static func plan(_ p: SIMD3<Float>) -> SIMD2<Double> { SIMD2(Double(p.x), Double(-p.z)) }

    /// Rotation (radians) and translation that take plan coordinates to drawing coordinates.
    func transform(in survey: PipeSurvey) -> (angle: Double, offset: SIMD2<Double>) {
        let pts = survey.allPoints
        let refs: [(SIMD2<Double>, SIMD2<Double>)] = references.compactMap { r in
            guard let p = pts.first(where: { $0.id == r.point }) else { return nil }
            return (Self.plan(p.position), SIMD2(r.x, r.y))
        }
        var angle = rotation * .pi / 180
        if refs.count >= 2 {
            let a = refs[1].0 - refs[0].0, b = refs[1].1 - refs[0].1
            if simd_length(a) > 0.05 && simd_length(b) > 0.05 {
                angle = atan2(b.y, b.x) - atan2(a.y, a.x)
            }
        }
        guard let first = refs.first else { return (angle, .zero) }
        return (angle, first.1 - rotate(first.0, angle))
    }

    /// How far the second reference's measured distance differs from the drawing (metres), a check on accuracy.
    func mismatch(in survey: PipeSurvey) -> Double? {
        let pts = survey.allPoints
        guard references.count >= 2,
              let p0 = pts.first(where: { $0.id == references[0].point }),
              let p1 = pts.first(where: { $0.id == references[1].point }) else { return nil }
        let measured = simd_length(Self.plan(p1.position) - Self.plan(p0.position))
        let drawn = simd_length(SIMD2(references[1].x - references[0].x, references[1].y - references[0].y))
        return measured - drawn
    }

    private func rotate(_ p: SIMD2<Double>, _ a: Double) -> SIMD2<Double> {
        SIMD2(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a))
    }

    /// A function from world points to drawing (X, Y, level).
    func mapper(for survey: PipeSurvey) -> (SIMD3<Float>) -> SIMD3<Double> {
        let (a, t) = transform(in: survey)
        let floorY = Double(survey.floorY), level = floorLevel
        let c = cos(a), s = sin(a)
        return { p in
            let q = Self.plan(p)
            return SIMD3(q.x * c - q.y * s + t.x, q.x * s + q.y * c + t.y, Double(p.y) - floorY + level)
        }
    }

    /// Rotation in radians applied to plan directions (for bearings and arrows).
    func angle(for survey: PipeSurvey) -> Double { transform(in: survey).angle }
}

struct PipePoint: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case point, bend45, bend90, wye, tee, cleanout, riser, drop, floorDrain, gully, trap, manhole, outlet, reducer

        var title: String {
            switch self {
            case .point: return "Point"
            case .bend45: return "45° bend"
            case .bend90: return "90° bend"
            case .wye: return "45° Y junction"
            case .tee: return "Tee"
            case .cleanout: return "Cleanout"
            case .riser: return "Riser / stack"
            case .drop: return "Drop / opening"
            case .floorDrain: return "Floor drain"
            case .gully: return "Gully"
            case .trap: return "Trap"
            case .manhole: return "Manhole"
            case .outlet: return "Outlet"
            case .reducer: return "Reducer"
            }
        }

        var symbol: String {
            switch self {
            case .point: return "circle.fill"
            case .bend45: return "arrow.turn.right.down"
            case .bend90: return "arrow.turn.down.right"
            case .wye: return "arrow.triangle.merge"
            case .tee: return "t.square"
            case .cleanout: return "plus.circle"
            case .riser: return "arrow.up.and.down.circle"
            case .drop: return "arrow.down.circle"
            case .floorDrain: return "square.grid.3x3.square"
            case .gully: return "drop.circle"
            case .trap: return "u.circle"
            case .manhole: return "circle.circle"
            case .outlet: return "arrow.down.right.circle"
            case .reducer: return "chevron.right.2"
            }
        }

        /// Short code used in drawings and DXF.
        var code: String {
            switch self {
            case .point: return ""
            case .bend45: return "B45"
            case .bend90: return "B90"
            case .wye: return "Y"
            case .tee: return "T"
            case .cleanout: return "CO"
            case .riser: return "R"
            case .drop: return "D"
            case .floorDrain: return "FD"
            case .gully: return "G"
            case .trap: return "TR"
            case .manhole: return "MH"
            case .outlet: return "OUT"
            case .reducer: return "RED"
            }
        }
    }

    var id = UUID()
    /// Pipe centre line.
    var position: SIMD3<Float>
    var kind: Kind = .point
    var label: String = ""
}

struct PipeSegment {
    var from: PipePoint
    var to: PipePoint

    var vector: SIMD3<Float> { to.position - from.position }
    var length: Float { simd_length(vector) }
    var planLength: Float { simd_length(SIMD2(vector.x, vector.z)) }
    /// Height lost along the segment (positive = falling in the flow direction).
    var drop: Float { from.position.y - to.position.y }
    /// Fall in percent of horizontal length (positive = falls in flow direction).
    var fallPercent: Float { planLength > 0.01 ? drop / planLength * 100 : 0 }
    /// Gradient as 1:X (nil when flat or rising).
    var gradient: Float? { drop > 0.0005 ? planLength / drop : nil }
    /// Compass-style bearing in the plan, degrees clockwise from the scan's forward direction.
    var bearing: Float {
        var b = atan2(vector.x, -vector.z) * 180 / .pi
        if b < 0 { b += 360 }
        return b
    }
    var isVertical: Bool { planLength < 0.05 && abs(drop) > 0.05 }

    enum Status { case good, flat, backfall, vertical }
    func status(minFall: Float) -> Status {
        if isVertical { return .vertical }
        if fallPercent < -0.1 { return .backfall }
        if fallPercent < minFall { return .flat }
        return .good
    }
}

/// A high-resolution photo with the camera that took it, so pipe lines can be drawn onto it.
struct PipePhoto: Codable {
    var file: String
    var worldToCamera: simd_float4x4
    var fx: Float, fy: Float, cx: Float, cy: Float
    /// Sensor image size (the intrinsics refer to this).
    var sensorWidth: Int, sensorHeight: Int
    /// Clockwise rotation (0, 90, 180, 270) applied when the JPEG was saved, so it shows upright.
    var rotation: Int = 90
    var caption: String = ""
    /// The point the camera was aimed at, if any.
    var target: SIMD3<Float>?
    /// The survey point this photo belongs to.
    var point: UUID?

    /// Size of the saved (rotated) image.
    var width: Int { rotation % 180 == 0 ? sensorWidth : sensorHeight }
    var height: Int { rotation % 180 == 0 ? sensorHeight : sensorWidth }

    /// Camera-space position (x right, y up, z forward) of a world point.
    func camera(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = worldToCamera * SIMD4(p, 1)
        return SIMD3(q.x, q.y, -q.z)
    }

    /// Pixel in the saved image for a camera-space point in front of the camera.
    func pixel(camera c: SIMD3<Float>) -> CGPoint {
        let u = CGFloat(fx * c.x / c.z + cx), v = CGFloat(cy - fy * c.y / c.z)
        let w = CGFloat(sensorWidth), h = CGFloat(sensorHeight)
        switch rotation {
        case 90: return CGPoint(x: h - v, y: u)
        case 180: return CGPoint(x: w - u, y: h - v)
        case 270: return CGPoint(x: v, y: w - u)
        default: return CGPoint(x: u, y: v)
        }
    }

    /// Image pixel of a world point, or nil when it is behind the camera.
    func project(_ p: SIMD3<Float>) -> CGPoint? {
        let c = camera(p)
        guard c.z > 0.05 else { return nil }
        return pixel(camera: c)
    }

    /// A world segment clipped to what is in front of the camera, in image pixels.
    func project(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (CGPoint, CGPoint)? {
        var ca = camera(a), cb = camera(b)
        let near: Float = 0.05
        if ca.z < near && cb.z < near { return nil }
        if ca.z < near { ca = ca + (cb - ca) * ((near - ca.z) / (cb.z - ca.z)) }
        if cb.z < near { cb = cb + (ca - cb) * ((near - cb.z) / (ca.z - cb.z)) }
        return (pixel(camera: ca), pixel(camera: cb))
    }
}

extension simd_float4x4: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.init(try c.decode(SIMD4<Float>.self), try c.decode(SIMD4<Float>.self), try c.decode(SIMD4<Float>.self), try c.decode(SIMD4<Float>.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(columns.0); try c.encode(columns.1); try c.encode(columns.2); try c.encode(columns.3)
    }
}

enum PipeSize {
    static let metric: [(String, Float)] = [("40 mm", 0.040), ("50 mm", 0.050), ("75 mm", 0.075), ("100 mm", 0.100),
                                            ("110 mm", 0.110), ("125 mm", 0.125), ("160 mm", 0.160), ("200 mm", 0.200)]
    static let imperial: [(String, Float)] = [("1½″", 0.048), ("2″", 0.060), ("3″", 0.089), ("4″", 0.114), ("6″", 0.168), ("8″", 0.219)]
}

extension UnitSystem {
    func fall(_ percent: Float) -> String { String(format: "%.1f%%", percent) }
    func gradient(_ g: Float?) -> String { g.map { String(format: "1:%.0f", $0) } ?? "–" }
    func level(_ metres: Double) -> String {
        self == .metric ? String(format: "%+.3f", metres) : String(format: "%+.2f ft", metres * 3.28084)
    }
    func diameter(_ metres: Float) -> String {
        self == .metric ? String(format: "Ø%.0f mm", metres * 1000) : String(format: "Ø%.1f″", metres / 0.0254)
    }
}
