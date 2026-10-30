import SwiftUI
import UIKit

struct ExportView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("units") private var unitsRaw = UnitSystem.metric.rawValue
    @AppStorage("cadUnit") private var cadUnitRaw = CADUnit.millimetres.rawValue
    let project: ScanProject
    var sectionHeight: Float

    @State private var selected: Set<ExportFormat> = ExportFormat.defaults
    @State private var simplify: Float = 0
    @State private var colorByClass = false
    @State private var splitByClass = true
    @State private var working = false
    @State private var status = ""
    @State private var results: [URL] = []
    @State private var errorMessage: String?
    @State private var sharing = false

    private var formats: [ExportFormat] {
        ExportFormat.available(for: project.kind, hasRoomPlanUSDZ: store.has(ProjectFile.roomUSDZ, in: project))
    }

    var body: some View {
        NavigationStack {
            Form {
                if !results.isEmpty {
                    Section {
                        ForEach(results, id: \.self) { url in
                            HStack {
                                Image(systemName: "doc.fill").foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).font(.subheadline)
                                    Text(fileSize(url)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button { sharing = true } label: { Label("Share / Save to Files", systemImage: "square.and.arrow.up") }
                    } header: { Text("Exported") } footer: {
                        Text("Also saved in the Files app under On My iPhone › Scanvas › Exports.")
                    }
                }

                Section("Formats") {
                    ForEach(formats) { f in
                        Toggle(isOn: Binding(get: { selected.contains(f) }, set: { on in if on { selected.insert(f) } else { selected.remove(f) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title)
                                Text(f.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Picker("CAD units (DXF)", selection: $cadUnitRaw) {
                        ForEach(CADUnit.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if project.kind != .room {
                        Picker("Mesh detail", selection: $simplify) {
                            Text("Full").tag(Float(0))
                            Text("High (2 cm)").tag(Float(0.02))
                            Text("Medium (5 cm)").tag(Float(0.05))
                            Text("Low (10 cm)").tag(Float(0.10))
                        }
                    }
                    if project.kind == .space {
                        Toggle("Colour by surface type", isOn: $colorByClass)
                        Toggle("Separate walls, floor, ceiling…", isOn: $splitByClass)
                        LabeledContent("Plan section height", value: UnitSystem(rawValue: unitsRaw)?.length(sectionHeight) ?? "")
                    }
                } header: { Text("Options") } footer: {
                    Text(project.kind == .space
                         ? "Big scans make big CAD files. Use Medium or Low detail for DXF/IFC if AutoCAD or Revit feels slow. Change the section height on the Plan tab."
                         : "Revit: open the IFC, or Insert › Import CAD for the DXF. AutoCAD: open the DXF directly.")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { run() }.disabled(selected.isEmpty || working)
                }
            }
            .overlay {
                if working {
                    VStack(spacing: 12) { ProgressView(); Text(status).font(.callout) }
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $sharing) { ShareSheet(items: results) }
            .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func run() {
        working = true
        status = "Preparing…"
        var options = ExportOptions()
        options.unit = CADUnit(rawValue: cadUnitRaw) ?? .millimetres
        options.displayUnits = UnitSystem(rawValue: unitsRaw) ?? .metric
        options.simplify = simplify
        options.sectionHeight = sectionHeight
        options.colorByClass = colorByClass
        options.splitByClass = splitByClass
        let chosen = selected.intersection(formats)
        let folder = store.folder(for: project)
        let project = self.project
        Task.detached(priority: .userInitiated) {
            do {
                let urls = try Exporter.export(project: project, folder: folder, formats: chosen, options: options) { s in
                    Task { @MainActor in status = s }
                }
                await MainActor.run { results = urls; working = false; sharing = true }
            } catch {
                await MainActor.run { working = false; errorMessage = error.localizedDescription }
            }
        }
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
