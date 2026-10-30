import SwiftUI
import RealityKit

private struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Scans spaces of any size as a LiDAR mesh (whole floors, warehouses, outdoor areas).
struct MeshScanView: View {
    @EnvironmentObject private var store: ProjectStore
    @StateObject private var scanner = MeshScanner()
    @Environment(\.dismiss) private var dismiss
    @AppStorage("captureColour") private var captureColour = true
    @State private var saving = false
    @State private var status = ""
    @State private var errorMessage: String?
    var onSaved: (ScanProject) -> Void

    var body: some View {
        ZStack {
            ARViewContainer(arView: scanner.arView).ignoresSafeArea()

            VStack(spacing: 10) {
                HStack {
                    Button("Cancel") { scanner.stop(); dismiss() }
                        .buttonStyle(.bordered).tint(.white)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(scanner.triangleCount.formatted()) triangles").font(.footnote.monospacedDigit().weight(.semibold))
                        Text(timeText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                if let msg = scanner.trackingMessage {
                    Text(msg).font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.orange.opacity(0.85), in: Capsule())
                }
                Spacer()
                if !saving {
                    Text("Walk slowly and sweep walls, floor and ceiling. LiDAR reaches about 5 m, so keep moving through large spaces.")
                        .font(.footnote).multilineTextAlignment(.center)
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    Button { finish() } label: {
                        Label("Finish scan", systemImage: "stop.circle.fill").frame(maxWidth: 280)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(scanner.triangleCount == 0)
                }
            }
            .padding()

            if saving {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(status).font(.callout)
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear {
            scanner.captureColour = captureColour
            scanner.start()
        }
        .onDisappear { scanner.stop() }
        .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var timeText: String {
        let s = Int(scanner.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func finish() {
        saving = true
        status = "Collecting mesh…"
        let collected = scanner.collectMesh()
        scanner.stop()
        let project = ScanProject(name: store.nextName(for: .space), kind: .space)
        let colour = captureColour
        let scanner = self.scanner
        Task.detached(priority: .userInitiated) {
            var mesh = collected
            do {
                if colour {
                    await MainActor.run { status = "Colouring mesh…" }
                    scanner.colourize(&mesh) { p in
                        Task { @MainActor in status = "Colouring mesh… \(Int(p * 100))%" }
                    }
                }
                scanner.clearKeyframes()
                let folder = ProjectStore.folder(for: project.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try mesh.write(to: folder.appendingPathComponent(ProjectFile.mesh))
                let preview = mesh.triangleCount > 300_000 ? mesh.simplified(cell: 0.05) : mesh
                if let thumb = SceneExport.thumbnail(of: SceneExport.scene(parts: [("Scan", preview)])) {
                    try? thumb.write(to: folder.appendingPathComponent(ProjectFile.thumbnail))
                }
                let b = mesh.bounds
                let size = b.max - b.min
                var saved = project
                let units = UnitSystem.current
                saved.summary = "\(mesh.triangleCount.formatted()) triangles · \(units.length(size.x)) × \(units.length(size.z))"
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
