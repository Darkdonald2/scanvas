import SwiftUI
import RealityKit
import SceneKit

private struct PipeARContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Drainage survey: trace pipes point by point with LiDAR while the area is scanned and photographed.
struct PipeSurveyView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tracer = PipeTracer()
    @AppStorage("captureColour") private var captureColour = true
    @AppStorage("smoothMesh") private var smoothMesh = true
    @AppStorage("lockExposure") private var lockExposure = true
    @AppStorage("pipeShowMesh") private var showMesh = true
    @State private var project = ScanProject(name: "", kind: .pipe)
    @State private var saving = false
    @State private var status = ""
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var confirmCancel = false
    var onSaved: (ScanProject) -> Void

    private var units: UnitSystem { UnitSystem.current }
    private var scanner: MeshScanner { tracer.scanner }

    var body: some View {
        ZStack {
            PipeARContainer(arView: scanner.arView).ignoresSafeArea()

            // Labels pinned to the pipes.
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(tracer.labels) { l in
                    Text(l.text)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(l.color.opacity(0.9), in: Capsule())
                        .position(l.point)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            reticle.ignoresSafeArea().allowsHitTesting(false)

            if !saving {
                VStack(spacing: 8) {
                    topBar
                    banners
                    Spacer()
                    readout
                    controls
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    Text("Processing survey").font(.headline)
                    ProgressView(value: progress).frame(width: 220)
                    Text(status).font(.callout).multilineTextAlignment(.center)
                    Text("Keep the app open.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear(perform: start)
        .onDisappear { scanner.stop() }
        .onChange(of: scanner.tooFast) { _, fast in
            if fast { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
        .onChange(of: showMesh) { _, on in scanner.showMesh = on }
        .confirmationDialog("Discard this survey?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { cancel() }
        }
        .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: Pieces

    private var reticle: some View {
        let colour: Color = tracer.edgeStep > 0 ? .yellow : tracer.hud.steady ? .green : .white
        return ZStack {
            Circle().stroke(colour, lineWidth: 2).frame(width: 34, height: 34)
            Circle().fill(colour).frame(width: 5, height: 5)
            ForEach(0..<4) { i in
                Rectangle().fill(colour).frame(width: 2, height: 9)
                    .offset(y: -24)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            if tracer.sizing { ProgressView().tint(.yellow).offset(y: 34) }
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") {
                if tracer.survey.allPoints.isEmpty { cancel() } else { confirmCancel = true }
            }
            .buttonStyle(.bordered).tint(.white)
            Spacer()
            runMenu
            Spacer()
            Button("Finish") { finish() }
                .buttonStyle(.borderedProminent)
                .disabled(tracer.survey.allPoints.isEmpty && scanner.triangleCount == 0)
        }
    }

    private var runMenu: some View {
        Menu {
            Section("Pipe size") {
                Button { tracer.startSizing() } label: { Label("Detect size with LiDAR", systemImage: "scope") }
                Button { tracer.startEdges() } label: { Label("Tap both edges", systemImage: "arrow.left.and.right") }
                let sizes = units == .metric ? PipeSize.metric : PipeSize.imperial
                ForEach(0..<sizes.count, id: \.self) { i in
                    let size = sizes[i]
                    Button {
                        tracer.setDiameter(size.1)
                    } label: {
                        if abs(tracer.run.diameter - size.1) < 0.0005 { Label(size.0, systemImage: "checkmark") } else { Text(size.0) }
                    }
                }
            }
            Section("New run") {
                ForEach(0..<PipeSystem.presets.count, id: \.self) { i in
                    let p = PipeSystem.presets[i]
                    Button("\(p.code) · \(p.name)") { tracer.newRun(system: p.code) }
                }
            }
            if tracer.survey.runs.count > 1 {
                Section("Continue run") {
                    ForEach(tracer.survey.runs.indices, id: \.self) { i in
                        let r = tracer.survey.runs[i]
                        Button {
                            tracer.select(run: i)
                        } label: {
                            if i == tracer.currentRun { Label(r.name, systemImage: "checkmark") } else { Text("\(r.name) · \(r.points.count) pts") }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(systemColor(tracer.run.system)).frame(width: 10, height: 10)
                Text(tracer.run.name).font(.subheadline.weight(.semibold))
                Text(units.diameter(tracer.run.diameter)).font(.caption.monospacedDigit())
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder private var banners: some View {
        if scanner.tooFast {
            Label("Slow down", systemImage: "tortoise.fill").font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.red.opacity(0.9), in: Capsule())
        }
        if let msg = scanner.trackingMessage {
            Text(msg).font(.callout.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.orange.opacity(0.85), in: Capsule())
        }
        if let toast = tracer.toast {
            Text(toast).font(.callout.weight(.medium)).multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var readout: some View {
        let h = tracer.hud
        return VStack(alignment: .leading, spacing: 5) {
            if tracer.survey.allPoints.isEmpty && tracer.edgeStep == 0 {
                Text("Aim the circle at the upstream end of the pipe and tap +. Work along it in the direction of flow, adding a point at every bend, junction and change of fall. Stay within about 2–3 m.")
                    .font(.footnote)
            }
            if let len = h.segmentLength, let st = h.segmentStatus {
                HStack(spacing: 8) {
                    Text(units.length(len)).font(.title3.weight(.bold).monospacedDigit())
                    if st == .vertical {
                        Text("Vertical drop").font(.subheadline.weight(.semibold))
                    } else {
                        Text("Fall " + units.fall(h.segmentFall ?? 0)).font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(units.gradient(h.segmentGradient)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(statusText(st)).font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(PipeTracer.statusSwiftUI(st), in: Capsule()).foregroundStyle(.black)
                }
            }
            HStack(spacing: 10) {
                Circle().fill(h.hasAim ? (h.steady ? Color.green : Color.yellow) : Color.red).frame(width: 8, height: 8)
                if h.hasAim {
                    Text(units.length(h.distance) + " away").foregroundStyle(h.distance > 3.5 ? Color.orange : Color.primary)
                    if let f = h.aboveFloor { Text("↑ " + units.length(f) + " above floor") }
                    if let c = h.belowCeiling, c > -0.05 { Text(units.length(max(0, c)) + " below soffit") }
                } else {
                    Text("No LiDAR reading. Move closer.")
                }
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit())
            HStack {
                Text("\(tracer.run.name): \(units.length(h.runLength)) · \(tracer.run.points.count) points")
                Spacer()
                Text("\(tracer.survey.runs.count) run\(tracer.survey.runs.count == 1 ? "" : "s") · \(units.length(tracer.survey.totalLength))")
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            if h.hasAim && h.distance > 3.5 {
                Text("Move closer for accurate points (LiDAR is best within 3 m).").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var controls: some View {
        HStack(alignment: .center) {
            roundButton("arrow.uturn.backward") { tracer.undo() }
                .disabled(tracer.survey.allPoints.isEmpty)
            Spacer()
            Menu {
                ForEach(PipePoint.Kind.allCases, id: \.self) { k in
                    Button { tracer.kind = k } label: { Label(k.title, systemImage: k.symbol) }
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: tracer.kind.symbol).font(.title3)
                    Text(tracer.kind.title).font(.caption2).lineLimit(1)
                }
                .frame(width: 72, height: 56)
                .background(Color(white: 0.15).opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(tracer.kind == .point ? Color.white : Color.yellow)
            }
            Spacer()
            Button { tracer.addPoint() } label: {
                ZStack {
                    Circle().fill(tracer.edgeStep > 0 ? Color.yellow : Color.accentColor).frame(width: 74, height: 74)
                    Image(systemName: "plus").font(.system(size: 32, weight: .bold)).foregroundStyle(.black)
                }
            }
            .accessibilityLabel(tracer.edgeStep > 0 ? "Mark pipe edge" : "Add point")
            Spacer()
            ZStack(alignment: .topTrailing) {
                roundButton("camera.fill") { tracer.takePhoto() }
                if tracer.photosTaken > 0 {
                    Text("\(tracer.photosTaken)").font(.caption2.bold()).padding(4)
                        .background(Color.accentColor, in: Circle()).foregroundStyle(.black)
                        .offset(x: 4, y: -4)
                }
            }
            Spacer()
            Menu {
                Button { tracer.setFloorHere() } label: { Label("Set floor level here", systemImage: "arrow.down.to.line") }
                Button { tracer.setCeilingHere() } label: { Label("Set soffit level here", systemImage: "arrow.up.to.line") }
                Toggle(isOn: $tracer.snapToCentre) { Label("Snap to pipe centre line", systemImage: "scope") }
                Toggle(isOn: $showMesh) { Label("Show scanned mesh", systemImage: "square.grid.3x3") }
                Picker("Minimum fall", selection: $tracer.survey.minFall) {
                    ForEach([0.5, 1.0, 1.5, 2.0, 2.5] as [Float], id: \.self) { f in
                        Text(String(format: "%.1f%% (1:%.0f)", f, 100 / f)).tag(f)
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.title3).frame(width: 52, height: 52)
                    .background(Color(white: 0.15).opacity(0.85), in: Circle()).foregroundStyle(.white)
            }
        }
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).frame(width: 52, height: 52)
                .background(Color(white: 0.15).opacity(0.85), in: Circle()).foregroundStyle(.white)
        }
    }

    private func statusText(_ s: PipeSegment.Status) -> String {
        switch s {
        case .good: return "GOOD FALL"
        case .flat: return "TOO FLAT"
        case .backfall: return "BACK-FALL"
        case .vertical: return "VERTICAL"
        }
    }

    private func systemColor(_ code: String) -> Color {
        let c = PipeSystem.color(code)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    // MARK: Lifecycle

    private func start() {
        project.name = store.nextName(for: .pipe)
        let folder = ProjectStore.folder(for: project.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tracer.folder = folder
        scanner.captureColour = captureColour
        scanner.lockExposure = lockExposure
        scanner.showMesh = showMesh
        if captureColour {
            let photos = folder.appendingPathComponent(ProjectFile.keyframes, isDirectory: true)
            try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            scanner.photoDirectory = photos
        }
        scanner.start()
    }

    private func cancel() {
        scanner.stop()
        try? FileManager.default.removeItem(at: ProjectStore.folder(for: project.id))
        dismiss()
    }

    private func finish() {
        saving = true
        status = "Collecting scan…"
        let collected = scanner.collectMesh()
        scanner.stop()
        tracer.flushPhotos()
        var traced = tracer.survey
        traced.runs.removeAll { $0.points.isEmpty }
        if !traced.floorMeasured, let f = scanner.floorEstimate { traced.floorY = f }
        let base = traced
        let floorDetected = scanner.floorEstimate != nil
        let project = self.project
        let colour = captureColour
        let smooth = smoothMesh
        let scanner = self.scanner
        Task.detached(priority: .userInitiated) {
            let folder = ProjectStore.folder(for: project.id)
            var survey = base
            func report(_ text: String, _ value: Double) {
                Task { @MainActor in status = text; progress = value }
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var scene = SCNScene()
                if !collected.isEmpty {
                    let (mesh, s) = try SpaceProcessing.process(collected, scanner: scanner, folder: folder,
                                                                smooth: smooth, colour: colour, report: report)
                    scene = s
                    if !survey.floorMeasured && !floorDetected { survey.floorY = mesh.floorHeight }
                } else {
                    scanner.clearKeyframes()
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(ProjectFile.keyframes))
                    if !survey.floorMeasured && !floorDetected {
                        survey.floorY = survey.allPoints.map { $0.position.y }.min() ?? 0
                    }
                }
                let data = try JSONEncoder().encode(survey)
                try data.write(to: folder.appendingPathComponent(ProjectFile.pipes), options: .atomic)
                scene.rootNode.addChildNode(PipeGeometry.node(for: survey))
                if let thumb = SceneExport.thumbnail(of: scene) {
                    try? thumb.write(to: folder.appendingPathComponent(ProjectFile.thumbnail))
                }
                var saved = project
                saved.summary = survey.summary
                await MainActor.run {
                    store.save(saved)
                    saving = false
                    onSaved(saved)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    saving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
