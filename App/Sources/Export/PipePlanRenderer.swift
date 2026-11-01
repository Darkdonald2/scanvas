import UIKit
import simd

/// A pipe survey prepared for 2D drawing: everything in drawing coordinates (metres, X right, Y up the page).
struct PipeDrawing {
    struct Point { var p: SIMD2<Double>; var level: Double; var kind: PipePoint.Kind; var label: String }
    struct Run {
        var name: String
        var system: String
        var diameter: Float
        var points: [Point]
        var segments: [PipeSegment]
    }
    var runs: [Run] = []
    var background: [(SIMD2<Double>, SIMD2<Double>)] = []
    var title: String
    var units: UnitSystem
    var minFall: Float
    var aligned: Bool

    init(survey: PipeSurvey, background planSegments: [(SIMD2<Float>, SIMD2<Float>)] = [], title: String, units: UnitSystem) {
        self.title = title
        self.units = units
        minFall = survey.minFall
        aligned = survey.alignment.isAligned
        let map = survey.alignment.mapper(for: survey)
        let (a, t) = survey.alignment.transform(in: survey)
        let c = cos(a), s = sin(a)
        func plan(_ q: SIMD2<Float>) -> SIMD2<Double> {
            let x = Double(q.x), y = Double(q.y)
            return SIMD2(x * c - y * s + t.x, x * s + y * c + t.y)
        }
        background = planSegments.map { (plan($0.0), plan($0.1)) }
        runs = survey.runs.map { r in
            Run(name: r.name, system: r.system, diameter: r.diameter,
                points: r.points.map { p in
                    let q = map(p.position)
                    return Point(p: SIMD2(q.x, q.y), level: q.z, kind: p.kind, label: p.label)
                },
                segments: r.segments)
        }
    }

