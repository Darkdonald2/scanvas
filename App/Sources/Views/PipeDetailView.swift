import SwiftUI
import SceneKit
import simd

private struct PhotoSelection: Identifiable { let id: Int }

/// A saved drainage survey: 3D with the scan, plan, annotated photos, and an editable data sheet.
struct PipeDetailView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("units") private var unitsRaw = UnitSystem.metric.rawValue
    let project: ScanProject

    enum Tab: String, CaseIterable { case model = "3D", plan = "Plan", photos = "Photos", data = "Data" }

    @State private var tab: Tab = .model
    @State private var survey = PipeSurvey()
    @State private var scene: SCNScene?
    @State private var section: [(SIMD2<Float>, SIMD2<Float>)] = []
    @State private var viewMode: ViewMode = .outside
    @State private var move: SIMD2<Float> = .zero
    @State private var lift: Float = 0
    @State private var resetToken = 0
    @State private var measuring = false
    @State private var measured: Float?
    @State private var thumbs: [Int: UIImage] = [:]
    @State private var selectedPhoto: PhotoSelection?
    @State private var showExport = false
    @State private var showAlign = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var loading = true
    @State private var errorMessage: String?

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .metric }
    private var current: ScanProject { store.projects.first { $0.id == project.id } ?? project }
    private var folder: URL { store.folder(for: project) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
            ZStack(alignment: .bottom) {
                if loading {
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch tab {
                    case .model:
                        if let scene {
                            SceneViewer(scene: scene, mode: viewMode, floorY: survey.floorY, measuring: measuring,
                                        move: move, lift: lift, resetToken: resetToken) { measured = $0 }
                            modelOverlay
                        }
                    case .plan:
                        FloorPlanView { cg, size in
                            let drawing = PipeDrawing(survey: survey, background: section, title: current.name, units: units)
                            PipePlanRenderer(drawing: drawing, theme: .dark).draw(in: cg, rect: CGRect(origin: .zero, size: size), margin: 30)
                        }
                    case .photos:
                        photoGrid
                    case .data:
                        dataSheet
                    }
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
                    Button { showAlign = true } label: { Label("Align to drawing", systemImage: "scope") }
                    Button { newName = current.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportView(project: current, sectionHeight: 1.2).environmentObject(store)
        }
        .sheet(isPresented: $showAlign) {
            AlignmentView(survey: survey, units: units) { updated in
                survey = updated
                persist()
            }
        }
        .sheet(item: $selectedPhoto) { sel in
            PipePhotoView(index: sel.id, survey: survey, folder: folder, units: units) { caption in
                guard sel.id < survey.photos.count else { return }
                survey.photos[sel.id].caption = caption
                persist(rebuild: false)
            }
        }
        .alert("Rename survey", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { store.rename(current, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this survey?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(current); dismiss() }
        }
        .alert("Problem", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .task { await load() }
    }

    // MARK: 3D

    private var modelOverlay: some View {
        VStack(spacing: 8) {
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
            Text(viewMode == .inside ? "Drag to look · joystick to walk · hold ↑ ↓ to rise or sink" : "Drag to orbit · pinch to zoom")
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
            if measuring {
                Text(measured.map { "Distance: " + units.length($0) } ?? "Tap two points on the model")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            HStack {
                Spacer()
                Button { measuring.toggle(); measured = nil } label: {
                    Image(systemName: "ruler").padding(10)
                        .background(measuring ? Color.accentColor : Color(white: 0.2), in: Circle())
                        .foregroundStyle(measuring ? Color.black : Color.white)
                }
            }
        }
        .padding(12)
    }

    // MARK: Photos

    private var photoGrid: some View {
        Group {
            if survey.photos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "camera").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No photos").font(.headline)
                    Text("Tap the camera button while tracing to take full-resolution photos. The traced pipes are drawn onto them.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(survey.photos.indices, id: \.self) { i in
                            Button { selectedPhoto = PhotoSelection(id: i) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    ZStack {
                                        Color(white: 0.12)
                                        if let img = thumbs[i] {
                                            Image(uiImage: img).resizable().scaledToFill()
                                        } else {
                                            ProgressView()
                                        }
                                    }
                                    .frame(height: 150).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(survey.photos[i].caption.isEmpty ? "Photo \(i + 1)" : survey.photos[i].caption)
                                        .font(.caption).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .task(id: survey.photos.count) { await loadThumbs() }
            }
        }
    }

    private func loadThumbs() async {
        let s = survey, f = folder, u = units
        for i in s.photos.indices where thumbs[i] == nil {
            let img = await Task.detached(priority: .utility) { () -> UIImage? in
                PipePhotoAnnotator.annotate(s.photos[i], survey: s, folder: f, maxSize: 480, units: u)
            }.value
            if let img { thumbs[i] = img }
        }
    }

    // MARK: Data sheet

    private var dataSheet: some View {
        List {
            Section {
                LabeledContent("Total length", value: units.length(survey.totalLength))
                LabeledContent("Points", value: "\(survey.allPoints.count)")
                Picker("Minimum fall", selection: binding(\.minFall)) {
                    ForEach([0.5, 1.0, 1.25, 1.5, 2.0, 2.5] as [Float], id: \.self) { f in
                        Text(String(format: "%.2g%% (1:%.0f)", f, 100 / f)).tag(f)
                    }
                }
                Button { showAlign = true } label: {
                    LabeledContent("Drawing coordinates", value: survey.alignment.isAligned ? "Aligned" : "Not aligned")
                }
            } header: { Text("Survey") } footer: {
                Text("Segments flatter than the minimum fall are flagged orange; segments that rise in the flow direction are flagged red.")
            }

            ForEach(survey.runs) { run in
                runSection(run)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func runSection(_ run: PipeRun) -> some View {
        let segs = run.segments
        let chain = run.chainages
        let map = survey.alignment.mapper(for: survey)
        Section {
            TextField("Name", text: runBinding(run.id, \.name, run.name))
            Picker("System", selection: runBinding(run.id, \.system, run.system)) {
                ForEach(systemCodes(including: run.system), id: \.self) { code in
                    Text(code + (PipeSystem.presets.first { $0.code == code }.map { " · " + $0.name } ?? "")).tag(code)
                }
            }
            Picker("Size", selection: runBinding(run.id, \.diameter, run.diameter)) {
                ForEach(sizes(including: run.diameter), id: \.self) { d in
                    Text(units.diameter(d)).tag(d)
                }
            }
            LabeledContent("Length", value: units.length(run.length))
            LabeledContent("Drop", value: units.length(run.drop))
            LabeledContent("Average fall", value: units.fall(run.averageFall))
            ForEach(run.points.indices, id: \.self) { j in
                let p = run.points[j]
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(j + 1)").font(.caption.monospacedDigit().weight(.bold)).frame(width: 24, alignment: .leading)
                        Menu {
                            ForEach(PipePoint.Kind.allCases, id: \.self) { k in
                                Button { setKind(run.id, p.id, k) } label: { Label(k.title, systemImage: k.symbol) }
                            }
                        } label: {
                            Label(p.kind.title, systemImage: p.kind.symbol).font(.subheadline)
                        }
                        Spacer()
                        let m = map(p.position)
                        Text(String(format: "IL %+.3f", m.z - Double(run.diameter) / 2))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("Chainage \(units.length(chain[j])) · \(units.length(p.position.y - survey.floorY)) above floor")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if j < segs.count {
                        let s = segs[j]
                        let st = s.status(minFall: survey.minFall)
                        Text("↓ " + units.length(s.length) + (st == .vertical ? " vertical" : " · fall " + units.fall(s.fallPercent) + " · " + units.gradient(s.gradient)))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(PipeTracer.statusSwiftUI(st))
                    }
                }
            }
            Button { reverse(run.id) } label: { Label("Reverse flow direction", systemImage: "arrow.left.arrow.right") }
            Button(role: .destructive) { deleteRun(run.id) } label: { Label("Delete run", systemImage: "trash") }
        } header: {
            HStack {
                Circle().fill(color(run.system)).frame(width: 10, height: 10)
                Text("\(run.name) · \(units.diameter(run.diameter))")
            }
        }
    }

    private func systemCodes(including code: String) -> [String] {
        var codes = PipeSystem.presets.map { $0.code }
        if !codes.contains(code) { codes.insert(code, at: 0) }
        return codes
    }

    private func sizes(including d: Float) -> [Float] {
        var all = (units == .metric ? PipeSize.metric : PipeSize.imperial).map { $0.1 }
        if !all.contains(d) { all.append(d); all.sort() }
        return all
    }

    private func color(_ code: String) -> Color {
        let c = PipeSystem.color(code)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    // MARK: Editing

    private func binding<T>(_ kp: WritableKeyPath<PipeSurvey, T>) -> Binding<T> {
        Binding(get: { survey[keyPath: kp] }, set: { survey[keyPath: kp] = $0; persist() })
    }

    private func runBinding<T>(_ id: UUID, _ kp: WritableKeyPath<PipeRun, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { survey.runs.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in
                    guard let i = survey.runs.firstIndex(where: { $0.id == id }) else { return }
                    survey.runs[i][keyPath: kp] = v
                    persist()
                })
    }

    private func setKind(_ run: UUID, _ point: UUID, _ kind: PipePoint.Kind) {
        guard let i = survey.runs.firstIndex(where: { $0.id == run }),
              let j = survey.runs[i].points.firstIndex(where: { $0.id == point }) else { return }
        survey.runs[i].points[j].kind = kind
        persist()
    }

    private func reverse(_ run: UUID) {
        guard let i = survey.runs.firstIndex(where: { $0.id == run }) else { return }
        survey.runs[i].points.reverse()
        persist()
    }

    private func deleteRun(_ run: UUID) {
        survey.runs.removeAll { $0.id == run }
        persist()
    }

    /// Saves the survey and refreshes the 3D pipes.
    private func persist(rebuild: Bool = true) {
        do {
            let data = try JSONEncoder().encode(survey)
            try data.write(to: folder.appendingPathComponent(ProjectFile.pipes), options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
        var p = current
        if p.summary != survey.summary {
            p.summary = survey.summary
            store.save(p)
        }
        if rebuild, let scene {
            scene.rootNode.childNode(withName: "Pipes", recursively: false)?.removeFromParentNode()
            scene.rootNode.addChildNode(PipeGeometry.node(for: survey))
            thumbs = [:]
        }
    }

    // MARK: Stats and loading

    private var stats: some View {
        HStack(spacing: 14) {
            Label("\(survey.runs.count) run\(survey.runs.count == 1 ? "" : "s")", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            Label(units.length(survey.totalLength), systemImage: "ruler")
            Label("\(survey.photos.count)", systemImage: "camera")
            let bad = survey.runs.flatMap { $0.segments }.filter { [.flat, .backfall].contains($0.status(minFall: survey.minFall)) }.count
            if bad > 0 {
                Label("\(bad) to check", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.1))
    }

    private func load() async {
        let f = folder
        let result = await Task.detached(priority: .userInitiated) { () -> (PipeSurvey?, SCNScene, [(SIMD2<Float>, SIMD2<Float>)], String?) in
            var survey: PipeSurvey?
            var problem: String?
            do { survey = try PipeExport.load(f) } catch { problem = "Could not read the pipe data: \(error.localizedDescription)" }
            var scene = SCNScene()
            var section: [(SIMD2<Float>, SIMD2<Float>)] = []
            let mesh = try? MeshData(contentsOf: f.appendingPathComponent(ProjectFile.mesh))
            if let t = try? TexturedMesh(contentsOf: f.appendingPathComponent(ProjectFile.textured)), !t.pages.isEmpty {
                scene = SceneExport.texturedScene(t, folder: f, dollhouse: true)
            } else if let mesh, !mesh.isEmpty {
                scene = SceneExport.scene(parts: [("Scan", mesh)], dollhouse: true)
            }
            if let mesh, !mesh.isEmpty {
                section = mesh.section(atHeight: 1.2, floor: survey?.floorY ?? mesh.floorHeight)
            }
            if let survey { scene.rootNode.addChildNode(PipeGeometry.node(for: survey)) }
            return (survey, scene, section, problem)
        }.value
        if let s = result.0 { survey = s }
        scene = result.1
        section = result.2
        errorMessage = result.3
        loading = false
    }
}

/// Full-screen photo with the pipes drawn on, zoomable, with an editable caption.
struct PipePhotoView: View {
    let index: Int
    let survey: PipeSurvey
    let folder: URL
    let units: UnitSystem
    var onCaption: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var annotated: UIImage?
    @State private var plain: UIImage?
    @State private var showPipes = true
    @State private var caption = ""
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let img = showPipes ? annotated : plain {
                        Image(uiImage: img).resizable().scaledToFit()
                            .scaleEffect(scale).offset(offset)
                            .gesture(MagnificationGesture()
                                .onChanged { scale = max(1, min(8, lastScale * $0)) }
                                .onEnded { _ in lastScale = scale }
                                .simultaneously(with: DragGesture()
                                    .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width, height: lastOffset.height + $0.translation.height) }
                                    .onEnded { _ in lastOffset = offset }))
                            .onTapGesture(count: 2) { withAnimation { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .clipped()
                Form {
                    Toggle("Draw traced pipes", isOn: $showPipes)
                    TextField("Caption", text: $caption)
                        .onSubmit { onCaption(caption) }
                }
                .frame(height: 140)
            }
            .navigationTitle("Photo \(index + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { onCaption(caption); dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(annotated == nil)
                }
            }
            .sheet(isPresented: $sharing) {
                if let img = showPipes ? annotated : plain { ShareSheet(items: [img]) }
            }
        }
        .task {
            guard index < survey.photos.count else { return }
            var photo = survey.photos[index]
            caption = photo.caption
            let s = survey, f = folder, u = units
            plain = UIImage(contentsOfFile: f.appendingPathComponent(photo.file).path)
            photo.caption = ""
            let p = photo
            annotated = await Task.detached(priority: .userInitiated) {
                PipePhotoAnnotator.annotate(p, survey: s, folder: f, maxSize: 4096, units: u)
            }.value
        }
    }
}

/// Places the survey in an existing drawing's coordinates from one or two known points.
struct AlignmentView: View {
    let survey: PipeSurvey
    let units: UnitSystem
    var onSave: (PipeSurvey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var points: [UUID?] = [nil, nil]
    @State private var xs: [Double] = [0, 0]
    @State private var ys: [Double] = [0, 0]
    @State private var rotation: Double = 0
    @State private var floorLevel: Double = 0

    private struct Choice: Identifiable { let id: UUID; let title: String }

    private var choices: [Choice] {
        survey.runs.flatMap { run in
            run.points.indices.map { j in
                let p = run.points[j]
                return Choice(id: p.id, title: "\(run.name) · point \(j + 1)" + (p.kind == .point ? "" : " (\(p.kind.title))"))
            }
        }
    }

    private var draft: PipeSurvey {
        var s = survey
        s.alignment.references = (0..<2).compactMap { i in
            points[i].map { DrawingAlignment.Reference(point: $0, x: xs[i], y: ys[i]) }
        }
        s.alignment.rotation = rotation
        s.alignment.floorLevel = floorLevel
        return s
    }

    private let numberFormat = FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...4))

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Pick a traced point you can find on your drawing, such as a riser or cleanout, and type its drawing coordinates in metres. With two points, the rotation is worked out for you. The DXF, IFC, CSV and report then use your drawing's coordinates, so the pipes paste straight into it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(0..<2, id: \.self) { i in
                    Section(i == 0 ? "Reference point 1" : "Reference point 2 (sets rotation)") {
                        Picker("Point", selection: $points[i]) {
                            Text("None").tag(UUID?.none)
                            ForEach(choices) { c in Text(c.title).tag(UUID?.some(c.id)) }
                        }
                        if points[i] != nil {
                            LabeledContent("Drawing X") {
                                TextField("X", value: $xs[i], format: numberFormat)
                                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Drawing Y") {
                                TextField("Y", value: $ys[i], format: numberFormat)
                                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                Section {
                    if points[0] == nil || points[1] == nil {
                        LabeledContent("Rotation (°, anticlockwise)") {
                            TextField("0", value: $rotation, format: numberFormat)
                                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Floor level") {
                        TextField("0.000", value: $floorLevel, format: numberFormat)
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                    if let m = draft.alignment.mismatch(in: draft) {
                        LabeledContent("Distance check", value: String(format: "%+.0f mm", m * 1000))
                            .foregroundStyle(abs(m) < 0.05 ? Color.green : Color.orange)
                    }
                } footer: {
                    Text("Distance check compares the measured distance between the two points with your drawing. A few centimetres over a long distance is normal LiDAR drift; a big difference usually means a wrong point or typo.")
                }
                if survey.alignment.isAligned {
                    Section {
                        Button("Remove alignment", role: .destructive) {
                            points = [nil, nil]; rotation = 0
                        }
                    }
                }
            }
            .navigationTitle("Align to drawing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(draft); dismiss() } }
            }
            .onAppear {
                let a = survey.alignment
                for (i, r) in a.references.prefix(2).enumerated() {
                    points[i] = r.point; xs[i] = r.x; ys[i] = r.y
                }
                rotation = a.rotation
                floorLevel = a.floorLevel
            }
        }
    }
}
