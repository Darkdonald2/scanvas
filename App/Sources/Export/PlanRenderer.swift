import UIKit
import simd

/// Everything needed to draw a 2D plan: a RoomPlan model and/or a mesh section.
struct PlanDrawing {
    var plan: PlanModel?
    var section: [(SIMD2<Float>, SIMD2<Float>)] = []
    var title = ""
    var units: UnitSystem = .metric

    var bounds: (min: SIMD2<Float>, max: SIMD2<Float>) {
        var pts = section.flatMap { [$0.0, $0.1] }
        if let plan { let b = plan.bounds; pts += [b.min, b.max] }
        return Geometry.bounds(pts.isEmpty ? [.zero, SIMD2(1, 1)] : pts)
    }

    var isEmpty: Bool { (plan?.elements.isEmpty ?? true) && section.isEmpty }
}

/// Draws a plan with Core Graphics, for the in-app plan view, PDF and PNG.
struct PlanRenderer {
    struct Theme {
        var background: UIColor, floor: UIColor, wall: UIColor, door: UIColor, glass: UIColor
        var furniture: UIColor, text: UIColor, dims: UIColor, section: UIColor

        static let dark = Theme(background: UIColor(white: 0.07, alpha: 1), floor: UIColor(white: 0.16, alpha: 1),
                                wall: UIColor(white: 0.92, alpha: 1), door: UIColor.systemOrange, glass: UIColor.systemCyan,
                                furniture: UIColor.systemGreen, text: .white, dims: UIColor.systemYellow,
                                section: UIColor(white: 0.9, alpha: 1))
        static let print = Theme(background: .white, floor: UIColor(white: 0.94, alpha: 1), wall: UIColor(white: 0.1, alpha: 1),
                                 door: UIColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1), glass: UIColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1),
                                 furniture: UIColor(white: 0.45, alpha: 1), text: .black, dims: UIColor(white: 0.25, alpha: 1),
                                 section: .black)
    }

    var drawing: PlanDrawing
    var theme: Theme = .dark

    /// Draws into `rect` of a UIKit-style (Y down) context. Returns points per metre.
    @discardableResult
    func draw(in ctx: CGContext, rect: CGRect, margin: CGFloat = 40) -> CGFloat {
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        ctx.setFillColor(theme.background.cgColor)
        ctx.fill(rect)
        guard !drawing.isEmpty else { return 1 }

        let b = drawing.bounds
        let w = CGFloat(max(b.max.x - b.min.x, 0.5)), h = CGFloat(max(b.max.y - b.min.y, 0.5))
        let inner = rect.insetBy(dx: margin, dy: margin)
        let s = min(inner.width / w, inner.height / h)
        let ox = inner.midX - w * s / 2, oy = inner.midY + h * s / 2
        func pt(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: ox + CGFloat(p.x - b.min.x) * s, y: oy - CGFloat(p.y - b.min.y) * s)
        }
        func path(_ pts: [SIMD2<Float>], closed: Bool = true) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts.map(pt))
            if closed { p.closeSubpath() }
            return p
        }
        let font = max(9, min(max(14, rect.width / 70), s * 0.13))

        // Mesh section.
        if !drawing.section.isEmpty {
            ctx.setStrokeColor(theme.section.cgColor)
            ctx.setLineWidth(max(1, s * 0.02))
            for (a, c) in drawing.section { ctx.move(to: pt(a)); ctx.addLine(to: pt(c)) }
            ctx.strokePath()
        }

        guard let plan = drawing.plan else { return s }

        for outline in plan.outlines {
            ctx.addPath(path(outline)); ctx.setFillColor(theme.floor.cgColor); ctx.fillPath()
        }

        for obj in plan.objects {
            ctx.addPath(path(obj.footprint))
            ctx.setStrokeColor(theme.furniture.cgColor); ctx.setLineWidth(1.2); ctx.strokePath()
            text(obj.label.capitalized, at: pt(obj.center2D), size: font * 0.8, color: theme.furniture)
        }

        for wall in plan.walls {
            let t = max(wall.size.y, plan.wallThickness)
            let n = wall.normal * t / 2
            ctx.setFillColor(theme.wall.cgColor)
            for (from, to) in plan.solidSpans(of: wall) {
                let a = wall.center2D + wall.axis * from, c = wall.center2D + wall.axis * to
                ctx.addPath(path([a - n, c - n, c + n, a + n])); ctx.fillPath()
            }
            for g in plan.gaps(in: wall) {
                let a = wall.center2D + wall.axis * g.from, c = wall.center2D + wall.axis * g.to
                let gw = g.to - g.from
                switch g.element.kind {
                case .door:
                    let hinge = a + n
                    ctx.setStrokeColor(theme.door.cgColor); ctx.setLineWidth(1.5)
                    ctx.move(to: pt(hinge)); ctx.addLine(to: pt(hinge + wall.normal * gw)); ctx.strokePath()
                    // Swing arc (drawn as a polyline to stay correct under the Y flip).
                    ctx.setLineDash(phase: 0, lengths: [3, 3])
                    let arcPts = (0...16).map { i -> SIMD2<Float> in
                        let ang = wall.yaw + Float(i) / 16 * .pi / 2
                        return hinge + SIMD2(cos(ang), sin(ang)) * gw
                    }
                    ctx.addPath(path(arcPts, closed: false)); ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                case .window:
                    ctx.setFillColor(theme.glass.withAlphaComponent(0.35).cgColor)
                    ctx.addPath(path([a - n, c - n, c + n, a + n])); ctx.fillPath()
                    ctx.setStrokeColor(theme.glass.cgColor); ctx.setLineWidth(1.5)
                    ctx.move(to: pt(a)); ctx.addLine(to: pt(c)); ctx.strokePath()
                default:
                    break
                }
            }
            // Length label outside the wall.
            let mid = wall.center2D + wall.normal * (t / 2 + 0.22)
            var angle = -CGFloat(wall.yaw)
            while angle > .pi / 2 { angle -= .pi }
            while angle < -.pi / 2 { angle += .pi }
            text(drawing.units.length(wall.size.x), at: pt(mid), size: font, color: theme.dims, angle: angle)
        }

        if plan.labels.isEmpty {
            for outline in plan.outlines {
                text(drawing.units.area(abs(Geometry.polygonArea(outline))), at: pt(Geometry.centroid(outline)),
                     size: font * 1.2, color: theme.text, bold: true)
            }
        }
        for l in plan.labels { text(l.text, at: pt(l.position), size: font * 1.2, color: theme.text, bold: true) }
        return s
    }

    private func text(_ s: String, at p: CGPoint, size: CGFloat, color: UIColor, angle: CGFloat = 0, bold: Bool = false) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        str.draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2))
        ctx.restoreGState()
    }
}

