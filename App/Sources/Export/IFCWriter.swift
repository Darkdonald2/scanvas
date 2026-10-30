import Foundation
import simd

/// Minimal STEP (ISO 10303-21) writer for IFC files that Revit, ArchiCAD, BlenderBIM and IFC viewers open.
final class IFCWriter {
    enum Schema: String { case ifc2x3 = "IFC2X3", ifc4 = "IFC4" }

    private let out: TextFileWriter
    private var nextID = 1
    let schema: Schema

    // Shared entities, valid after `init`.
    private(set) var ownerHistory = 0
    private(set) var bodyContext = 0
    private(set) var origin3D = 0
    private(set) var origin2D = 0
    private(set) var zAxis = 0
    private(set) var xAxis = 0
    private(set) var identity = 0
    private(set) var storey = 0
    private(set) var storeyPlacement = 0
    private var contained: [Int] = []

    init(url: URL, schema: Schema, projectName: String) throws {
        self.schema = schema
        out = try TextFileWriter(url: url)
        let stamp = ISO8601DateFormatter().string(from: Date())
        out.line("ISO-10303-21;")
        out.line("HEADER;")
        out.line("FILE_DESCRIPTION(('ViewDefinition [\(schema == .ifc2x3 ? "CoordinationView_V2.0" : "ReferenceView_V1.2")]'),'2;1');")
        out.line("FILE_NAME(\(str(projectName + ".ifc")),\(str(stamp)),(''),(''),'Scanvas','Scanvas','');")
        out.line("FILE_SCHEMA(('\(schema.rawValue)'));")
        out.line("ENDSEC;")
        out.line("DATA;")

        let person = add("IFCPERSON($,$,'',$,$,$,$,$)")
        let org = add("IFCORGANIZATION($,'Scanvas',$,$,$)")
        let po = add("IFCPERSONANDORGANIZATION(#\(person),#\(org),$)")
        let app = add("IFCAPPLICATION(#\(org),'1.0','Scanvas','Scanvas')")
        ownerHistory = add("IFCOWNERHISTORY(#\(po),#\(app),$,.ADDED.,$,#\(po),#\(app),\(Int(Date().timeIntervalSince1970)))")

        origin3D = add("IFCCARTESIANPOINT((0.,0.,0.))")
        origin2D = add("IFCCARTESIANPOINT((0.,0.))")
        zAxis = add("IFCDIRECTION((0.,0.,1.))")
        xAxis = add("IFCDIRECTION((1.,0.,0.))")
        identity = add("IFCAXIS2PLACEMENT3D(#\(origin3D),#\(zAxis),#\(xAxis))")
        let context = add("IFCGEOMETRICREPRESENTATIONCONTEXT($,'Model',3,1.E-05,#\(identity),$)")
        bodyContext = add("IFCGEOMETRICREPRESENTATIONSUBCONTEXT('Body','Model',*,*,*,*,#\(context),$,.MODEL_VIEW.,$)")

        let units = [
            add("IFCSIUNIT(*,.LENGTHUNIT.,$,.METRE.)"),
            add("IFCSIUNIT(*,.AREAUNIT.,$,.SQUARE_METRE.)"),
            add("IFCSIUNIT(*,.VOLUMEUNIT.,$,.CUBIC_METRE.)"),
            add("IFCSIUNIT(*,.PLANEANGLEUNIT.,$,.RADIAN.)"),
        ]
        let unitAssignment = add("IFCUNITASSIGNMENT((\(refs(units))))")
        let project = add("IFCPROJECT(\(guid()),#\(ownerHistory),\(str(projectName)),$,$,$,$,(#\(context)),#\(unitAssignment))")

        let sitePlacement = add("IFCLOCALPLACEMENT($,#\(identity))")
        let site = add("IFCSITE(\(guid()),#\(ownerHistory),'Site',$,$,#\(sitePlacement),$,$,.ELEMENT.,$,$,$,$,$)")
        let buildingPlacement = add("IFCLOCALPLACEMENT(#\(sitePlacement),#\(identity))")
        let building = add("IFCBUILDING(\(guid()),#\(ownerHistory),'Building',$,$,#\(buildingPlacement),$,$,.ELEMENT.,$,$,$)")
        storeyPlacement = add("IFCLOCALPLACEMENT(#\(buildingPlacement),#\(identity))")
        storey = add("IFCBUILDINGSTOREY(\(guid()),#\(ownerHistory),'Level 1',$,$,#\(storeyPlacement),$,$,.ELEMENT.,0.)")
        add("IFCRELAGGREGATES(\(guid()),#\(ownerHistory),$,$,#\(project),(#\(site)))")
        add("IFCRELAGGREGATES(\(guid()),#\(ownerHistory),$,$,#\(site),(#\(building)))")
        add("IFCRELAGGREGATES(\(guid()),#\(ownerHistory),$,$,#\(building),(#\(storey)))")
    }

