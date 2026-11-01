import Foundation
import UIKit
import SceneKit
import simd

/// R12 DXF in double precision, so drawing coordinates like (-15.390, -2409.880) stay exact to the millimetre.
final class PipeDXFWriter {
    private let out: TextFileWriter
    private let k: Double

    init(url: URL, unit: CADUnit, layers: [(String, Int)]) throws {
        out = try TextFileWriter(url: url)
        k = Double(unit.scale)
        pair(0, "SECTION"); pair(2, "HEADER")
        pair(9, "$ACADVER"); pair(1, "AC1009")
        pair(9, "$INSUNITS"); pair(70, "\(unit.dxfCode)")
        pair(0, "ENDSEC")
        pair(0, "SECTION"); pair(2, "TABLES")
        pair(0, "TABLE"); pair(2, "LTYPE"); pair(70, "1")
        pair(0, "LTYPE"); pair(2, "CONTINUOUS"); pair(70, "0"); pair(3, "Solid line"); pair(72, "65"); pair(73, "0"); pair(40, "0.0")
        pair(0, "ENDTAB")
        pair(0, "TABLE"); pair(2, "LAYER"); pair(70, "\(layers.count)")
        for (name, color) in layers {
            pair(0, "LAYER"); pair(2, name); pair(70, "0"); pair(62, "\(color)"); pair(6, "CONTINUOUS")
        }
        pair(0, "ENDTAB")
        pair(0, "TABLE"); pair(2, "STYLE"); pair(70, "1")
        pair(0, "STYLE"); pair(2, "STANDARD"); pair(70, "0"); pair(40, "0.0"); pair(41, "1.0"); pair(50, "0.0"); pair(71, "0"); pair(42, "0.2"); pair(3, "txt"); pair(4, "")
        pair(0, "ENDTAB")
        pair(0, "ENDSEC")
        pair(0, "SECTION"); pair(2, "ENTITIES")
    }

    func finish() {
        pair(0, "ENDSEC"); pair(0, "EOF")
        out.close()
    }

    private func pair(_ code: Int, _ value: String) { out.line(String(code)); out.line(value) }
    private func n(_ x: Double) -> String { String(format: "%.6f", x * k) }
    private func point(_ base: Int, _ p: SIMD3<Double>) {
        pair(base, n(p.x)); pair(base + 10, n(p.y)); pair(base + 20, n(p.z))
    }

    func line(_ a: SIMD3<Double>, _ b: SIMD3<Double>, layer: String) {
        pair(0, "LINE"); pair(8, layer); point(10, a); point(11, b)
    }

    /// 2D polyline at z = 0, or a true 3D polyline.
    func polyline(_ pts: [SIMD3<Double>], threeD: Bool, closed: Bool = false, layer: String) {
        guard pts.count >= 2 else { return }
        pair(0, "POLYLINE"); pair(8, layer); pair(66, "1")
        pair(10, "0.0"); pair(20, "0.0"); pair(30, "0.0")
        pair(70, "\((threeD ? 8 : 0) | (closed ? 1 : 0))")
        for p in pts {
            pair(0, "VERTEX"); pair(8, layer)
            point(10, threeD ? p : SIMD3(p.x, p.y, 0))
            if threeD { pair(70, "32") }
        }
        pair(0, "SEQEND"); pair(8, layer)
    }

    func circle(_ c: SIMD2<Double>, radius: Double, layer: String) {
        pair(0, "CIRCLE"); pair(8, layer); point(10, SIMD3(c, 0)); pair(40, n(radius))
    }

