import Foundation
import simd

/// Plain mesh and point-cloud formats. Inputs are ARKit world coordinates (Y up).
/// OBJ/GLB stay Y-up (their convention); STL/PLY/PTS/XYZ are written Z-up with the floor at 0, as CAD and point-cloud tools expect.
enum MeshFormats {
    // MARK: OBJ

    static func obj(parts: [(String, MeshData)], to url: URL) throws {
        let out = try TextFileWriter(url: url)
        out.line("# Exported by Scanvas")
        var base = 1
        for (name, m) in parts where !m.isEmpty {
            out.line("o \(name.replacingOccurrences(of: " ", with: "_"))")
            for (i, p) in m.positions.enumerated() {
                if m.hasColors {
                    let c = SIMD3<Float>(m.colors[i]) / 255
                    out.line("v \(num(p.x)) \(num(p.y)) \(num(p.z)) \(num(c.x, 1000)) \(num(c.y, 1000)) \(num(c.z, 1000))")
                } else {
                    out.line("v \(num(p.x)) \(num(p.y)) \(num(p.z))")
                }
            }
            if m.hasNormals { for n in m.normals { out.line("vn \(num(n.x, 1000)) \(num(n.y, 1000)) \(num(n.z, 1000))") } }
            for t in 0..<m.triangleCount {
                let a = Int(m.indices[3 * t]) + base, b = Int(m.indices[3 * t + 1]) + base, c = Int(m.indices[3 * t + 2]) + base
                out.line(m.hasNormals ? "f \(a)//\(a) \(b)//\(b) \(c)//\(c)" : "f \(a) \(b) \(c)")
            }
            base += m.vertexCount
        }
        out.close()
    }

    // MARK: STL (binary, Z-up)

    static func stl(_ m: MeshData, floor: Float, to url: URL) throws {
        var d = Data(count: 80)
        d.replaceSubrange(0..<17, with: Data("Scanvas STL mesh ".utf8))
        append(&d, UInt32(m.triangleCount))
        for t in 0..<m.triangleCount {
            let a = MeshData.toCAD(m.positions[Int(m.indices[3 * t])], floor: floor)
            let b = MeshData.toCAD(m.positions[Int(m.indices[3 * t + 1])], floor: floor)
            let c = MeshData.toCAD(m.positions[Int(m.indices[3 * t + 2])], floor: floor)
            var n = simd_cross(b - a, c - a)
            n = simd_length(n) > 0 ? simd_normalize(n) : .zero
            for v in [n, a, b, c] { append(&d, v.x); append(&d, v.y); append(&d, v.z) }
            append(&d, UInt16(0))
        }
        try d.write(to: url, options: .atomic)
    }

    // MARK: PLY (binary, Z-up, with colours)

    static func ply(_ m: MeshData, floor: Float, pointsOnly: Bool = false, to url: URL) throws {
        var header = "ply\nformat binary_little_endian 1.0\ncomment Exported by Scanvas\n"
        header += "element vertex \(m.vertexCount)\nproperty float x\nproperty float y\nproperty float z\n"
        if m.hasNormals { header += "property float nx\nproperty float ny\nproperty float nz\n" }
        if m.hasColors { header += "property uchar red\nproperty uchar green\nproperty uchar blue\n" }
        if !pointsOnly { header += "element face \(m.triangleCount)\nproperty list uchar int vertex_indices\n" }
        header += "end_header\n"
        var d = Data(header.utf8)
        d.reserveCapacity(d.count + m.vertexCount * 27 + m.triangleCount * 13)
        for i in 0..<m.vertexCount {
            let p = MeshData.toCAD(m.positions[i], floor: floor)
            append(&d, p.x); append(&d, p.y); append(&d, p.z)
            if m.hasNormals { let n = MeshData.toCADNormal(m.normals[i]); append(&d, n.x); append(&d, n.y); append(&d, n.z) }
            if m.hasColors { let c = m.colors[i]; d.append(contentsOf: [c.x, c.y, c.z]) }
        }
        if !pointsOnly {
            for t in 0..<m.triangleCount {
                d.append(UInt8(3))
                for k in 0..<3 { append(&d, Int32(m.indices[3 * t + k])) }
            }
        }
        try d.write(to: url, options: .atomic)
    }

