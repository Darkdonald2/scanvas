import Foundation
import simd

/// A photo-textured mesh in ARKit world coordinates (Y up). Each page is one texture image
/// (`tex_<n>.jpg` next to the mesh file) with its own triangles; UVs have their origin at the image's top-left.
struct TexturedMesh {
    struct Page {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        var asMesh: MeshData {
            var m = MeshData()
            m.positions = positions; m.normals = normals; m.indices = indices
            return m
        }
    }

    var pages: [Page] = []
    /// Triangles no photo saw, kept with vertex colours.
    var untextured = MeshData()

    var triangleCount: Int { pages.reduce(untextured.triangleCount) { $0 + $1.indices.count / 3 } }

    static func textureName(_ page: Int) -> String { "tex_\(page).jpg" }

    func write(to url: URL) throws {
        var w = BinaryWriter()
        w.put(UInt32(0x5854_4353)); w.put(UInt32(1)) // "SCTX"
        w.put(UInt32(pages.count))
        for p in pages { w.putArray(p.positions); w.putArray(p.normals); w.putArray(p.uvs); w.putArray(p.indices) }
        try w.data.write(to: url, options: .atomic)
        try untextured.write(to: url.appendingPathExtension("rest"))
    }

    init() {}

    init(contentsOf url: URL) throws {
        var r = try BinaryReader(url: url)
        guard try r.get(UInt32.self) == 0x5854_4353 else { throw CocoaError(.fileReadCorruptFile) }
        _ = try r.get(UInt32.self)
        let n = Int(try r.get(UInt32.self))
        for _ in 0..<n {
            var p = Page()
            p.positions = try r.getArray(SIMD3<Float>.self)
            p.normals = try r.getArray(SIMD3<Float>.self)
            p.uvs = try r.getArray(SIMD2<Float>.self)
            p.indices = try r.getArray(UInt32.self)
            pages.append(p)
        }
        untextured = (try? MeshData(contentsOf: url.appendingPathExtension("rest"))) ?? MeshData()
    }
}

struct BinaryWriter {
    var data = Data()
    mutating func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
    mutating func putArray<T>(_ a: [T]) {
        put(UInt32(a.count))
        a.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    }
}

struct BinaryReader {
    let data: Data
    var offset = 0
    init(url: URL) throws { data = try Data(contentsOf: url) }

    mutating func get<T>(_: T.Type) throws -> T {
        guard offset + MemoryLayout<T>.size <= data.count else { throw CocoaError(.fileReadCorruptFile) }
        let o = offset
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: T.self) }
        offset += MemoryLayout<T>.size
        return v
    }

    mutating func getArray<T>(_: T.Type) throws -> [T] {
        let n = Int(try get(UInt32.self))
        if n == 0 { return [] }
        let bytes = n * MemoryLayout<T>.stride
        guard offset + bytes <= data.count else { throw CocoaError(.fileReadCorruptFile) }
        let o = offset
        let arr = [T](unsafeUninitializedCapacity: n) { buf, count in
            data.withUnsafeBytes { raw in _ = memcpy(buf.baseAddress!, raw.baseAddress! + o, bytes) }
            count = n
        }
        offset += bytes
        return arr
    }
}
