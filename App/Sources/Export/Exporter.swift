import Foundation
import simd

enum ExportFormat: String, CaseIterable, Identifiable {
    case dxfPlan, dxf3D, ifc, pdfPlan, pngPlan, obj, usdz, roomPlanUSDZ, glb, stl, ply, pts, xyz, csv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dxfPlan: return "Floor plan · DXF"
        case .dxf3D: return "3D model · DXF"
        case .ifc: return "BIM model · IFC"
        case .pdfPlan: return "Floor plan · PDF"
        case .pngPlan: return "Floor plan · PNG"
        case .obj: return "Mesh · OBJ"
        case .usdz: return "Mesh · USDZ"
        case .roomPlanUSDZ: return "RoomPlan model · USDZ"
        case .glb: return "Mesh · GLB (glTF)"
        case .stl: return "Mesh · STL"
        case .ply: return "Mesh · PLY"
        case .pts: return "Point cloud · PTS"
        case .xyz: return "Point cloud · XYZ"
        case .csv: return "Measurements · CSV"
        }
    }

    var detail: String {
        switch self {
        case .dxfPlan: return "AutoCAD, Revit (Import CAD). Walls, doors, windows, furniture, dimensions on layers."
        case .dxf3D: return "AutoCAD / Revit 3D faces, one layer per part."
        case .ifc: return "Revit (Open or Link IFC), ArchiCAD, BIM viewers."
        case .pdfPlan: return "Printable plan with dimensions and area."
        case .pngPlan: return "Plan image for messages and docs."
        case .obj: return "Revit 2024+, SketchUp, Blender, 3ds Max, Rhino. Photo-textured scans export as a zip with textures."
        case .usdz: return "iPhone Quick Look, Reality Composer, AR."
        case .roomPlanUSDZ: return "Apple's own parametric room model."
        case .glb: return "Web viewers, Blender, Unity, Unreal."
        case .stl: return "3D printing, Fusion, Rhino."
        case .ply: return "CloudCompare, MeshLab, Blender (with colours)."
        case .pts: return "Autodesk ReCap → RCP for AutoCAD / Revit point clouds."
        case .xyz: return "Any point-cloud tool."
        case .csv: return "Wall lengths, heights, openings and areas for Excel."
        }
    }

    var fileExtension: String {
        switch self {
        case .dxfPlan, .dxf3D: return "dxf"
        case .ifc: return "ifc"
        case .pdfPlan: return "pdf"
        case .pngPlan: return "png"
        case .obj: return "obj"
        case .usdz, .roomPlanUSDZ: return "usdz"
        case .glb: return "glb"
        case .stl: return "stl"
        case .ply: return "ply"
        case .pts: return "pts"
        case .xyz: return "xyz"
        case .csv: return "csv"
        }
    }

    var suffix: String {
        switch self {
        case .dxfPlan: return "-plan"
        case .dxf3D: return "-3d"
        case .pdfPlan, .pngPlan: return "-plan"
        case .roomPlanUSDZ: return "-roomplan"
        case .pts, .xyz: return "-points"
        default: return ""
        }
    }

    static func available(for kind: ScanKind, hasRoomPlanUSDZ: Bool) -> [ExportFormat] {
        switch kind {
        case .room:
            return allCases.filter { $0 != .roomPlanUSDZ || hasRoomPlanUSDZ }
        case .space:
            return [.dxfPlan, .dxf3D, .ifc, .pdfPlan, .pngPlan, .obj, .usdz, .glb, .stl, .ply, .pts, .xyz]
        case .object:
            return [.usdz, .obj, .glb, .stl, .ply, .dxf3D, .ifc, .pts, .xyz]
        }
    }

    static let defaults: Set<ExportFormat> = [.dxfPlan, .ifc, .obj]
}

struct ExportOptions {
    var unit: CADUnit = .millimetres
    var displayUnits: UnitSystem = .metric
    /// Vertex-cluster size in metres for meshes (0 = full detail).
    var simplify: Float = 0
    /// Height above the floor of the plan section for spaces.
    var sectionHeight: Float = 1.2
    var colorByClass = false
    var splitByClass = true
}