    var bounds: (SIMD2<Double>, SIMD2<Double>)? {
        var pts = runs.flatMap { $0.points.map { $0.p } }
        if pts.isEmpty { pts = background.flatMap { [$0.0, $0.1] } }
        guard var lo = pts.first else { return nil }
        var hi = lo
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        // Include the scanned walls near the pipes, but don't let far-away scan noise shrink the drawing.
        let pad = max(1.0, simd_length(hi - lo) * 0.15)
        for (a, b) in background {
            for p in [a, b] where p.x > lo.x - pad && p.x < hi.x + pad && p.y > lo.y - pad && p.y < hi.y + pad {
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        return (lo, hi)
    }
}

struct PipePlanRenderer {
    enum Theme { case dark, print }
    var drawing: PipeDrawing
    var theme: Theme

    private var ink: UIColor { theme == .dark ? .white : .black }
    private var faint: UIColor { theme == .dark ? UIColor(white: 0.45, alpha: 1) : UIColor(white: 0.62, alpha: 1) }

    static func uiColor(_ c: SIMD3<Float>, darken: Bool = false) -> UIColor {
        let k: CGFloat = darken ? 0.75 : 1
        return UIColor(red: CGFloat(c.x) * k, green: CGFloat(c.y) * k, blue: CGFloat(c.z) * k, alpha: 1)
    }

    static func statusColor(_ s: PipeSegment.Status, print: Bool) -> UIColor {
        switch s {
        case .good: return print ? UIColor(red: 0.05, green: 0.55, blue: 0.2, alpha: 1) : UIColor(red: 0.3, green: 0.9, blue: 0.45, alpha: 1)
        case .flat: return UIColor(red: 0.95, green: 0.55, blue: 0.05, alpha: 1)
        case .backfall: return UIColor(red: 0.9, green: 0.15, blue: 0.15, alpha: 1)
        case .vertical: return print ? UIColor(red: 0.1, green: 0.4, blue: 0.85, alpha: 1) : UIColor(red: 0.4, green: 0.7, blue: 1, alpha: 1)
        }
    }

    /// Draws the plan to fit `rect`; returns the scale in points per metre.
    @discardableResult
    func draw(in ctx: CGContext, rect: CGRect, margin: CGFloat = 40) -> CGFloat {
        if theme == .dark {
            ctx.setFillColor(UIColor(white: 0.07, alpha: 1).cgColor)
        } else {
            ctx.setFillColor(UIColor.white.cgColor)
        }
        ctx.fill(rect)
        guard case let (lo, hi)? = drawing.bounds else {
            text("No pipes traced", at: CGPoint(x: rect.midX, y: rect.midY), size: 14, color: faint, ctx: ctx)
            return 1
        }
        let area = rect.insetBy(dx: margin, dy: margin)
        let size = simd_max(hi - lo, SIMD2(0.5, 0.5))
        let scale = min(area.width / CGFloat(size.x), area.height / CGFloat(size.y))
        let centre = (lo + hi) / 2
        func pt(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(x: area.midX + CGFloat(p.x - centre.x) * scale, y: area.midY - CGFloat(p.y - centre.y) * scale)
        }

        // Scanned walls and objects (plan section) for context.
        if !drawing.background.isEmpty {
            ctx.setStrokeColor(faint.cgColor)
            ctx.setLineWidth(0.6)
            for (a, b) in drawing.background {
                ctx.move(to: pt(a)); ctx.addLine(to: pt(b))
            }
            ctx.strokePath()
        }

        let font = max(7, min(11, scale * 0.09))
        for run in drawing.runs {
            let colour = Self.uiColor(PipeSystem.color(run.system), darken: theme == .print)
            let width = max(2, min(8, CGFloat(run.diameter) * scale))
            // Pipe.
            if run.points.count > 1 {
                ctx.setStrokeColor(colour.cgColor)
                ctx.setLineWidth(width)
                ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.move(to: pt(run.points[0].p))
                for p in run.points.dropFirst() { ctx.addLine(to: pt(p.p)) }
                ctx.strokePath()
            }
            // Segment labels and flow arrows.
            for (i, s) in run.segments.enumerated() where i + 1 < run.points.count {
                let a = pt(run.points[i].p), b = pt(run.points[i + 1].p)
                let dx = b.x - a.x, dy = b.y - a.y
                let len = hypot(dx, dy)
                let status = s.status(minFall: drawing.minFall)
                let sc = Self.statusColor(status, print: theme == .print)
                if len < 6 {
                    // Vertical (riser/drop): ring.
                    ctx.setStrokeColor(sc.cgColor); ctx.setLineWidth(1.5)
                    ctx.strokeEllipse(in: CGRect(x: a.x - width, y: a.y - width, width: width * 2, height: width * 2))
                    continue
                }
                let ux = dx / len, uy = dy / len
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                if len > 24 {
                    let tip = CGPoint(x: mid.x + ux * 6, y: mid.y + uy * 6)
                    ctx.setFillColor(ink.cgColor)
                    ctx.move(to: tip)
                    ctx.addLine(to: CGPoint(x: mid.x - ux * 5 - uy * 4, y: mid.y - uy * 5 + ux * 4))
                    ctx.addLine(to: CGPoint(x: mid.x - ux * 5 + uy * 4, y: mid.y - uy * 5 - ux * 4))
                    ctx.closePath(); ctx.fillPath()
                }
                if len > 40 {
                    var angle = atan2(dy, dx)
                    if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
                    let label = drawing.units.length(s.length) + "  " + drawing.units.fall(s.fallPercent)
                        + (s.gradient.map { "  1:" + String(format: "%.0f", $0) } ?? "")
                    let off = width / 2 + font * 0.9
                    let lp = CGPoint(x: mid.x + uy * off, y: mid.y - ux * off)
                    text(label, at: lp, size: font, color: sc, angle: angle, bold: true, ctx: ctx)
                }
            }
            // Points and fittings.
            for (i, p) in run.points.enumerated() {
                let c = pt(p.p)
                if p.kind == .point {
                    ctx.setFillColor(colour.cgColor)
                    ctx.fillEllipse(in: CGRect(x: c.x - width * 0.6, y: c.y - width * 0.6, width: width * 1.2, height: width * 1.2))
                } else {
                    let r = max(5, width * 1.2)
                    ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1.2)
                    let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                    ctx.strokeEllipse(in: box)
                    switch p.kind {
                    case .cleanout:
                        ctx.move(to: CGPoint(x: c.x - r, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
                        ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r))
                        ctx.strokePath()
                    case .riser, .drop:
                        let k = r * 0.7
                        ctx.move(to: CGPoint(x: c.x - k, y: c.y - k)); ctx.addLine(to: CGPoint(x: c.x + k, y: c.y + k))
                        ctx.move(to: CGPoint(x: c.x - k, y: c.y + k)); ctx.addLine(to: CGPoint(x: c.x + k, y: c.y - k))
                        ctx.strokePath()
                    case .floorDrain, .gully:
                        ctx.stroke(box.insetBy(dx: r * 0.35, dy: r * 0.35))
                    default: break
                    }
                    let tag = p.label.isEmpty ? p.kind.code : p.kind.code + " " + p.label
                    text(tag, at: CGPoint(x: c.x + r + 2, y: c.y - r - font * 0.3), size: font, color: ink, bold: true, alignLeft: true, ctx: ctx)
                }
                if i == 0 {
                    let tag = "\(run.name)  \(drawing.units.diameter(run.diameter))"
                    text(tag, at: CGPoint(x: c.x, y: c.y + width + font * 1.1), size: font * 1.15, color: colour, bold: true, ctx: ctx)
                }
            }
        }
        return scale
    }

    func text(_ s: String, at p: CGPoint, size: CGFloat, color: UIColor, angle: CGFloat = 0, bold: Bool = false,
              alignLeft: Bool = false, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let b = str.size()
        UIGraphicsPushContext(ctx)
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        str.draw(at: CGPoint(x: alignLeft ? 0 : -b.width / 2, y: -b.height / 2))
        ctx.restoreGState()
        UIGraphicsPopContext()
    }
}

/// Draws the traced pipes onto a survey photo using the camera pose it was taken with.
enum PipePhotoAnnotator {
    static func annotate(_ photo: PipePhoto, survey: PipeSurvey, folder: URL, maxSize: CGFloat = 2000,
                         units: UnitSystem = .current) -> UIImage? {
        guard let source = UIImage(contentsOfFile: folder.appendingPathComponent(photo.file).path) else { return nil }
        let w = CGFloat(photo.width), h = CGFloat(photo.height)
        let k = min(1, maxSize / max(w, h))
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            source.draw(in: CGRect(origin: .zero, size: size))
            let unit = size.width / 400
            func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * k, y: p.y * k) }
            let bounds = CGRect(origin: .zero, size: size)
            cg.setLineCap(.round); cg.setLineJoin(.round)
            for run in survey.runs {
                let colour = PipePlanRenderer.uiColor(PipeSystem.color(run.system))
                for s in run.segments {
                    guard case let (a0, b0)? = photo.project(s.from.position, s.to.position) else { continue }
                    let a = scaled(a0), b = scaled(b0)
                    cg.setStrokeColor(UIColor.black.withAlphaComponent(0.6).cgColor)
                    cg.setLineWidth(unit * 3.2)
                    cg.move(to: a); cg.addLine(to: b); cg.strokePath()
                    cg.setStrokeColor(colour.cgColor)
                    cg.setLineWidth(unit * 2)
                    cg.move(to: a); cg.addLine(to: b); cg.strokePath()
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    if bounds.insetBy(dx: unit * 20, dy: unit * 8).contains(mid) && hypot(b.x - a.x, b.y - a.y) > unit * 30 {
                        let st = s.status(minFall: survey.minFall)
                        let label = st == .vertical ? units.length(s.length) + " drop"
                            : units.length(s.length) + " · " + units.fall(s.fallPercent)
                        badge(label, at: mid, size: unit * 6, fill: PipePlanRenderer.statusColor(st, print: false), ctx: cg)
                    }
                }
                for p in run.points {
                    guard let c0 = photo.project(p.position) else { continue }
                    let c = scaled(c0)
                    guard bounds.contains(c) else { continue }
                    let r = unit * (p.kind == .point ? 2.2 : 3.5)
                    cg.setFillColor(UIColor.white.cgColor)
                    cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    cg.setStrokeColor(colour.cgColor); cg.setLineWidth(unit)
                    cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    if p.kind != .point {
                        badge(p.kind.code + (p.label.isEmpty ? "" : " " + p.label), at: CGPoint(x: c.x, y: c.y - r - unit * 6),
                              size: unit * 6, fill: .white, ctx: cg)
                    }
                }
                if let first = run.points.first, let c0 = photo.project(first.position) {
                    let c = scaled(c0)
                    if bounds.insetBy(dx: unit * 30, dy: unit * 10).contains(c) {
                        badge("\(run.name) \(units.diameter(run.diameter))", at: CGPoint(x: c.x, y: c.y + unit * 10),
                              size: unit * 6.5, fill: colour, ctx: cg)
                    }
                }
            }
            if !photo.caption.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: unit * 8), .foregroundColor: UIColor.white]
                let str = NSAttributedString(string: photo.caption, attributes: attrs)
                let b = str.size()
                cg.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
                cg.fill(CGRect(x: 0, y: size.height - b.height - unit * 6, width: size.width, height: b.height + unit * 6))
                UIGraphicsPushContext(cg)
                str.draw(at: CGPoint(x: unit * 4, y: size.height - b.height - unit * 3))
                UIGraphicsPopContext()
            }
        }
    }

    private static func badge(_ s: String, at p: CGPoint, size: CGFloat, fill: UIColor, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: size), .foregroundColor: UIColor.black]
        let str = NSAttributedString(string: s, attributes: attrs)
        let b = str.size()
        let box = CGRect(x: p.x - b.width / 2 - size * 0.4, y: p.y - b.height / 2 - size * 0.15,
                         width: b.width + size * 0.8, height: b.height + size * 0.3)
        ctx.setFillColor(fill.withAlphaComponent(0.92).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: box, cornerRadius: box.height / 2).cgPath)
        ctx.fillPath()
        UIGraphicsPushContext(ctx)
        str.draw(at: CGPoint(x: p.x - b.width / 2, y: p.y - b.height / 2))
        UIGraphicsPopContext()
    }
}
