import Foundation
import UIKit
import simd

/// Brings a model processed by Scanvas Studio back into its scan: reads a GLB (positions, normals,
/// texture coordinates, indices and one embedded texture) and saves it as the scan's photo-textured model.
enum StudioImport {
    struct ImportError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static let damaged = ImportError(message: "The model file is damaged or incomplete. Send it to the phone again.")
    private static let layout = ImportError(message: "This GLB isn't laid out the way Scanvas can read: it needs one mesh with one photo texture.")

    /// Where an accessor's values sit in the file.
    private struct Span {
        var offset = 0, count = 0, stride = 0, type = 0
    }

    static func apply(glb url: URL, to folder: URL) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 28, u32(data, 0) == 0x4654_6C67 else { throw ImportError(message: "That file isn't a GLB model.") }
        let jsonLength = Int(u32(data, 12))
        guard u32(data, 16) == 0x4E4F_534A, jsonLength > 0, data.count >= 20 + jsonLength + 8 else { throw damaged }
        guard let json = try? JSONSerialization.jsonObject(with: data.subdata(in: 20..<(20 + jsonLength))) as? [String: Any] else {
            throw damaged
        }
        let binStart = 20 + jsonLength + 8
        guard let accessors = json["accessors"] as? [[String: Any]],
              let meshes = json["meshes"] as? [[String: Any]],
              let prim = (meshes.first?["primitives"] as? [[String: Any]])?.first,
              let attrs = prim["attributes"] as? [String: Int], let pos = attrs["POSITION"]
        else { throw layout }

        var views = json["bufferViews"] as? [[String: Any]] ?? []
        if views.isEmpty {
            // Scanvas Studio up to 1.0 left this table out of its files. Its layout is always the same
            // (positions, normals, texture coordinates, indices, then the picture), so rebuild the table.
            guard let nor = attrs["NORMAL"], let tex = attrs["TEXCOORD_0"], let idx = prim["indices"] as? Int,
                  [pos, nor, tex, idx].allSatisfy({ accessors.indices.contains($0) }) else { throw layout }
            var offset = 0
            for (accessor, bytes) in [(pos, 12), (nor, 12), (tex, 8), (idx, 4)] {
                let length = (accessors[accessor]["count"] as? Int ?? 0) * bytes
                views.append(["byteOffset": offset, "byteLength": length])
                offset += (length + 3) & ~3
            }
            guard data.count - binStart > offset else { throw damaged }
            views.append(["byteOffset": offset, "byteLength": data.count - binStart - offset])
        }

        func span(_ accessor: Int, size: (Int) -> Int) throws -> Span {
            guard accessors.indices.contains(accessor), let v = accessors[accessor]["bufferView"] as? Int, views.indices.contains(v) else { throw layout }
            let a = accessors[accessor], view = views[v]
            var s = Span()
            s.count = a["count"] as? Int ?? 0
            s.type = a["componentType"] as? Int ?? 0
            let element = size(s.type)
            s.stride = (view["byteStride"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? element
            s.offset = binStart + (view["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
            guard element > 0 else { throw layout }
            guard s.count >= 0, s.stride >= element, s.offset >= binStart,
                  s.count == 0 || s.offset + (s.count - 1) * s.stride + element <= data.count else { throw damaged }
            return s
        }
        func floatSpan(_ accessor: Int, components: Int) throws -> Span {
            try span(accessor) { $0 == 5126 ? components * 4 : 0 }
        }

        var page = TexturedMesh.Page()
        page.positions = vec3(data, try floatSpan(pos, components: 3))
        if let n = attrs["NORMAL"], let s = try? floatSpan(n, components: 3), s.count == page.positions.count {
            page.normals = vec3(data, s)
        }
        guard let t = attrs["TEXCOORD_0"] else { throw ImportError(message: "This model has no photo texture.") }
        // glTF and Scanvas both count texture rows from the top.
        page.uvs = vec2(data, try floatSpan(t, components: 2))
        if let idx = prim["indices"] as? Int {
            page.indices = indices(data, try span(idx) { $0 == 5125 ? 4 : $0 == 5123 ? 2 : $0 == 5121 ? 1 : 0 })
        } else {
            page.indices = (0..<UInt32(page.positions.count)).map { $0 }
        }
        page.indices.removeLast(page.indices.count % 3)
        guard !page.positions.isEmpty, !page.indices.isEmpty, page.uvs.count == page.positions.count else { throw layout }
        let limit = UInt32(page.positions.count)
        guard !page.indices.contains(where: { $0 >= limit }) else { throw damaged }

        guard let images = json["images"] as? [[String: Any]], let iv = images.first?["bufferView"] as? Int, views.indices.contains(iv) else {
            throw ImportError(message: "This model has no photo texture inside it. In Scanvas Studio, use model_textured.glb.")
        }
        let start = binStart + (views[iv]["byteOffset"] as? Int ?? 0), length = views[iv]["byteLength"] as? Int ?? 0
        guard start >= binStart, length > 4, start + length <= data.count else { throw damaged }
        var picture = data.subdata(in: start..<(start + length))
        if !(picture[picture.startIndex] == 0xFF && picture[picture.startIndex + 1] == 0xD8) {
            // Not a JPEG (GLBs from other programs often hold PNG): convert, since scans keep JPEG textures.
            guard let jpeg = UIImage(data: picture)?.jpegData(compressionQuality: 0.92) else {
                throw ImportError(message: "The model's texture picture couldn't be read.")
            }
            picture = jpeg
        }

        // Replace the scan's textures with the imported one.
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("tex_") && name.hasSuffix(".jpg") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        try picture.write(to: folder.appendingPathComponent(TexturedMesh.textureName(0)), options: .atomic)
        var textured = TexturedMesh()
        textured.pages = [page]
        try textured.write(to: folder.appendingPathComponent(ProjectFile.textured))
        let note = "\nstudio: imported \(page.indices.count / 3) triangles from Scanvas Studio"
        if let h = try? FileHandle(forWritingTo: folder.appendingPathComponent("processing.txt")) {
            h.seekToEndOfFile(); h.write(Data(note.utf8)); try? h.close()
        }
        return page.indices.count / 3
    }

    // MARK: Reading

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func vec3(_ data: Data, _ s: Span) -> [SIMD3<Float>] {
        guard s.count > 0 else { return [] }
        return [SIMD3<Float>](unsafeUninitializedCapacity: s.count) { out, n in
            data.withUnsafeBytes { raw in
                for i in 0..<s.count {
                    let o = s.offset + i * s.stride
                    out[i] = SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                   raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                   raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                }
            }
            n = s.count
        }
    }

    private static func vec2(_ data: Data, _ s: Span) -> [SIMD2<Float>] {
        guard s.count > 0 else { return [] }
        return [SIMD2<Float>](unsafeUninitializedCapacity: s.count) { out, n in
            data.withUnsafeBytes { raw in
                for i in 0..<s.count {
                    let o = s.offset + i * s.stride
                    out[i] = SIMD2(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                   raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self))
                }
            }
            n = s.count
        }
    }

    private static func indices(_ data: Data, _ s: Span) -> [UInt32] {
        guard s.count > 0 else { return [] }
        return [UInt32](unsafeUninitializedCapacity: s.count) { out, n in
            data.withUnsafeBytes { raw in
                for i in 0..<s.count {
                    let o = s.offset + i * s.stride
                    switch s.type {
                    case 5125: out[i] = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)
                    case 5123: out[i] = UInt32(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                    default: out[i] = UInt32(raw.load(fromByteOffset: o, as: UInt8.self))
                    }
                }
            }
            n = s.count
        }
    }
}