    /// Writes the spatial containment and closes the file.
    func finish() {
        if !contained.isEmpty {
            add("IFCRELCONTAINEDINSPATIALSTRUCTURE(\(guid()),#\(ownerHistory),'Storey contents',$,(\(refs(contained))),#\(storey))")
        }
        out.line("ENDSEC;")
        out.line("END-ISO-10303-21;")
        out.close()
    }

    func contain(_ element: Int) { contained.append(element) }

    @discardableResult
    func add(_ entity: String) -> Int {
        let id = nextID
        nextID += 1
        out.write("#\(id)=\(entity);\n")
        return id
    }

    // MARK: Geometry helpers

    func point(_ p: SIMD3<Float>) -> Int { add("IFCCARTESIANPOINT((\(num(p.x)),\(num(p.y)),\(num(p.z))))") }
    func point(_ p: SIMD2<Float>) -> Int { add("IFCCARTESIANPOINT((\(num(p.x)),\(num(p.y))))") }

    /// A placement relative to the storey at `origin`, rotated by `yaw` around Z.
    func placement(origin: SIMD3<Float>, yaw: Float) -> Int {
        let pt = point(origin)
        let dir = add("IFCDIRECTION((\(num(cos(yaw), 1e6)),\(num(sin(yaw), 1e6)),0.))")
        let axes = add("IFCAXIS2PLACEMENT3D(#\(pt),#\(zAxis),#\(dir))")
        return add("IFCLOCALPLACEMENT(#\(storeyPlacement),#\(axes))")
    }

    /// A box extruded up from its placement: `width` along local X, `depth` along local Y, centred on the origin.
    func boxShape(width: Float, depth: Float, height: Float) -> Int {
        let pos = add("IFCAXIS2PLACEMENT2D(#\(origin2D),$)")
        let profile = add("IFCRECTANGLEPROFILEDEF(.AREA.,$,#\(pos),\(num(max(width, 0.001))),\(num(max(depth, 0.001))))")
        let solid = add("IFCEXTRUDEDAREASOLID(#\(profile),#\(identity),#\(zAxis),\(num(max(height, 0.001))))")
        let rep = add("IFCSHAPEREPRESENTATION(#\(bodyContext),'Body','SweptSolid',(#\(solid)))")
        return add("IFCPRODUCTDEFINITIONSHAPE($,$,(#\(rep)))")
    }

    /// A polygon extruded up by `height`.
    func prismShape(_ polygon: [SIMD2<Float>], height: Float) -> Int {
        var pts = polygon.map { point($0) }
        pts.append(pts[0])
        let poly = add("IFCPOLYLINE((\(refs(pts))))")
        let profile = add("IFCARBITRARYCLOSEDPROFILEDEF(.AREA.,$,#\(poly))")
        let solid = add("IFCEXTRUDEDAREASOLID(#\(profile),#\(identity),#\(zAxis),\(num(height)))")
        let rep = add("IFCSHAPEREPRESENTATION(#\(bodyContext),'Body','SweptSolid',(#\(solid)))")
        return add("IFCPRODUCTDEFINITIONSHAPE($,$,(#\(rep)))")
    }

    /// IFC4 triangulated mesh (positions already in IFC coordinates).
    func meshShape(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> Int {
        var coords = ""
        coords.reserveCapacity(positions.count * 30)
        for (i, p) in positions.enumerated() {
            if i > 0 { coords += "," }
            coords += "(\(num(p.x)),\(num(p.y)),\(num(p.z)))"
        }
        let list = add("IFCCARTESIANPOINTLIST3D((\(coords)))")
        var tris = ""
        tris.reserveCapacity(indices.count * 8)
        for t in 0..<(indices.count / 3) {
            if t > 0 { tris += "," }
            tris += "(\(indices[3 * t] + 1),\(indices[3 * t + 1] + 1),\(indices[3 * t + 2] + 1))"
        }
        let faces = add("IFCTRIANGULATEDFACESET(#\(list),$,$,(\(tris)),$)")
        let rep = add("IFCSHAPEREPRESENTATION(#\(bodyContext),'Body','Tessellation',(#\(faces)))")
        return add("IFCPRODUCTDEFINITIONSHAPE($,$,(#\(rep)))")
    }

    // MARK: Text helpers

    func str(_ s: String) -> String {
        let ascii = s.unicodeScalars.map { $0.isASCII && $0.value >= 32 ? String($0) : "_" }.joined()
        return "'" + ascii.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }

    func refs(_ ids: [Int]) -> String { ids.map { "#\($0)" }.joined(separator: ",") }

    /// A new IFC GlobalId (a UUID in IFC's 22-character base-64 form), quoted.
    func guid(_ uuid: UUID = UUID()) -> String { "'" + Self.compress(uuid) + "'" }

    static func compress(_ uuid: UUID) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$")
        let u = uuid.uuid
        let b = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15].map { UInt32($0) }
        var s = ""
        func emit(_ value: UInt32, _ digits: Int) {
            for k in stride(from: digits - 1, through: 0, by: -1) { s.append(chars[Int((value >> (6 * UInt32(k))) & 63)]) }
        }
        emit(b[0], 2)
        for i in stride(from: 1, to: 16, by: 3) { emit(b[i] << 16 | b[i + 1] << 8 | b[i + 2], 4) }
        return s
    }
}

