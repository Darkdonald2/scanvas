import Foundation
import RoomPlan
import simd

/// Converts RoomPlan results into the app's CAD-friendly PlanModel.
enum RoomPlanConverter {
    static func plan(from room: CapturedRoom, wallThickness: Float) -> PlanModel {
        build(walls: room.walls, doors: room.doors, windows: room.windows, openings: room.openings,
              floors: room.floors, objects: room.objects, sections: room.sections, wallThickness: wallThickness)
    }

    static func plan(from structure: CapturedStructure, wallThickness: Float) -> PlanModel {
        build(walls: structure.walls, doors: structure.doors, windows: structure.windows, openings: structure.openings,
              floors: structure.floors, objects: structure.objects, sections: structure.sections, wallThickness: wallThickness)
    }

    static func build(walls: [CapturedRoom.Surface], doors: [CapturedRoom.Surface], windows: [CapturedRoom.Surface],
                      openings: [CapturedRoom.Surface], floors: [CapturedRoom.Surface], objects: [CapturedRoom.Object],
                      sections: [CapturedRoom.Section], wallThickness: Float) -> PlanModel {
        // Floor level in ARKit Y.
        var floorY: Float
        if !floors.isEmpty {
            floorY = floors.map { $0.transform.columns.3.y }.min() ?? 0
        } else {
            floorY = walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0
        }
        if !floorY.isFinite { floorY = 0 }

        func planPoint(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, -p.z, p.y - floorY) }
        func yaw(of t: simd_float4x4) -> Float { atan2(-t.columns.0.z, t.columns.0.x) }
        func position(of t: simd_float4x4) -> SIMD3<Float> { SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z) }

        var model = PlanModel()
        model.wallThickness = wallThickness

        func addSurface(_ s: CapturedRoom.Surface, kind: PlanElement.Kind) {
            var isOpen = false
            if case .door(let open) = s.category { isOpen = open }
            let thickness = kind == .wall ? max(s.dimensions.z, wallThickness) : max(s.dimensions.z, 0.05)
            model.elements.append(PlanElement(
                id: s.identifier, parentID: s.parentIdentifier, kind: kind, label: kind.rawValue,
                center: planPoint(position(of: s.transform)), yaw: yaw(of: s.transform),
                size: SIMD3(s.dimensions.x, thickness, s.dimensions.y), isOpen: isOpen))
        }
        walls.forEach { addSurface($0, kind: .wall) }
        doors.forEach { addSurface($0, kind: .door) }
        windows.forEach { addSurface($0, kind: .window) }
        openings.forEach { addSurface($0, kind: .opening) }

        for o in objects {
            model.elements.append(PlanElement(
                id: o.identifier, parentID: nil, kind: .object, label: label(for: o.category),
                center: planPoint(position(of: o.transform)), yaw: yaw(of: o.transform),
                size: SIMD3(o.dimensions.x, o.dimensions.z, o.dimensions.y)))
        }

        for f in floors {
            var corners = f.polygonCorners
            if corners.count < 3 {
                let w = f.dimensions.x / 2, h = f.dimensions.y / 2
                corners = [SIMD3(-w, -h, 0), SIMD3(w, -h, 0), SIMD3(w, h, 0), SIMD3(-w, h, 0)]
            }
            let poly = corners.map { c -> SIMD2<Float> in
                let w = f.transform * SIMD4(c, 1)
                return SIMD2(w.x, -w.z)
            }
            model.floors.append(poly)
        }

        for s in sections {
            let name = sectionName(s.label)
            guard !name.isEmpty else { continue }
            model.labels.append(PlanLabel(text: name, position: SIMD2(s.center.x, -s.center.z)))
        }
        return model
    }

    static func label(for category: CapturedRoom.Object.Category) -> String {
        let raw = String(describing: category)
        // "washerDryer" → "washer dryer"
        return raw.reduce(into: "") { s, ch in
            if ch.isUppercase { s += " " + ch.lowercased() } else { s.append(ch) }
        }
    }

    static func sectionName(_ label: CapturedRoom.Section.Label) -> String {
        let raw = String(describing: label)
        if raw == "unidentified" { return "" }
        let spaced = raw.reduce(into: "") { s, ch in
            if ch.isUppercase { s += " " + ch.lowercased() } else { s.append(ch) }
        }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