enum PlanImageExport {
    /// A4 landscape PDF with title, plan, scale bar and totals.
    static func pdf(_ drawing: PlanDrawing, to url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 842, height: 595)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { ctx in
            ctx.beginPage()
            let cg = ctx.cgContext
            let area = CGRect(x: 0, y: 50, width: page.width, height: page.height - 80)
            let s = PlanRenderer(drawing: drawing, theme: .print).draw(in: cg, rect: area, margin: 30)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: page.width, height: 50))
            let title = NSAttributedString(string: drawing.title, attributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.black])
            title.draw(at: CGPoint(x: 30, y: 16))
            var info = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
            if let plan = drawing.plan {
                info += "   ·   Area " + drawing.units.area(plan.floorArea)
                info += "   ·   Ceiling " + drawing.units.length(plan.ceilingHeight)
                info += "   ·   " + plan.summary
            }
            NSAttributedString(string: info, attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray])
                .draw(at: CGPoint(x: 30, y: page.height - 24))
            // Scale bar: 1 m (or 3 ft).
            let metres: CGFloat = drawing.units == .metric ? 1 : 0.9144
            let len = metres * s
            let x0 = page.width - 30 - len, y0 = page.height - 18
            cg.setStrokeColor(UIColor.black.cgColor); cg.setLineWidth(2)
            cg.move(to: CGPoint(x: x0, y: y0)); cg.addLine(to: CGPoint(x: x0 + len, y: y0)); cg.strokePath()
            NSAttributedString(string: drawing.units == .metric ? "1 m" : "3 ft", attributes: [.font: UIFont.systemFont(ofSize: 9)])
                .draw(at: CGPoint(x: x0, y: y0 - 14))
        }
    }

    static func png(_ drawing: PlanDrawing, to url: URL) throws {
        let size = CGSize(width: 2048, height: 2048)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            PlanRenderer(drawing: drawing, theme: .print).draw(in: ctx.cgContext, rect: CGRect(origin: .zero, size: size), margin: 120)
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
}
