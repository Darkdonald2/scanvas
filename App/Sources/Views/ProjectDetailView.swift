import SwiftUI
import SceneKit

struct ProjectDetailView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("units") private var unitsRaw = UnitSystem.metric.rawValue
    let project: ScanProject

    enum Tab: String, CaseIterable { case model = "3D", plan = "Plan" }
    enum Shading: String, CaseIterable { case colour = "Colour", classes = "Surfaces", wire = "Wireframe" }

    @State private var tab: Tab = .model
    @State private var shading: Shading = .colour
    @State private var plan: PlanModel?
    @State private var mesh: MeshData?
    @State private var textured: TexturedMesh?
    @State private var scene: SCNScene?
    @State private var section: [(SIMD2<Float>, SIMD2<Float>)] = []
    @State private var sectionHeight: Double = 1.2
    @State private var viewMode: ViewMode = .inside
    @State private var floorY: Float = 0
    @State private var move: SIMD2<Float> = .zero
    @State private var lift: Float = 0
    @State private var resetToken = 0
    @State private var measuring = false
    @State private var measured: Float?
    @State private var showExport = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var loading = true

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .metric }
    private var current: ScanProject { store.projects.first { $0.id == project.id } ?? project }

    var body: some View {
        VStack(spacing: 0) {
            if project.kind != .object {
                Picker("View", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
            }
            ZStack(alignment: .bottom) {
                if loading {
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tab == .model, let scene {
                    SceneViewer(scene: scene, mode: project.kind == .object ? .outside : viewMode, floorY: floorY,
                                measuring: measuring, move: move, lift: lift, resetToken: resetToken) { measured = $0 }
                    modelOverlay
                } else if tab == .plan {
                    FloorPlanView(drawing: PlanDrawing(plan: project.kind == .room ? plan : nil, section: section, title: current.name, units: units))
                    if project.kind == .space { sectionControl }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            stats
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(loading)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newName = current.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportView(project: current, sectionHeight: Float(sectionHeight)).environmentObject(store)
        }
        .alert("Rename scan", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { store.rename(current, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this scan?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(current); dismiss() }
        }
        .task { await load() }
        .onChange(of: shading) { _, _ in rebuildScene() }
        .onChange(of: tab) { _, t in if t == .plan && project.kind == .space && section.isEmpty { recomputeSection() } }
    }

    // MARK: Overlays

    private var modelOverlay: some View {
        VStack(spacing: 8) {
            if project.kind != .object {
                HStack {
                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 200)
                    Button { resetToken += 1 } label: {
                        Image(systemName: "arrow.counterclockwise").padding(8).background(Color(white: 0.2), in: Circle())
                    }
                    .foregroundStyle(.white)
                }
                Text(viewMode == .inside ? "Drag to look · joystick to walk · hold ↑ ↓ to rise or sink" : "Drag to orbit · walls nearest you turn see-through")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if viewMode == .inside {
                    HStack(alignment: .bottom) {
                        Joystick(value: $move)
                        Spacer()
                        VStack(spacing: 12) {
                            HoldButton(systemImage: "arrow.up") { lift = $0 ? 1 : 0 }
                            HoldButton(systemImage: "arrow.down") { lift = $0 ? -1 : 0 }
                        }
                    }
                }
            }
            if measuring {
                Text(measured.map { "Distance: " + units.length($0) } ?? "Tap two points on the model")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            HStack {
                if project.kind != .object {
                    Picker("Shading", selection: $shading) {
                        ForEach(Shading.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 260)
                }
                Spacer()
                Button { measuring.toggle(); measured = nil } label: {
                    Image(systemName: "ruler").padding(10)
                        .background(measuring ? Color.accentColor : Color(white: 0.2), in: Circle())
                        .foregroundStyle(measuring ? .black : .white)
                }
            }
        }
        .padding(12)
    }

    private var sectionControl: some View {
        VStack(spacing: 4) {
            Text("Section height " + units.length(Float(sectionHeight))).font(.caption.weight(.semibold))
            Slider(value: $sectionHeight, in: 0.2...3.0, step: 0.05, onEditingChanged: { editing in
                if !editing { recomputeSection() }
            })
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }

    private var stats: some View {
        let items: [(String, String)] = statItems
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.caption2).foregroundStyle(.secondary)
                        Text(item.1).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
    }

    private var statItems: [(String, String)] {
        if let plan, project.kind == .room {
            return [("Floor area", units.area(plan.floorArea)), ("Ceiling", units.length(plan.ceilingHeight)),
                    ("Wall length", units.length(plan.wallLength)), ("Walls", "\(plan.walls.count)"),
                    ("Doors", "\(plan.doors.count)"), ("Windows", "\(plan.windows.count)"), ("Objects", "\(plan.objects.count)")]
        }
        if let mesh {
            let size = mesh.bounds.max - mesh.bounds.min
            return [("Width", units.length(size.x)), ("Depth", units.length(size.z)), ("Height", units.length(size.y)),
                    ("Triangles", mesh.triangleCount.formatted()), ("Vertices", mesh.vertexCount.formatted())]
        }
        return []
    }

    // MARK: Loading

    private func load() async {
        let folder = store.folder(for: project)
        let kind = project.kind
        let result: (PlanModel?, MeshData?, TexturedMesh?) = await Task.detached(priority: .userInitiated) {
            let plan = (try? Data(contentsOf: folder.appendingPathComponent(ProjectFile.plan)))
                .flatMap { try? JSONDecoder().decode(PlanModel.self, from: $0) }
            var mesh: MeshData?
            if kind == .room {
                mesh = plan.map { PlanMesher.combined($0) }
            } else {
                mesh = try? MeshData(contentsOf: folder.appendingPathComponent(ProjectFile.mesh))
            }
            let textured = try? TexturedMesh(contentsOf: folder.appendingPathComponent(ProjectFile.textured))
            return (plan, mesh, textured)
        }.value
        textured = result.2
        plan = result.0
        mesh = result.1
        if project.kind == .space, let m = result.1 { floorY = m.floorHeight }
        if project.kind == .object { viewMode = .outside }
        rebuildScene()
        loading = false
    }

    private func rebuildScene() {
        let folder = store.folder(for: project)
        if project.kind == .object, let s = try? SCNScene(url: folder.appendingPathComponent(ProjectFile.model), options: nil) {
            scene = s
            return
        }
        if let plan, project.kind == .room {
            scene = SceneExport.roomScene(plan, wireframe: shading == .wire,
                                          recolour: shading == .classes ? { recolour($1, name: $0) } : nil)
            return
        }
        if shading == .colour, let textured {
            scene = SceneExport.texturedScene(textured, folder: folder, wireframe: false, dollhouse: true)
            return
        }
        guard var m = mesh else { return }
        // Keep the viewer smooth on very large scans; exports always use full detail.
        if m.triangleCount > 1_500_000 { m = m.simplified(cell: 0.03) }
        if shading == .classes { m = m.colouredByClass() }
        scene = SceneExport.scene(parts: [("Scan", m)], wireframe: shading == .wire, dollhouse: true)
    }

    private func recolour(_ m: MeshData, name: String) -> MeshData {
        var out = m
        let c: SIMD3<UInt8>
        switch name {
        case "Walls": c = MeshClass.wall.color
        case "Floor": c = MeshClass.floor.color
        case "Doors": c = MeshClass.door.color
        case "Windows": c = MeshClass.window.color
        default: c = MeshClass.table.color
        }
        out.colors = Array(repeating: c, count: m.vertexCount)
        return out
    }

    private func recomputeSection() {
        guard let mesh else { return }
        let h = Float(sectionHeight)
        Task.detached(priority: .userInitiated) {
            let segs = mesh.section(atHeight: h, floor: mesh.floorHeight)
            await MainActor.run { section = segs }
        }
    }
}