    // MARK: Point clouds (Z-up) — PTS and XYZ open in Autodesk ReCap, then attach the RCP in AutoCAD or Revit.

    static func pts(_ m: MeshData, floor: Float, to url: URL) throws {
        let out = try TextFileWriter(url: url)
        out.line("\(m.vertexCount)")
        for i in 0..<m.vertexCount {
            let p = MeshData.toCAD(m.positions[i], floor: floor)
            let c = m.hasColors ? m.colors[i] : SIMD3(200, 200, 200)
            out.line("\(num(p.x)) \(num(p.y)) \(num(p.z)) 0 \(c.x) \(c.y) \(c.z)")
        }
        out.close()
    }

    static func xyz(_ m: MeshData, floor: Float, to url: URL) throws {
        let out = try TextFileWriter(url: url)
        for i in 0..<m.vertexCount {
            let p = MeshData.toCAD(m.positions[i], floor: floor)
            let c = m.hasColors ? m.colors[i] : SIMD3(200, 200, 200)
            out.line("\(num(p.x)) \(num(p.y)) \(num(p.z)) \(c.x) \(c.y) \(c.z)")
        }
        out.close()
    }

    // MARK: glTF binary (GLB), Y-up, with vertex colours

    static func glb(parts: [(String, MeshData)], to url: URL) throws {
        var bin = Data()
        var bufferViews: [[String: Any]] = [], accessors: [[String: Any]] = [], meshes: [[String: Any]] = [], nodes: [[String: Any]] = []

        func view(_ data: Data, target: Int) -> Int {
            while bin.count % 4 != 0 { bin.append(0) }
            bufferViews.append(["buffer": 0, "byteOffset": bin.count, "byteLength": data.count, "target": target])
            bin.append(data)
            return bufferViews.count - 1
        }
        func accessor(_ view: Int, type: String, componentType: Int, count: Int, normalized: Bool = false, min: [Float]? = nil, max: [Float]? = nil) -> Int {
            var a: [String: Any] = ["bufferView": view, "componentType": componentType, "count": count, "type": type]
            if normalized { a["normalized"] = true }
            if let min, let max { a["min"] = min; a["max"] = max }
            accessors.append(a)
            return accessors.count - 1
        }

        for (name, m) in parts where !m.isEmpty {
            var pos = Data(); pos.reserveCapacity(m.vertexCount * 12)
            for p in m.positions { append(&pos, p.x); append(&pos, p.y); append(&pos, p.z) }
            let b = m.bounds
            var attributes: [String: Int] = [
                "POSITION": accessor(view(pos, target: 34962), type: "VEC3", componentType: 5126, count: m.vertexCount,
                                     min: [b.min.x, b.min.y, b.min.z], max: [b.max.x, b.max.y, b.max.z]),
            ]
            if m.hasNormals {
                var nd = Data(); nd.reserveCapacity(m.vertexCount * 12)
                for n in m.normals { append(&nd, n.x); append(&nd, n.y); append(&nd, n.z) }
                attributes["NORMAL"] = accessor(view(nd, target: 34962), type: "VEC3", componentType: 5126, count: m.vertexCount)
            }
            if m.hasColors {
                var cd = Data(); cd.reserveCapacity(m.vertexCount * 4)
                for c in m.colors { cd.append(contentsOf: [c.x, c.y, c.z, 255]) }
                attributes["COLOR_0"] = accessor(view(cd, target: 34962), type: "VEC4", componentType: 5121, count: m.vertexCount, normalized: true)
            }
            var id = Data(); id.reserveCapacity(m.indices.count * 4)
            for i in m.indices { append(&id, i) }
            let indices = accessor(view(id, target: 34963), type: "SCALAR", componentType: 5125, count: m.indices.count)
            meshes.append(["name": name, "primitives": [["attributes": attributes, "indices": indices, "material": 0, "mode": 4]]])
            nodes.append(["name": name, "mesh": meshes.count - 1])
        }
        while bin.count % 4 != 0 { bin.append(0) }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Scanvas"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<nodes.count)]],
            "nodes": nodes, "meshes": meshes, "accessors": accessors, "bufferViews": bufferViews,
            "buffers": [["byteLength": bin.count]],
            "materials": [["name": "Scan", "doubleSided": true,
                           "pbrMetallicRoughness": ["baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 1]]],
        ]
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var d = Data()
        append(&d, UInt32(0x4654_6C67)); append(&d, UInt32(2)); append(&d, UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        append(&d, UInt32(jsonData.count)); append(&d, UInt32(0x4E4F_534A)); d.append(jsonData)
        append(&d, UInt32(bin.count)); append(&d, UInt32(0x004E_4942)); d.append(bin)
        try d.write(to: url, options: .atomic)
    }

    // MARK: Textured

    /// OBJ + MTL + JPEG textures in `dir` (Y-up, UV origin bottom-left as OBJ expects).
    static func texturedOBJ(_ t: TexturedMesh, textures: URL, name: String, in dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var mtl = "# Exported by Scanvas\n"
        for i in t.pages.indices {
            mtl += "newmtl photo\(i)\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nmap_Kd \(TexturedMesh.textureName(i))\n\n"
            let dst = dir.appendingPathComponent(TexturedMesh.textureName(i))
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: textures.appendingPathComponent(TexturedMesh.textureName(i)), to: dst)
        }
        mtl += "newmtl untextured\nKd 0.7 0.7 0.7\nillum 1\n"
        try mtl.write(to: dir.appendingPathComponent(name + ".mtl"), atomically: true, encoding: .utf8)

        let out = try TextFileWriter(url: dir.appendingPathComponent(name + ".obj"))
        out.line("# Exported by Scanvas")
        out.line("mtllib \(name).mtl")
        var base = 1
        for (i, p) in t.pages.enumerated() where !p.indices.isEmpty {
            out.line("o photo_part_\(i)")
            out.line("usemtl photo\(i)")
            for v in p.positions { out.line("v \(num(v.x)) \(num(v.y)) \(num(v.z))") }
            for uv in p.uvs { out.line("vt \(num(uv.x, 100000)) \(num(1 - uv.y, 100000))") }
            for tri in 0..<(p.indices.count / 3) {
                let a = Int(p.indices[3 * tri]) + base, b = Int(p.indices[3 * tri + 1]) + base, c = Int(p.indices[3 * tri + 2]) + base
                out.line("f \(a)/\(a) \(b)/\(b) \(c)/\(c)")
            }
            base += p.positions.count
        }
        let rest = t.untextured
        if !rest.isEmpty {
            out.line("o untextured")
            out.line("usemtl untextured")
            for v in rest.positions { out.line("v \(num(v.x)) \(num(v.y)) \(num(v.z))") }
            for tri in 0..<rest.triangleCount {
                out.line("f \(Int(rest.indices[3 * tri]) + base) \(Int(rest.indices[3 * tri + 1]) + base) \(Int(rest.indices[3 * tri + 2]) + base)")
            }
        }
        out.close()
    }

    /// glTF binary with the photo textures embedded.
    static func texturedGLB(_ t: TexturedMesh, textures: URL, to url: URL) throws {
        var bin = Data()
        var bufferViews: [[String: Any]] = [], accessors: [[String: Any]] = [], meshes: [[String: Any]] = [], nodes: [[String: Any]] = []
        var images: [[String: Any]] = [], materials: [[String: Any]] = [], texturesJSON: [[String: Any]] = []

        func view(_ data: Data, target: Int?) -> Int {
            while bin.count % 4 != 0 { bin.append(0) }
            var v: [String: Any] = ["buffer": 0, "byteOffset": bin.count, "byteLength": data.count]
            if let target { v["target"] = target }
            bufferViews.append(v)
            bin.append(data)
            return bufferViews.count - 1
        }
        func accessor(_ data: Data, type: String, componentType: Int, count: Int, target: Int, min: [Float]? = nil, max: [Float]? = nil) -> Int {
            var a: [String: Any] = ["bufferView": view(data, target: target), "componentType": componentType, "count": count, "type": type]
            if let min, let max { a["min"] = min; a["max"] = max }
            accessors.append(a)
            return accessors.count - 1
        }

        for (i, p) in t.pages.enumerated() where !p.indices.isEmpty {
            let jpeg = try Data(contentsOf: textures.appendingPathComponent(TexturedMesh.textureName(i)))
            images.append(["bufferView": view(jpeg, target: nil), "mimeType": "image/jpeg"])
            texturesJSON.append(["source": images.count - 1])
            materials.append(["name": "photo\(i)", "doubleSided": true, "extensions": ["KHR_materials_unlit": [String: Any]()],
                              "pbrMetallicRoughness": ["baseColorTexture": ["index": texturesJSON.count - 1], "metallicFactor": 0, "roughnessFactor": 1]])
            var pos = Data(), uv = Data(), idx = Data()
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for v in p.positions { append(&pos, v.x); append(&pos, v.y); append(&pos, v.z); lo = simd_min(lo, v); hi = simd_max(hi, v) }
            for c in p.uvs { append(&uv, c.x); append(&uv, c.y) }
            for k in p.indices { append(&idx, k) }
            var attributes: [String: Int] = [
                "POSITION": accessor(pos, type: "VEC3", componentType: 5126, count: p.positions.count, target: 34962,
                                     min: [lo.x, lo.y, lo.z], max: [hi.x, hi.y, hi.z]),
                "TEXCOORD_0": accessor(uv, type: "VEC2", componentType: 5126, count: p.uvs.count, target: 34962),
            ]
            if p.normals.count == p.positions.count {
                var nd = Data()
                for n in p.normals { append(&nd, n.x); append(&nd, n.y); append(&nd, n.z) }
                attributes["NORMAL"] = accessor(nd, type: "VEC3", componentType: 5126, count: p.normals.count, target: 34962)
            }
            let indices = accessor(idx, type: "SCALAR", componentType: 5125, count: p.indices.count, target: 34963)
            meshes.append(["name": "photo\(i)", "primitives": [["attributes": attributes, "indices": indices, "material": materials.count - 1, "mode": 4]]])
            nodes.append(["name": "photo\(i)", "mesh": meshes.count - 1])
        }
        while bin.count % 4 != 0 { bin.append(0) }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Scanvas"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<nodes.count)]],
            "nodes": nodes, "meshes": meshes, "accessors": accessors, "bufferViews": bufferViews,
            "buffers": [["byteLength": bin.count]],
            "materials": materials, "textures": texturesJSON, "images": images,
            "samplers": [["magFilter": 9729, "minFilter": 9987]],
            "extensionsUsed": ["KHR_materials_unlit"],
        ]
        if images.isEmpty { json["textures"] = nil; json["images"] = nil }
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        var d = Data()
        append(&d, UInt32(0x4654_6C67)); append(&d, UInt32(2)); append(&d, UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        append(&d, UInt32(jsonData.count)); append(&d, UInt32(0x4E4F_534A)); d.append(jsonData)
        append(&d, UInt32(bin.count)); append(&d, UInt32(0x004E_4942)); d.append(bin)
        try d.write(to: url, options: .atomic)
    }

    // MARK: Helpers

    @inline(__always) static func append<T>(_ d: inout Data, _ v: T) {
        withUnsafeBytes(of: v) { d.append(contentsOf: $0) }
    }
}