enum IFCExport {
    /// Room plan → IFC2X3 with walls (with real door/window voids), doors, windows, a floor slab and furniture.
    static func room(_ plan: PlanModel, name: String, to url: URL) throws {
        let ifc = try IFCWriter(url: url, schema: .ifc2x3, projectName: name)
        let oh = ifc.ownerHistory
        var wallIDs: [UUID: Int] = [:]

        for wall in plan.walls {
            let t = max(wall.size.y, plan.wallThickness)
            let place = ifc.placement(origin: SIMD3(wall.center2D, wall.bottom), yaw: wall.yaw)
            let shape = ifc.boxShape(width: wall.size.x, depth: t, height: wall.size.z)
            let id = ifc.add("IFCWALL(\(ifc.guid(wall.id)),#\(oh),'Wall',$,$,#\(place),#\(shape),$)")
            ifc.contain(id)
            wallIDs[wall.id] = id
        }

        for wall in plan.walls {
            guard let wallID = wallIDs[wall.id] else { continue }
            let t = max(wall.size.y, plan.wallThickness)
            for g in plan.gaps(in: wall) {
                let e = g.element
                let w = g.to - g.from, h = g.top - g.bottom
                guard w > 0.05, h > 0.05 else { continue }
                let mid = wall.center2D + wall.axis * ((g.from + g.to) / 2)
                let base = SIMD3(mid, wall.bottom + g.bottom)
                // Opening that cuts the wall.
                let op = ifc.add("IFCOPENINGELEMENT(\(ifc.guid()),#\(oh),'Opening',$,$,#\(ifc.placement(origin: base, yaw: wall.yaw)),#\(ifc.boxShape(width: w, depth: t + 0.1, height: h)),$)")
                ifc.add("IFCRELVOIDSELEMENT(\(ifc.guid()),#\(oh),$,$,#\(wallID),#\(op))")
                // The door or window that fills it.
                let fill: Int
                switch e.kind {
                case .door:
                    fill = ifc.add("IFCDOOR(\(ifc.guid(e.id)),#\(oh),'Door',$,$,#\(ifc.placement(origin: base, yaw: wall.yaw)),#\(ifc.boxShape(width: w, depth: 0.05, height: h)),$,\(num(h)),\(num(w)))")
                case .window:
                    fill = ifc.add("IFCWINDOW(\(ifc.guid(e.id)),#\(oh),'Window',$,$,#\(ifc.placement(origin: base, yaw: wall.yaw)),#\(ifc.boxShape(width: w, depth: 0.05, height: h)),$,\(num(h)),\(num(w)))")
                default:
                    continue
                }
                ifc.add("IFCRELFILLSELEMENT(\(ifc.guid()),#\(oh),$,$,#\(op),#\(fill))")
                ifc.contain(fill)
            }
        }

        for (i, outline) in plan.outlines.enumerated() where outline.count >= 3 {
            let ccw = Geometry.polygonArea(outline) >= 0 ? outline : Array(outline.reversed())
            let place = ifc.placement(origin: SIMD3(0, 0, -0.15), yaw: 0)
            let shape = ifc.prismShape(ccw, height: 0.15)
            let slab = ifc.add("IFCSLAB(\(ifc.guid()),#\(oh),'Floor \(i + 1)',$,$,#\(place),#\(shape),$,.FLOOR.)")
            ifc.contain(slab)
        }

        for obj in plan.objects {
            let place = ifc.placement(origin: SIMD3(obj.center2D, obj.bottom), yaw: obj.yaw)
            let shape = ifc.boxShape(width: obj.size.x, depth: obj.size.y, height: obj.size.z)
            let label = obj.label.capitalized
            let id = ifc.add("IFCFURNISHINGELEMENT(\(ifc.guid(obj.id)),#\(oh),\(ifc.str(label)),$,\(ifc.str(label)),#\(place),#\(shape),$)")
            ifc.contain(id)
        }
        ifc.finish()
    }

    /// Mesh → IFC4 with one building-element proxy per part (e.g. per ARKit class).
    static func mesh(parts: [(String, MeshData)], name: String, floor: Float, to url: URL) throws {
        let ifc = try IFCWriter(url: url, schema: .ifc4, projectName: name)
        let place = ifc.placement(origin: .zero, yaw: 0)
        for (partName, m) in parts where !m.isEmpty {
            let pts = m.positions.map { MeshData.toCAD($0, floor: floor) }
            let shape = ifc.meshShape(pts, m.indices)
            let id = ifc.add("IFCBUILDINGELEMENTPROXY(\(ifc.guid()),#\(ifc.ownerHistory),\(ifc.str("Scan - " + partName)),$,'Scan mesh',#\(place),#\(shape),$,.NOTDEFINED.)")
            ifc.contain(id)
        }
        ifc.finish()
    }
}