enum Exporter {
    /// Writes every requested format into Documents/Exports/<project name>/ and returns the files.
    static func export(project: ScanProject, folder: URL, formats: Set<ExportFormat>, options: ExportOptions,
                       progress: @escaping (String) -> Void) throws -> [URL] {
        let fm = FileManager.default
        let safeName = project.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let outDir = ProjectStore.exportsRoot.appendingPathComponent(safeName, isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let plan: PlanModel? = (try? Data(contentsOf: folder.appendingPathComponent(ProjectFile.plan)))
            .flatMap { try? JSONDecoder().decode(PlanModel.self, from: $0) }
        var mesh: MeshData
        if let plan, project.kind == .room {
            mesh = PlanMesher.combined(plan)
        } else {
            mesh = try MeshData(contentsOf: folder.appendingPathComponent(ProjectFile.mesh))
        }
        if project.kind != .room && options.simplify > 0 {
            progress("Simplifying mesh…")
            mesh = mesh.simplified(cell: options.simplify)
        }
        if options.colorByClass { mesh = mesh.colouredByClass() }
        let floor: Float = project.kind == .room ? 0 : mesh.floorHeight

        var parts: [(String, MeshData)]
        if let plan, project.kind == .room {
            parts = PlanMesher.parts(plan)
        } else if options.splitByClass && mesh.faceClasses.count == mesh.triangleCount && !mesh.faceClasses.isEmpty {
            parts = mesh.partsByClass().map { ($0.0.name, $0.1) }
        } else {
            parts = [(project.kind == .object ? "Object" : "Scan", mesh)]
        }

        // Photo textures are used for OBJ/GLB/USDZ when the scan has them and full detail is chosen.
        let textured: TexturedMesh? = options.simplify == 0 && !options.colorByClass
            ? try? TexturedMesh(contentsOf: folder.appendingPathComponent(ProjectFile.textured)) : nil

        var section: [(SIMD2<Float>, SIMD2<Float>)] = []
        if project.kind == .space && (formats.contains(.dxfPlan) || formats.contains(.pdfPlan) || formats.contains(.pngPlan)) {
            progress("Cutting plan section…")
            section = mesh.section(atHeight: options.sectionHeight, floor: floor)
        }

        var urls: [URL] = []
        for format in ExportFormat.allCases where formats.contains(format) {
            let url = outDir.appendingPathComponent(safeName + format.suffix + "." + format.fileExtension)
            try? fm.removeItem(at: url)
            progress("Writing \(format.title)…")
            switch format {
            case .dxfPlan:
                if let plan, project.kind == .room {
                    try DXFExport.floorPlan(plan, to: url, unit: options.unit, units: options.displayUnits)
                } else {
                    try DXFExport.section(section, to: url, unit: options.unit)
                }
            case .dxf3D:
                try DXFExport.mesh(parts: parts, to: url, unit: options.unit, floor: floor)
            case .ifc:
                if let plan, project.kind == .room {
                    try IFCExport.room(plan, name: project.name, to: url)
                } else {
                    try IFCExport.mesh(parts: parts, name: project.name, floor: floor, to: url)
                }
            case .pdfPlan, .pngPlan:
                let drawing = PlanDrawing(plan: project.kind == .room ? plan : nil, section: section, title: project.name, units: options.displayUnits)
                if format == .pdfPlan { try PlanImageExport.pdf(drawing, to: url) } else { try PlanImageExport.png(drawing, to: url) }
            case .obj:
                if let textured, !textured.pages.isEmpty {
                    progress("Writing textured OBJ…")
                    let dir = outDir.appendingPathComponent(safeName + "-obj", isDirectory: true)
                    try? fm.removeItem(at: dir)
                    try MeshFormats.texturedOBJ(textured, textures: folder, name: safeName, in: dir)
                    let zip = outDir.appendingPathComponent(safeName + "-obj.zip")
                    try? fm.removeItem(at: zip)
                    try zipFolder(dir, to: zip)
                    try? fm.removeItem(at: dir)
                    urls.append(zip)
                    continue
                }
                try MeshFormats.obj(parts: parts, to: url)
            case .usdz:
                let model = folder.appendingPathComponent(ProjectFile.model)
                if project.kind == .object && fm.fileExists(atPath: model.path) {
                    try fm.copyItem(at: model, to: url)
                } else if let textured, !textured.pages.isEmpty {
                    try SceneExport.write(SceneExport.texturedScene(textured, folder: folder, dollhouse: false), to: url)
                } else {
                    try SceneExport.usdz(parts: parts, to: url)
                }
            case .roomPlanUSDZ:
                try fm.copyItem(at: folder.appendingPathComponent(ProjectFile.roomUSDZ), to: url)
            case .glb:
                if let textured, !textured.pages.isEmpty {
                    try MeshFormats.texturedGLB(textured, textures: folder, to: url)
                } else {
                    try MeshFormats.glb(parts: parts, to: url)
                }
            case .stl:
                try MeshFormats.stl(mesh, floor: floor, to: url)
            case .ply:
                try MeshFormats.ply(mesh, floor: floor, to: url)
            case .pts:
                try MeshFormats.pts(mesh, floor: floor, to: url)
            case .xyz:
                try MeshFormats.xyz(mesh, floor: floor, to: url)
            case .csv:
                guard let plan else { continue }
                try csv(plan, units: options.displayUnits).write(to: url, atomically: true, encoding: .utf8)
            }
            urls.append(url)
        }
        return urls
    }

    /// Zips a folder with the system's built-in archiver (the same one Files uses).
    static func zipFolder(_ dir: URL, to zip: URL) throws {
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &coordError) { tmp in
            do { try FileManager.default.copyItem(at: tmp, to: zip) } catch { copyError = error }
        }
        if let e = coordError ?? (copyError as NSError?) { throw e }
    }

    static func csv(_ plan: PlanModel, units: UnitSystem) -> String {
        var rows = ["Type,Label,Width (m),Depth (m),Height (m),Width,Height,Centre X (m),Centre Y (m)"]
        for e in plan.elements {
            let kind = e.kind.rawValue.capitalized
            rows.append([kind, e.label, num(e.size.x, 1000), num(e.size.y, 1000), num(e.size.z, 1000),
                         units.length(e.size.x), units.length(e.size.z), num(e.center.x, 1000), num(e.center.y, 1000)]
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ","))
        }
        rows.append("")
        rows.append("\"Floor area\",\"\(units.area(plan.floorArea))\",\(num(plan.floorArea, 100))")
        rows.append("\"Total wall length\",\"\(units.length(plan.wallLength))\",\(num(plan.wallLength, 100))")
        rows.append("\"Ceiling height\",\"\(units.length(plan.ceilingHeight))\",\(num(plan.ceilingHeight, 100))")
        return rows.joined(separator: "\n") + "\n"
    }
}
