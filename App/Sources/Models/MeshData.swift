import Foundation
import simd

/// A triangle mesh in ARKit world coordinates (metres, Y up).
struct MeshData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// Optional per-vertex RGB colours (same count as positions, or empty).
    var colors: [SIMD3<UInt8>] = []
    var indices: [UInt32] = []
    /// Optional per-face ARKit classification (same count as triangles, or empty).
    var faceClasses: [UInt8] = []

    var vertexCount: Int { positions.count }
    var triangleCount: Int { indices.count / 3 }
    var hasColors: Bool { !colors.isEmpty && colors.count == positions.count }
    var hasNormals: Bool { !normals.isEmpty && normals.count == positions.count }
    var isEmpty: Bool { indices.isEmpty }

    mutating func append(_ other: MeshData) {
        let base = UInt32(positions.count)
        let keepColors = (positions.isEmpty || hasColors) && other.hasColors
        let keepClasses = (indices.isEmpty || !faceClasses.isEmpty) && !other.faceClasses.isEmpty
        let keepNormals = (positions.isEmpty || hasNormals) && other.hasNormals
        positions += other.positions
        if keepNormals { normals += other.normals } else { normals = [] }
        if keepColors { colors += other.colors } else { colors = [] }
        indices += other.indices.map { $0 + base }
        if keepClasses { faceClasses += other.faceClasses } else { faceClasses = [] }
    }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard !positions.isEmpty else { return (.zero, .zero) }
        var lo = positions[0], hi = positions[0]
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    /// Recomputes smooth vertex normals from the triangles.
    mutating func computeNormals() {
        var n = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in 0..<triangleCount {
            let a = Int(indices[3 * t]), b = Int(indices[3 * t + 1]), c = Int(indices[3 * t + 2])
            let fn = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            n[a] += fn; n[b] += fn; n[c] += fn
        }
        normals = n.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    func faceNormal(_ t: Int) -> SIMD3<Float> {
        let a = positions[Int(indices[3 * t])], b = positions[Int(indices[3 * t + 1])], c = positions[Int(indices[3 * t + 2])]
        let n = simd_cross(b - a, c - a)
        return simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
    }
}

// MARK: - Coordinates

extension MeshData {
    /// The height of the floor in ARKit Y: the median of floor-classified faces, or a low percentile of all vertices.
    var floorHeight: Float {
        var ys: [Float] = []
        if faceClasses.count == triangleCount {
            for t in 0..<triangleCount where faceClasses[t] == MeshClass.floor.rawValue {
                ys.append(positions[Int(indices[3 * t])].y)
            }
        }
        if ys.count < 50 { ys = positions.map { $0.y } }
        guard !ys.isEmpty else { return 0 }
        ys.sort()
        let q: Float = faceClasses.count == triangleCount && ys.count != positions.count ? 0.5 : 0.02
        return ys[min(ys.count - 1, Int(Float(ys.count) * q))]
    }

    /// ARKit (Y up) → CAD (Z up, floor at 0).
    static func toCAD(_ p: SIMD3<Float>, floor: Float) -> SIMD3<Float> { SIMD3(p.x, -p.z, p.y - floor) }
    static func toCADNormal(_ n: SIMD3<Float>) -> SIMD3<Float> { SIMD3(n.x, -n.z, n.y) }
}

/// ARKit mesh classes (same raw values as ARMeshClassification).
enum MeshClass: UInt8, CaseIterable {
    case none = 0, wall, floor, ceiling, table, seat, window, door

    var name: String {
        switch self {
        case .none: return "Other"
        case .wall: return "Walls"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .table: return "Tables"
        case .seat: return "Seats"
        case .window: return "Windows"
        case .door: return "Doors"
        }
    }

    var color: SIMD3<UInt8> {
        switch self {
        case .none: return SIMD3(170, 170, 170)
        case .wall: return SIMD3(224, 214, 196)
        case .floor: return SIMD3(150, 110, 75)
        case .ceiling: return SIMD3(240, 240, 245)
        case .table: return SIMD3(80, 160, 230)
        case .seat: return SIMD3(230, 140, 60)
        case .window: return SIMD3(120, 210, 240)
        case .door: return SIMD3(200, 70, 70)
        }
    }
}

// MARK: - Processing

