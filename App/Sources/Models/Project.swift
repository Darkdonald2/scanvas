import Foundation

/// What kind of capture a project holds.
enum ScanKind: String, Codable, CaseIterable {
    case room      // RoomPlan: walls, doors, windows, furniture
    case space     // LiDAR mesh of any size of space
    case object    // Object Capture / photos → textured model
    case pipe      // Drainage pipe survey: traced runs + LiDAR scan + photos

    var title: String {
        switch self {
        case .room: return "Room"
        case .space: return "Space"
        case .object: return "Object"
        case .pipe: return "Pipes"
        }
    }

    var symbol: String {
        switch self {
        case .room: return "square.split.bottomrightquarter"
        case .space: return "cube.transparent"
        case .object: return "shippingbox"
        case .pipe: return "point.topleft.down.curvedto.point.bottomright.up"
        }
    }
}

struct ScanProject: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: ScanKind
    var created = Date()
    var summary = ""
}

/// The files a project folder can hold. Not every project has every file.
enum ProjectFile {
    static let info = "project.json"
    static let plan = "plan.json"           // PlanModel (rooms)
    static let rooms = "rooms.json"         // raw RoomPlan CapturedRoom array
    static let roomUSDZ = "roomplan.usdz"   // Apple's own parametric model
    static let mesh = "mesh.bin"            // MeshData (spaces, rooms, objects)
    static let model = "model.usdz"         // textured Object Capture model
    static let textured = "textured.bin"    // TexturedMesh (photo-textured spaces) + tex_<n>.jpg
    static let keyframes = "Keyframes"      // photos kept while scanning a space
    static let thumbnail = "thumb.jpg"
    static let images = "Images"            // Object Capture photos
    static let checkpoint = "Checkpoint"
    static let pipes = "pipes.json"         // PipeSurvey
    static let pipePhotos = "PipePhotos"    // full-resolution survey photos
}