    /// Text centred on `p` (or left-aligned), height in metres, rotation in degrees.
    func text(_ s: String, at p: SIMD2<Double>, height: Double, rotation: Double = 0, centred: Bool = true, layer: String) {
        var clean = s.replacingOccurrences(of: "Ø", with: "%%c").replacingOccurrences(of: "°", with: "%%d")
        clean = clean.unicodeScalars.map { $0.isASCII ? String($0) : "?" }.joined()
        pair(0, "TEXT"); pair(8, layer); point(10, SIMD3(p, 0))
        pair(40, n(height)); pair(1, clean)
        if rotation != 0 { pair(50, String(format: "%.3f", rotation)) }
        if centred { pair(72, "4"); point(11, SIMD3(p, 0)) }
    }
}

enum PipeExport {
    static func load(_ folder: URL) throws -> PipeSurvey {
        try JSONDecoder().decode(PipeSurvey.self, from: Data(contentsOf: folder.appendingPathComponent(ProjectFile.pipes)))
    }

    static func export(project: ScanProject, folder: URL, formats: Set<ExportFormat>, options: ExportOptions,
                       outDir: URL, safeName: String, progress: @escaping (String) -> Void) throws -> [URL] {
        let fm = FileManager.default
        let survey = try load(folder)
        var mesh = try? MeshData(contentsOf: folder.appendingPathComponent(ProjectFile.mesh))
        if options.simplify > 0, let m = mesh {
            progress("Simplifying mesh…")
            mesh = m.simplified(cell: options.simplify)
        }
        var section: [(SIMD2<Float>, SIMD2<Float>)] = []
        if let mesh, !formats.isDisjoint(with: [.pipeDXF, .pipeReport, .pipePNG]) {
            progress("Cutting plan section…")
            section = mesh.section(atHeight: options.sectionHeight, floor: survey.floorY)
        }
        let drawing = PipeDrawing(survey: survey, background: section, title: project.name, units: options.displayUnits)
        let textured: TexturedMesh? = options.simplify == 0
            ? try? TexturedMesh(contentsOf: folder.appendingPathComponent(ProjectFile.textured)) : nil
        let tubes = PipeGeometry.parts(for: survey)
        var urls: [URL] = []

        for format in ExportFormat.allCases where formats.contains(format) {
            let url = outDir.appendingPathComponent(safeName + format.suffix + "." + format.fileExtension)
            try? fm.removeItem(at: url)
            progress("Writing \(format.title)…")
            switch format {
            case .pipeReport:
                try report(survey, drawing: drawing, folder: folder, title: project.name, units: options.displayUnits, to: url)
            case .pipePNG:
                try png(drawing, to: url)
            case .pipeDXF:
                try dxf(survey, drawing: drawing, unit: options.unit, units: options.displayUnits, to: url)
            case .pipeIFC:
                try ifc(survey, name: project.name, to: url)
            case .pipeCSV:
                try csv(survey, units: options.displayUnits).write(to: url, atomically: true, encoding: .utf8)
            case .obj:
                if var t = textured, !t.pages.isEmpty {
                    for (_, m) in tubes { t.untextured.append(m) }
                    let dir = outDir.appendingPathComponent(safeName + "-obj", isDirectory: true)
                    try? fm.removeItem(at: dir)
                    try MeshFormats.texturedOBJ(t, textures: folder, name: safeName, in: dir)
                    let zip = outDir.appendingPathComponent(safeName + "-obj.zip")
                    try? fm.removeItem(at: zip)
                    try Exporter.zipFolder(dir, to: zip)
                    try? fm.removeItem(at: dir)
                    urls.append(zip)
                    continue
                }
                try MeshFormats.obj(parts: scanParts(mesh) + tubes, to: url)
            case .usdz:
                let scene: SCNScene
                if let t = textured, !t.pages.isEmpty {
                    scene = SceneExport.texturedScene(t, folder: folder, dollhouse: false)
                } else {
                    scene = SceneExport.scene(parts: scanParts(mesh))
                }
                scene.rootNode.addChildNode(PipeGeometry.node(for: survey))
                try SceneExport.write(scene, to: url)
            case .glb:
                if var t = textured, !t.pages.isEmpty {
                    for (_, m) in tubes { t.untextured.append(m) }
                    try MeshFormats.texturedGLB(t, textures: folder, to: url)
                } else {
                    try MeshFormats.glb(parts: scanParts(mesh) + tubes, to: url)
                }
            case .ply:
                guard let mesh else { continue }
                var all = mesh
                for (_, m) in tubes { all.append(m) }
                try MeshFormats.ply(all, floor: survey.floorY, to: url)
            case .pts:
                guard let mesh else { continue }
                try MeshFormats.pts(mesh, floor: survey.floorY, to: url)
            default:
                continue
            }
            urls.append(url)
        }
        return urls
    }

