import SwiftUI
import RealityKit
import SceneKit

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
    @AppStorage("smoothMesh") private var smoothMesh = true
    @AppStorage("lockExposure") private var lockExposure = true
    @State private var saving = false
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var progress: Double = 0
    @State private var project = ScanProject(name: "", kind: .space)
    var onSaved: (ScanProject) -> Void

    var body: some View {
        ZStack {
            ARViewContainer(arView: scanner.arView).ignoresSafeArea()

            VStack(spacing: 10) {
                HStack {
                    Button("Cancel") { scanner.stop(); try? FileManager.default.removeItem(at: ProjectStore.folder(for: project.id)); dismiss() }
                        .buttonStyle(.bordered).tint(.white)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(scanner.triangleCount.formatted()) triangles").font(.footnote.monospacedDigit().weight(.semibold))
                        Text(timeText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                if scanner.tooFast {
                    Label("Slow down", systemImage: "tortoise.fill").font(.title3.bold())
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.red.opacity(0.9), in: Capsule())
                        .transition(.scale.combined(with: .opacity))
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
                    Text("Processing scan").font(.headline)
                    ProgressView(value: progress).frame(width: 220)
                    Text(status).font(.callout).multilineTextAlignment(.center)
                    Text("Keep the app open.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear {
            scanner.captureColour = captureColour
            scanner.lockExposure = lockExposure
            project.name = store.nextName(for: .space)
            if captureColour {
                let photos = ProjectStore.folder(for: project.id).appendingPathComponent(ProjectFile.keyframes, isDirectory: true)
                try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
                scanner.photoDirectory = photos
            }
            scanner.start()
        }
        .onDisappear { scanner.stop() }
        .animation(.easeInOut(duration: 0.2), value: scanner.tooFast)
        .onChange(of: scanner.tooFast) { _, fast in
            if fast { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
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
        if collected.isEmpty {
            saving = false
            errorMessage = "No mesh was captured yet. Keep scanning for a few seconds, then tap Finish again."
            return
        }
        scanner.stop()
        let project = self.project
        let colour = captureColour
        let smooth = smoothMesh
        let scanner = self.scanner
        Task.detached(priority: .userInitiated) {
            let folder = ProjectStore.folder(for: project.id)
            func report(_ text: String, _ value: Double) {
                Task { @MainActor in status = text; progress = value }
            }
            do {
                let (mesh, thumbScene) = try SpaceProcessing.process(collected, scanner: scanner, folder: folder,
                                                                     smooth: smooth, colour: colour, report: report)
                if let thumb = SceneExport.thumbnail(of: thumbScene) {
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
