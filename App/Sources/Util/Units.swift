import Foundation

enum UnitSystem: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var title: String { self == .metric ? "Metric (m)" : "Imperial (ft/in)" }

    static var current: UnitSystem {
        UnitSystem(rawValue: UserDefaults.standard.string(forKey: "units") ?? "") ?? .metric
    }

    func length(_ metres: Float) -> String {
        switch self {
        case .metric:
            return metres < 1 ? String(format: "%.0f cm", metres * 100) : String(format: "%.2f m", metres)
        case .imperial:
            let totalInches = Double(metres) / 0.0254
            var feet = Int(totalInches / 12)
            var inches = Int((totalInches - Double(feet) * 12).rounded())
            if inches == 12 { feet += 1; inches = 0 }
            return feet == 0 ? "\(inches)\"" : "\(feet)' \(inches)\""
        }
    }

    func area(_ squareMetres: Float) -> String {
        switch self {
        case .metric: return String(format: "%.1f m²", squareMetres)
        case .imperial: return String(format: "%.0f ft²", squareMetres * 10.7639)
        }
    }
}

/// Units written into CAD files (DXF).
enum CADUnit: String, CaseIterable, Identifiable {
    case millimetres, centimetres, metres, inches, feet
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Multiply metres by this to get the unit.
    var scale: Float {
        switch self {
        case .millimetres: return 1000
        case .centimetres: return 100
        case .metres: return 1
        case .inches: return 39.37008
        case .feet: return 3.280840
        }
    }

    /// DXF $INSUNITS code.
    var dxfCode: Int {
        switch self {
        case .millimetres: return 4
        case .centimetres: return 5
        case .metres: return 6
        case .inches: return 1
        case .feet: return 2
        }
    }
}

/// Buffered text output for large export files.
final class TextFileWriter {
    private let handle: FileHandle
    private var buffer = ""

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(1 << 20)
    }

    func write(_ s: String) {
        buffer += s
        if buffer.utf8.count > 1 << 20 { flush() }
    }

    func line(_ s: String) { write(s); write("\n") }

    func flush() {
        if !buffer.isEmpty { handle.write(Data(buffer.utf8)); buffer.removeAll(keepingCapacity: true) }
    }

    func close() { flush(); try? handle.close() }
}

/// Short, locale-independent number text with a decimal point (valid for DXF, OBJ and STEP/IFC).
@inline(__always) func num(_ x: Float, _ decimals: Double = 10000) -> String {
    let v = (Double(x) * decimals).rounded() / decimals
    return v == 0 ? "0.0" : v.description
}