    private static func scanParts(_ mesh: MeshData?) -> [(String, MeshData)] {
        guard let mesh, !mesh.isEmpty else { return [] }
        return [("Scan", mesh)]
    }

    // MARK: DXF

    static func dxf(_ survey: PipeSurvey, drawing: PipeDrawing, unit: CADUnit, units: UnitSystem, to url: URL) throws {
        let systems = Array(Set(survey.runs.map { $0.system.uppercased() })).sorted()
        func layer(_ sys: String, _ suffix: String = "") -> String {
            "P-" + String(sys.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }) + suffix
        }
        var layers: [(String, Int)] = []
        for s in systems {
            let c = PipeSystem.dxfColor(s)
            layers += [(layer(s), c), (layer(s, "-3D"), c), (layer(s, "-TEXT"), c)]
        }
        layers += [("P-FITTINGS", 7), ("P-LEVELS", 3), ("P-WARNING", 1), ("SCAN-SECTION", 8)]
        let w = try PipeDXFWriter(url: url, unit: unit, layers: layers)
        let map = survey.alignment.mapper(for: survey)

        for (a, b) in drawing.background {
            w.line(SIMD3(a, 0), SIMD3(b, 0), layer: "SCAN-SECTION")
        }
        for run in survey.runs {
            let pts = run.points.map { map($0.position) }
            let sys = run.system.uppercased()
            let r = Double(run.diameter) / 2
            w.polyline(pts, threeD: false, layer: layer(sys))
            w.polyline(pts, threeD: true, layer: layer(sys, "-3D"))
            let textH = 0.08
            if let first = pts.first {
                w.text("\(run.name) Ø\(Int((run.diameter * 1000).rounded()))", at: SIMD2(first.x, first.y - r - 0.15),
                       height: textH * 1.3, layer: layer(sys, "-TEXT"))
            }
            for (i, s) in run.segments.enumerated() {
                let a = pts[i], b = pts[i + 1]
                let d = SIMD2(b.x - a.x, b.y - a.y)
                let len2 = simd_length(d)
                let status = s.status(minFall: survey.minFall)
                guard len2 > 0.15 else { continue }
                let u = d / len2
                var angle = atan2(u.y, u.x) * 180 / .pi
                if angle > 90 { angle -= 180 } else if angle < -90 { angle += 180 }
                let mid = SIMD2((a.x + b.x) / 2, (a.y + b.y) / 2)
                let normal = SIMD2(-u.y, u.x)
                var label = String(format: "L=%.3f  F=%.1f%%", s.length, s.fallPercent)
                if let g = s.gradient { label += String(format: "  1:%.0f", g) }
                let textLayer = status == .backfall || status == .flat ? "P-WARNING" : layer(sys, "-TEXT")
                w.text(label.replacingOccurrences(of: "%%", with: "%"), at: mid + normal * (r + textH), height: textH,
                       rotation: angle, layer: textLayer)
                // Flow arrow.
                if len2 > 0.4 {
                    let tip = mid + u * 0.09, back = mid - u * 0.06
                    w.polyline([SIMD3(tip, 0), SIMD3(back + normal * 0.05, 0), SIMD3(back - normal * 0.05, 0)],
                               threeD: false, closed: true, layer: layer(sys, "-TEXT"))
                }
            }
            for (i, p) in run.points.enumerated() {
                let q = pts[i]
                let c = SIMD2(q.x, q.y)
                let invert = q.z - r
                w.text(String(format: "IL %+.3f", invert), at: c + SIMD2(r + 0.05, -r - 0.07), height: 0.06, centred: false, layer: "P-LEVELS")
                guard p.kind != .point else { continue }
                let rr = max(r * 1.3, 0.06)
                w.circle(c, radius: rr, layer: "P-FITTINGS")
                switch p.kind {
                case .cleanout:
                    w.line(SIMD3(c.x - rr, c.y, 0), SIMD3(c.x + rr, c.y, 0), layer: "P-FITTINGS")
                    w.line(SIMD3(c.x, c.y - rr, 0), SIMD3(c.x, c.y + rr, 0), layer: "P-FITTINGS")
                case .riser, .drop:
                    let k = rr * 0.7
                    w.line(SIMD3(c.x - k, c.y - k, 0), SIMD3(c.x + k, c.y + k, 0), layer: "P-FITTINGS")
                    w.line(SIMD3(c.x - k, c.y + k, 0), SIMD3(c.x + k, c.y - k, 0), layer: "P-FITTINGS")
                default: break
                }
                let tag = p.label.isEmpty ? p.kind.code : p.kind.code + " " + p.label
                w.text(tag, at: c + SIMD2(rr + 0.04, rr + 0.02), height: 0.07, centred: false, layer: "P-FITTINGS")
            }
        }
        w.finish()
    }

    // MARK: IFC

    static func ifc(_ survey: PipeSurvey, name: String, to url: URL) throws {
        let w = try IFCWriter(url: url, schema: .ifc2x3, projectName: name)
        let map = survey.alignment.mapper(for: survey)
        func f(_ x: Double) -> String {
            let s = String(format: "%.6f", x)
            return s == "-0.000000" ? "0.0" : s
        }
        func dir(_ v: SIMD3<Double>) -> Int { w.add("IFCDIRECTION((\(f(v.x)),\(f(v.y)),\(f(v.z))))") }
        let pos2D = w.add("IFCAXIS2PLACEMENT2D(#\(w.origin2D),$)")
        var bySystem: [String: [Int]] = [:]
        for run in survey.runs {
            let pts = run.points.map { map($0.position) }
            let r = Double(run.diameter) / 2
            let wall = max(0.002, r * 0.06)
            let profile = w.add("IFCCIRCLEHOLLOWPROFILEDEF(.AREA.,\(w.str("DN\(Int((run.diameter * 1000).rounded()))")),#\(pos2D),\(f(r)),\(f(wall)))")
            for (i, s) in run.segments.enumerated() {
                let a = pts[i], b = pts[i + 1]
                let v = b - a
                let len = simd_length(v)
                guard len > 0.005 else { continue }
                let z = v / len
                let helper: SIMD3<Double> = abs(z.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
                let x = simd_normalize(simd_cross(helper, z))
                let origin = w.add("IFCCARTESIANPOINT((\(f(a.x)),\(f(a.y)),\(f(a.z))))")
                let axes = w.add("IFCAXIS2PLACEMENT3D(#\(origin),#\(dir(z)),#\(dir(x)))")
                let placement = w.add("IFCLOCALPLACEMENT(#\(w.storeyPlacement),#\(axes))")
                let solid = w.add("IFCEXTRUDEDAREASOLID(#\(profile),#\(w.identity),#\(w.zAxis),\(f(len)))")
                let rep = w.add("IFCSHAPEREPRESENTATION(#\(w.bodyContext),'Body','SweptSolid',(#\(solid)))")
                let shape = w.add("IFCPRODUCTDEFINITIONSHAPE($,$,(#\(rep)))")
                let segName = "\(run.name) S\(i + 1)"
                let seg = w.add("IFCFLOWSEGMENT(\(w.guid()),#\(w.ownerHistory),\(w.str(segName)),\(w.str(run.system + " pipe")),\(w.str(run.system)),#\(placement),#\(shape),$)")
                w.contain(seg)
                bySystem[run.system, default: []].append(seg)
                var props = [
                    w.add("IFCPROPERTYSINGLEVALUE('System',$,IFCLABEL(\(w.str(run.system))),$)"),
                    w.add("IFCPROPERTYSINGLEVALUE('Run',$,IFCLABEL(\(w.str(run.name))),$)"),
                    w.add("IFCPROPERTYSINGLEVALUE('NominalDiameter',$,IFCPOSITIVELENGTHMEASURE(\(f(Double(run.diameter)))),$)"),
                    w.add("IFCPROPERTYSINGLEVALUE('Length',$,IFCPOSITIVELENGTHMEASURE(\(f(Double(s.length)))),$)"),
                    w.add("IFCPROPERTYSINGLEVALUE('FallPercent',$,IFCREAL(\(f(Double(s.fallPercent)))),$)"),
                    w.add("IFCPROPERTYSINGLEVALUE('InvertLevelStart',$,IFCLENGTHMEASURE(\(f(a.z - r))),$)"),
                    w.add("IFCPROPERTYSINGLEVALUE('InvertLevelEnd',$,IFCLENGTHMEASURE(\(f(b.z - r))),$)"),
                ]
                if s.from.kind != .point {
                    props.append(w.add("IFCPROPERTYSINGLEVALUE('StartFitting',$,IFCLABEL(\(w.str(s.from.kind.title))),$)"))
                }
                if s.to.kind != .point {
                    props.append(w.add("IFCPROPERTYSINGLEVALUE('EndFitting',$,IFCLABEL(\(w.str(s.to.kind.title))),$)"))
                }
                let pset = w.add("IFCPROPERTYSET(\(w.guid()),#\(w.ownerHistory),'Scanvas_PipeSurvey',$,(\(w.refs(props))))")
                w.add("IFCRELDEFINESBYPROPERTIES(\(w.guid()),#\(w.ownerHistory),$,$,(#\(seg)),#\(pset))")
            }
        }
        for (system, segs) in bySystem.sorted(by: { $0.key < $1.key }) {
            let sys = w.add("IFCSYSTEM(\(w.guid()),#\(w.ownerHistory),\(w.str(system)),\(w.str("Drainage")),$)")
            w.add("IFCRELASSIGNSTOGROUP(\(w.guid()),#\(w.ownerHistory),$,$,(\(w.refs(segs))),$,#\(sys))")
        }
        w.finish()
    }

    // MARK: CSV

    static func csv(_ survey: PipeSurvey, units: UnitSystem) -> String {
        let map = survey.alignment.mapper(for: survey)
        var rows = ["Run,System,Diameter (mm),Point,Type,Label,X (m),Y (m),Centre level (m),Invert level (m),Above floor (m),Chainage (m),Length to next (m),Fall to next (%),Gradient,Status"]
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func d(_ x: Double) -> String { String(format: "%.3f", x) }
        for run in survey.runs {
            let segs = run.segments
            let chain = run.chainages
            let r = Double(run.diameter) / 2
            for (i, p) in run.points.enumerated() {
                let m = map(p.position)
                var cols = [q(run.name), q(run.system), String(format: "%.0f", run.diameter * 1000), "\(i + 1)", q(p.kind.title), q(p.label),
                            d(m.x), d(m.y), d(m.z), d(m.z - r), d(Double(p.position.y - survey.floorY)), d(Double(chain[i]))]
                if i < segs.count {
                    let s = segs[i]
                    let status: String
                    switch s.status(minFall: survey.minFall) {
                    case .good: status = "OK"
                    case .flat: status = "Too flat"
                    case .backfall: status = "Back-fall"
                    case .vertical: status = "Vertical"
                    }
                    cols += [d(Double(s.length)), String(format: "%.2f", s.fallPercent), q(units.gradient(s.gradient)), q(status)]
                } else {
                    cols += ["", "", "", ""]
                }
                rows.append(cols.joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: PNG

    static func png(_ drawing: PipeDrawing, to url: URL) throws {
        let size = CGSize(width: 2400, height: 1800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            PipePlanRenderer(drawing: drawing, theme: .print).draw(in: ctx.cgContext, rect: CGRect(origin: .zero, size: size), margin: 140)
            NSAttributedString(string: drawing.title, attributes: [.font: UIFont.boldSystemFont(ofSize: 40)]).draw(at: CGPoint(x: 60, y: 40))
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    // MARK: PDF report

    static func report(_ survey: PipeSurvey, drawing: PipeDrawing, folder: URL, title: String, units: UnitSystem, to url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let margin: CGFloat = 36
        let map = survey.alignment.mapper(for: survey)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { ctx in
            var y: CGFloat = 0
            var pageNo = 0
            func txt(_ s: String, x: CGFloat, size: CGFloat, bold: Bool = false, color: UIColor = .black, width: CGFloat? = nil,
                     advance: Bool = false) {
                let attrs: [NSAttributedString.Key: Any] = [.font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                                                            .foregroundColor: color]
                let str = NSAttributedString(string: s, attributes: attrs)
                if let width {
                    str.draw(with: CGRect(x: x, y: y, width: width, height: size * 1.4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                } else {
                    str.draw(at: CGPoint(x: x, y: y))
                }
                if advance { y += size * 1.45 }
            }
            func newPage() {
                ctx.beginPage()
                pageNo += 1
                y = margin
                txt("\(title) · Drainage survey", x: margin, size: 8, color: .gray)
                txt("Page \(pageNo)", x: page.width - margin - 40, size: 8, color: .gray, advance: true)
                y += 6
            }
            func paragraph(_ s: String, size: CGFloat = 9) {
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.darkGray]
                let str = NSAttributedString(string: s, attributes: attrs)
                let r = str.boundingRect(with: CGSize(width: page.width - 2 * margin, height: 400), options: .usesLineFragmentOrigin, context: nil)
                str.draw(with: CGRect(x: margin, y: y, width: page.width - 2 * margin, height: r.height + 2), options: .usesLineFragmentOrigin, context: nil)
                y += r.height + 6
            }
            func ensure(_ h: CGFloat) { if y + h > page.height - margin { newPage() } }
            func row(_ cols: [(String, CGFloat)], size: CGFloat = 7.5, bold: Bool = false, color: UIColor = .black, shade: Bool = false) {
                ensure(size * 1.6)
                if shade {
                    ctx.cgContext.setFillColor(UIColor(white: 0.93, alpha: 1).cgColor)
                    ctx.cgContext.fill(CGRect(x: margin - 2, y: y - 1, width: page.width - 2 * margin + 4, height: size * 1.5))
                }
                var x = margin
                for (s, w) in cols {
                    txt(s, x: x, size: size, bold: bold, color: color, width: w - 3)
                    x += w
                }
                y += size * 1.5
            }

            // Page 1: summary and plan.
            newPage()
            txt(title, x: margin, size: 20, bold: true, advance: true)
            txt("Drainage survey · " + DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short), x: margin, size: 10, color: .darkGray, advance: true)
            y += 4
            let traced = survey.runs.filter { $0.points.count > 1 }
            var facts = "\(traced.count) run\(traced.count == 1 ? "" : "s"), total \(units.length(survey.totalLength)), "
                + "\(survey.allPoints.count) points, \(survey.photos.count) photos. Minimum fall checked: \(units.fall(survey.minFall)) (1:\(Int(100 / max(survey.minFall, 0.01)))). "
            if survey.alignment.isAligned {
                facts += "Coordinates are aligned to the drawing (metres)"
                if let m = survey.alignment.mismatch(in: survey) { facts += String(format: "; reference check %+.0f mm", m * 1000) }
                facts += ". "
            } else {
                facts += "Coordinates are relative to where the scan started (not aligned to a drawing). "
            }
            facts += "Levels are relative to the floor" + (survey.alignment.floorLevel != 0 ? " at \(units.level(survey.alignment.floorLevel))" : " (0.000)")
                + (survey.floorMeasured ? ", measured on site." : ", detected by LiDAR.")
            facts += " Invert levels assume the pipe's outside diameter; subtract the wall thickness for the true internal invert."
            paragraph(facts)

            let planRect = CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 430)
            let cg = ctx.cgContext
            cg.saveGState()
            cg.clip(to: planRect)
            let scale = PipePlanRenderer(drawing: drawing, theme: .print).draw(in: cg, rect: planRect, margin: 26)
            cg.restoreGState()
            cg.setStrokeColor(UIColor(white: 0.8, alpha: 1).cgColor)
            cg.stroke(planRect)
            // Scale bar.
            let metres: CGFloat = scale > 60 ? 1 : scale > 15 ? 5 : 10
            let bar = metres * scale
            cg.setStrokeColor(UIColor.black.cgColor); cg.setLineWidth(1.5)
            cg.move(to: CGPoint(x: planRect.maxX - 12 - bar, y: planRect.maxY - 12))
            cg.addLine(to: CGPoint(x: planRect.maxX - 12, y: planRect.maxY - 12)); cg.strokePath()
            let saveY = y
            y = planRect.maxY - 26
            txt("\(Int(metres)) m", x: planRect.maxX - 12 - bar, size: 8)
            y = saveY + planRect.height + 8

            // Legend.
            var lx = margin
            for s in Array(Set(survey.runs.map { $0.system })).sorted() {
                cg.setFillColor(PipePlanRenderer.uiColor(PipeSystem.color(s), darken: true).cgColor)
                cg.fill(CGRect(x: lx, y: y + 2, width: 14, height: 5))
                let name = PipeSystem.presets.first { $0.code == s }?.name ?? s
                txt("\(s) \(name)", x: lx + 18, size: 8)
                lx += 110
            }
            y += 14
            lx = margin
            for (st, name) in [(PipeSegment.Status.good, "Fall OK"), (.flat, "Too flat"), (.backfall, "Back-fall"), (.vertical, "Vertical")] {
                cg.setFillColor(PipePlanRenderer.statusColor(st, print: true).cgColor)
                cg.fillEllipse(in: CGRect(x: lx, y: y + 1, width: 7, height: 7))
                txt(name, x: lx + 11, size: 8)
                lx += 80
            }
            y += 18

            // Run summary table.
            let cols: [CGFloat] = [70, 45, 55, 60, 55, 55, 60, 123]
            row(zip(["Run", "System", "Size", "Length", "Drop", "Avg fall", "Gradient", "Check"], cols).map { ($0, $1) }, bold: true, shade: true)
            for run in survey.runs {
                let st = run.status(minFall: survey.minFall)
                let check: String
                switch st {
                case .good: check = "OK"
                case .flat: check = "Some segments too flat"
                case .backfall: check = "Back-fall found"
                case .vertical: check = "Vertical"
                }
                let g = run.drop > 0.0005 ? String(format: "1:%.0f", run.segments.reduce(0) { $0 + $1.planLength } / run.drop) : "–"
                row(zip([run.name, run.system, units.diameter(run.diameter), units.length(run.length), units.length(run.drop),
                         units.fall(run.averageFall), g, check], cols).map { ($0, $1) },
                    color: st == .good ? .black : PipePlanRenderer.statusColor(st, print: true))
            }

            // Detailed tables per run.
            for run in survey.runs where !run.points.isEmpty {
                newPage()
                txt("\(run.name) · \(run.system) · \(units.diameter(run.diameter))", x: margin, size: 14, bold: true, advance: true)
                txt("Length \(units.length(run.length)) · drop \(units.length(run.drop)) · average fall \(units.fall(run.averageFall))",
                    x: margin, size: 9, color: .darkGray, advance: true)
                y += 6
                txt("Points (flow order)", x: margin, size: 10, bold: true, advance: true)
                let pc: [CGFloat] = [24, 80, 70, 75, 75, 60, 60, 79]
                row(zip(["#", "Type", "Label", "X", "Y", "Centre", "Invert", "Chainage"], pc).map { ($0, $1) }, bold: true, shade: true)
                let chain = run.chainages
                let r = Double(run.diameter) / 2
                for (i, p) in run.points.enumerated() {
                    let m = map(p.position)
                    row(zip(["\(i + 1)", p.kind.title, p.label, String(format: "%.3f", m.x), String(format: "%.3f", m.y),
                             String(format: "%+.3f", m.z), String(format: "%+.3f", m.z - r), units.length(chain[i])], pc).map { ($0, $1) })
                }
                y += 8
                txt("Segments", x: margin, size: 10, bold: true, advance: true)
                let sc: [CGFloat] = [44, 62, 62, 55, 55, 55, 55, 135]
                row(zip(["Seg", "Length", "Plan len.", "Drop", "Fall", "1:X", "Bearing", "Status"], sc).map { ($0, $1) }, bold: true, shade: true)
                for (i, s) in run.segments.enumerated() {
                    let st = s.status(minFall: survey.minFall)
                    let status: String
                    switch st {
                    case .good: status = "OK"
                    case .flat: status = "Too flat (< \(units.fall(survey.minFall)))"
                    case .backfall: status = "Back-fall: rises with flow"
                    case .vertical: status = "Vertical drop"
                    }
                    let bearing = (Double(s.bearing) - survey.alignment.angle(for: survey) * 180 / .pi).truncatingRemainder(dividingBy: 360)
                    row(zip(["\(i + 1)–\(i + 2)", units.length(s.length), units.length(s.planLength), units.length(s.drop),
                             units.fall(s.fallPercent), units.gradient(s.gradient), String(format: "%.0f°", bearing < 0 ? bearing + 360 : bearing), status], sc).map { ($0, $1) },
                        color: st == .good || st == .vertical ? .black : PipePlanRenderer.statusColor(st, print: true))
                }
            }

            // Photos, two per page, with the pipes drawn on.
            if !survey.photos.isEmpty {
                let boxH = (page.height - 2 * margin - 60) / 2
                for (i, photo) in survey.photos.enumerated() {
                    if i % 2 == 0 {
                        newPage()
                        txt(i == 0 ? "Photos" : "Photos (continued)", x: margin, size: 14, bold: true, advance: true)
                        y += 4
                    }
                    autoreleasepool {
                        guard let img = PipePhotoAnnotator.annotate(photo, survey: survey, folder: folder, maxSize: 1400, units: units),
                              let jpeg = img.jpegData(compressionQuality: 0.72), let small = UIImage(data: jpeg) else { return }
                        let box = CGRect(x: margin, y: y, width: page.width - 2 * margin, height: boxH - 22)
                        let s = min(box.width / small.size.width, box.height / small.size.height)
                        let w = small.size.width * s, h = small.size.height * s
                        small.draw(in: CGRect(x: box.midX - w / 2, y: box.minY, width: w, height: h))
                        y += h + 4
                        var caption = "Photo \(i + 1)"
                        if !photo.caption.isEmpty { caption += " · " + photo.caption }
                        if let t = photo.target {
                            let m = map(t)
                            caption += String(format: " · aimed at X %.3f, Y %.3f", m.x, m.y)
                        }
                        txt(caption, x: margin, size: 8, color: .darkGray, advance: true)
                        y = max(y, box.minY + boxH - 8)
                    }
                }
            }
        }
    }
}