extension MeshData {
    /// Vertex-clustering simplification. `cell` is the grid size in metres (0 = no change).
    func simplified(cell: Float) -> MeshData {
        guard cell > 0, !isEmpty else { return self }
        struct Key: Hashable { var x: Int32, y: Int32, z: Int32 }
        var map: [Key: Int] = [:]
        var sums: [SIMD3<Float>] = [], counts: [Float] = [], colorSums: [SIMD3<Float>] = []
        var remap = [Int](repeating: 0, count: positions.count)
        map.reserveCapacity(positions.count / 4)
        let colored = hasColors
        for (i, p) in positions.enumerated() {
            let k = Key(x: Int32((p.x / cell).rounded(.down)), y: Int32((p.y / cell).rounded(.down)), z: Int32((p.z / cell).rounded(.down)))
            if let idx = map[k] {
                sums[idx] += p; counts[idx] += 1
                if colored { colorSums[idx] += SIMD3<Float>(colors[i]) }
                remap[i] = idx
            } else {
                map[k] = sums.count; remap[i] = sums.count
                sums.append(p); counts.append(1)
                if colored { colorSums.append(SIMD3<Float>(colors[i])) }
            }
        }
        var out = MeshData()
        out.positions = zip(sums, counts).map { $0 / $1 }
        if colored { out.colors = zip(colorSums, counts).map { rgb($0 / $1) } }
        let keepClasses = faceClasses.count == triangleCount
        var seen = Set<SIMD3<UInt32>>()
        for t in 0..<triangleCount {
            let a = UInt32(remap[Int(indices[3 * t])]), b = UInt32(remap[Int(indices[3 * t + 1])]), c = UInt32(remap[Int(indices[3 * t + 2])])
            if a == b || b == c || a == c { continue }
            // Drop duplicate triangles that collapse onto the same three clusters.
            let m = min(a, b, c), M = max(a, b, c), mid = a ^ b ^ c ^ m ^ M
            if !seen.insert(SIMD3(m, mid, M)).inserted { continue }
            out.indices += [a, b, c]
            if keepClasses { out.faceClasses.append(faceClasses[t]) }
        }
        out.computeNormals()
        return out
    }

    /// A copy coloured by ARKit classification.
    func colouredByClass() -> MeshData {
        guard faceClasses.count == triangleCount else { return self }
        var out = self
        out.colors = [SIMD3<UInt8>](repeating: MeshClass.none.color, count: positions.count)
        for t in 0..<triangleCount {
            let c = (MeshClass(rawValue: faceClasses[t]) ?? .none).color
            for k in 0..<3 { out.colors[Int(indices[3 * t + k])] = c }
        }
        return out
    }

    /// Splits the mesh into one part per classification (for IFC/OBJ layers).
    func partsByClass() -> [(MeshClass, MeshData)] {
        guard faceClasses.count == triangleCount else { return [(.none, self)] }
        var result: [(MeshClass, MeshData)] = []
        for cls in MeshClass.allCases {
            var part = MeshData()
            var remap: [UInt32: UInt32] = [:]
            for t in 0..<triangleCount where faceClasses[t] == cls.rawValue {
                for k in 0..<3 {
                    let old = indices[3 * t + k]
                    if let n = remap[old] { part.indices.append(n); continue }
                    let n = UInt32(part.positions.count)
                    remap[old] = n
                    part.positions.append(positions[Int(old)])
                    if hasNormals { part.normals.append(normals[Int(old)]) }
                    if hasColors { part.colors.append(colors[Int(old)]) }
                    part.indices.append(n)
                }
                part.faceClasses.append(cls.rawValue)
            }
            if !part.isEmpty { result.append((cls, part)) }
        }
        return result
    }

    /// Horizontal section of the mesh at `height` above the floor, as 2D plan segments (X right, Y forward).
    func section(atHeight height: Float, floor: Float) -> [(SIMD2<Float>, SIMD2<Float>)] {
        let h = floor + height
        var segs: [(SIMD2<Float>, SIMD2<Float>)] = []
        for t in 0..<triangleCount {
            let p = [positions[Int(indices[3 * t])], positions[Int(indices[3 * t + 1])], positions[Int(indices[3 * t + 2])]]
            var hits: [SIMD2<Float>] = []
            for k in 0..<3 {
                let a = p[k], b = p[(k + 1) % 3]
                let da = a.y - h, db = b.y - h
                if (da < 0) != (db < 0) {
                    let s = da / (da - db)
                    let q = a + (b - a) * s
                    hits.append(SIMD2(q.x, -q.z))
                }
            }
            if hits.count == 2 { segs.append((hits[0], hits[1])) }
        }
        return segs
    }
}

// MARK: - Binary file

extension MeshData {
    private static let magic: UInt32 = 0x4D56_4353 // "SCVM"

    func write(to url: URL) throws {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        func putArray<T>(_ a: [T]) { put(UInt32(a.count)); a.withUnsafeBufferPointer { d.append(Data(buffer: $0)) } }
        put(Self.magic); put(UInt32(1))
        putArray(positions); putArray(hasNormals ? normals : []); putArray(hasColors ? colors : [])
        putArray(indices); putArray(faceClasses)
        try d.write(to: url, options: .atomic)
    }

