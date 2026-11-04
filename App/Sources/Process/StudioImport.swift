import Foundation
import simd

/// Brings a model processed by Scanvas Studio back into its scan: reads Studio's GLB (positions, normals,
/// texture coordinates, indices and one embedded JPEG texture) and saves it as the scan's photo-textured model.
enum StudioImport {
    struct ImportError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func apply(glb url: URL, to folder: URL) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 20, read(UInt32.self, data, 0) == 0x46546C67 else { throw ImportError(message: "That file isn't a GLB model.") }
        let jsonLength = Int(read(UInt32.self, data, 12))
        guard read(UInt32.self, data, 16) == 0x4E4F534A, data.count >= 20 + jsonLength + 8 else { throw ImportError(message: "The model file is damaged.") }
        guard let json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<(20 + jsonLength))) as? [String: Any] else {
            throw ImportError(message: "The model file is damaged.")
        }
        let binStart = 20 + jsonLength + 8
        guard let views = json["bufferViews"] as? [[String: Any]], let accessors = json["accessors"] as? [[String: Any]],
              let meshes = json["meshes"] as? [[String: Any]],
              let prim = (meshes.first?["primitives"] as? [[String: Any]])?.first,
              let attrs = prim["attributes"] as? [String: Int], let pos = attrs["POSITION"], let idx = prim["indices"] as? Int
        else { throw ImportError(message: "This GLB doesn't have the layout Scanvas Studio writes.") }

        func span(_ accessor: Int) -> (offset: Int, count: Int, type: Int) {
            let a = accessors[accessor]
            let v = views[a["bufferView"] as? Int ?? 0]
            return (binStart + (v["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0), a["count"] as? Int ?? 0, a["componentType"] as? Int ?? 0)
        }
        func vec3(_ accessor: Int) -> [SIMD3<Float>] {
            let s = span(accessor)
            return (0..<s.count).map { i in
                let o = s.offset + i * 12
                return SIMD3(read(Float.self, data, o), read(Float.self, data, o + 4), read(Float.self, data, o + 8))
            }
        }
        var page = TexturedMesh.Page()
        page.positions = vec3(pos)
        if let n = attrs["NORMAL"] { page.normals = vec3(n) }
        if let t = attrs["TEXCOORD_0"] {
            let s = span(t)
            // glTF and Scanvas both count texture rows from the top.
            page.uvs = (0..<s.count).map { i in SIMD2(read(Float.self, data, s.offset + i * 8), read(Float.self, data, s.offset + i * 8 + 4)) }
        }
        let s = span(idx)
        page.indices = (0..<s.count).map { i in
            s.type == 5125 ? read(UInt32.self, data, s.offset + i * 4) : UInt32(read(UInt16.self, data, s.offset + i * 2))
        }
        guard !page.positions.isEmpty, page.uvs.count == page.positions.count,
              let images = json["images"] as? [[String: Any]], let iv = images.first?["bufferView"] as? Int else {
            throw ImportError(message: "This model has no photo texture.")
        }
        let v = views[iv]
        let start = binStart + (v["byteOffset"] as? Int ?? 0), length = v["byteLength"] as? Int ?? 0
        guard start + length <= data.count else { throw ImportError(message: "The model file is damaged.") }

        // Replace the scan's textures with Studio's.
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("tex_") && name.hasSuffix(".jpg") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        try data.subdata(in: start..<(start + length)).write(to: folder.appendingPathComponent(TexturedMesh.textureName(0)), options: .atomic)
        var textured = TexturedMesh()
        textured.pages = [page]
        try textured.write(to: folder.appendingPathComponent(ProjectFile.textured))
        let note = "\nstudio: imported \(page.indices.count / 3) triangles from Scanvas Studio"
        if let h = try? FileHandle(forWritingTo: folder.appendingPathComponent("processing.txt")) {
            h.seekToEndOfFile(); h.write(Data(note.utf8)); try? h.close()
        }
        return page.indices.count / 3
    }

    private static func read<T: FixedWidthInteger>(_ type: T.Type, _ data: Data, _ offset: Int) -> T {
        data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    private static func read(_ type: Float.Type, _ data: Data, _ offset: Int) -> Float {
        Float(bitPattern: read(UInt32.self, data, offset))
    }
}