    init(contentsOf url: URL) throws {
        let d = try Data(contentsOf: url)
        var offset = 0
        func get<T>(_: T.Type) throws -> T {
            guard offset + MemoryLayout<T>.size <= d.count else { throw CocoaError(.fileReadCorruptFile) }
            let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += MemoryLayout<T>.size
            return v
        }
        func getArray<T>(_: T.Type) throws -> [T] {
            let n = Int(try get(UInt32.self))
            if n == 0 { return [] }
            let bytes = n * MemoryLayout<T>.stride
            guard offset + bytes <= d.count else { throw CocoaError(.fileReadCorruptFile) }
            let arr = [T](unsafeUninitializedCapacity: n) { buf, count in
                d.withUnsafeBytes { raw in
                    _ = memcpy(buf.baseAddress!, raw.baseAddress! + offset, bytes)
                }
                count = n
            }
            offset += bytes
            return arr
        }
        guard try get(UInt32.self) == Self.magic else { throw CocoaError(.fileReadCorruptFile) }
        _ = try get(UInt32.self)
        self.init()
        positions = try getArray(SIMD3<Float>.self)
        normals = try getArray(SIMD3<Float>.self)
        colors = try getArray(SIMD3<UInt8>.self)
        indices = try getArray(UInt32.self)
        faceClasses = try getArray(UInt8.self)
    }
}

/// Float RGB (0…255) → byte RGB.
func rgb(_ v: SIMD3<Float>) -> SIMD3<UInt8> {
    func c(_ x: Float) -> UInt8 { UInt8(max(0, min(255, x.rounded()))) }
    return SIMD3(c(v.x), c(v.y), c(v.z))
}

// MARK: - Smoothing

extension MeshData {
    /// Merges vertices that sit on top of each other (ARKit repeats them where mesh anchors meet).
    func welded(tolerance: Float = 0.002) -> MeshData {
        struct Key: Hashable { var x: Int32, y: Int32, z: Int32 }
        var map: [Key: UInt32] = [:]
        map.reserveCapacity(positions.count)
        var remap = [UInt32](repeating: 0, count: positions.count)
        var out = MeshData()
        let keepColors = hasColors, keepNormals = hasNormals
        for (i, p) in positions.enumerated() {
            let k = Key(x: Int32((p.x / tolerance).rounded()), y: Int32((p.y / tolerance).rounded()), z: Int32((p.z / tolerance).rounded()))
            if let j = map[k] { remap[i] = j; continue }
            let j = UInt32(out.positions.count)
            map[k] = j; remap[i] = j
            out.positions.append(p)
            if keepNormals { out.normals.append(normals[i]) }
            if keepColors { out.colors.append(colors[i]) }
        }
        let keepClasses = faceClasses.count == triangleCount
        for t in 0..<triangleCount {
            let a = remap[Int(indices[3 * t])], b = remap[Int(indices[3 * t + 1])], c = remap[Int(indices[3 * t + 2])]
            if a == b || b == c || a == c { continue }
            out.indices += [a, b, c]
            if keepClasses { out.faceClasses.append(faceClasses[t]) }
        }
        return out
    }

    /// Taubin smoothing: irons out LiDAR noise without shrinking the scan.
    func smoothed(iterations: Int = 4) -> MeshData {
        guard !isEmpty else { return self }
        var m = welded()
        let n = m.positions.count
        // Neighbour lists from triangle edges.
        var neighbours = [[UInt32]](repeating: [], count: n)
        for t in 0..<m.triangleCount {
            let v = [m.indices[3 * t], m.indices[3 * t + 1], m.indices[3 * t + 2]]
            for (a, b) in [(v[0], v[1]), (v[1], v[2]), (v[2], v[0])] {
                if !neighbours[Int(a)].contains(b) { neighbours[Int(a)].append(b) }
                if !neighbours[Int(b)].contains(a) { neighbours[Int(b)].append(a) }
            }
        }
        // Boundary vertices (on an edge used by only one triangle) stay put so holes don't grow.
        var edgeUse: [UInt64: UInt8] = [:]
        for t in 0..<m.triangleCount {
            for k in 0..<3 {
                let a = m.indices[3 * t + k], b = m.indices[3 * t + (k + 1) % 3]
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                edgeUse[key, default: 0] &+= 1
            }
        }
        var fixed = [Bool](repeating: false, count: n)
        for (key, uses) in edgeUse where uses == 1 {
            fixed[Int(key >> 32)] = true; fixed[Int(key & 0xFFFF_FFFF)] = true
        }
        var p = m.positions
        func step(_ factor: Float) {
            var next = p
            for i in 0..<n where !fixed[i] && !neighbours[i].isEmpty {
                var avg = SIMD3<Float>.zero
                for j in neighbours[i] { avg += p[Int(j)] }
                avg /= Float(neighbours[i].count)
                next[i] = p[i] + factor * (avg - p[i])
            }
            p = next
        }
        for _ in 0..<iterations { step(0.5); step(-0.53) }
        m.positions = p
        m.computeNormals()
        // Keep normals facing the same way ARKit had them (towards where the scanner stood).
        if hasNormals && !SceneExport.facesTowardNormals(self) {
            m.normals = m.normals.map { -$0 }
        }
        return m
    }
}
