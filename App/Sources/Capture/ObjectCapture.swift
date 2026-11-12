import SwiftUI
import RealityKit
import PhotosUI
import UniformTypeIdentifiers
import SceneKit

/// On-device photogrammetry (Apple Object Capture): photos → textured USDZ.
enum Photogrammetry {
    static var isSupported: Bool { PhotogrammetrySession.isSupported }

    static func reconstruct(images: URL, checkpoint: URL?, output: URL, progress: @escaping (Double) -> Void) async throws {
        var config = PhotogrammetrySession.Configuration()
        if let checkpoint { config.checkpointDirectory = checkpoint }
        let session = try PhotogrammetrySession(input: images, configuration: config)
        try session.process(requests: [.modelFile(url: output, detail: .reduced)])
        for try await out in session.outputs {
            switch out {
            case .requestProgress(_, let fraction):
                progress(fraction)
            case .requestError(_, let error):
                throw error
            case .processingComplete:
                return
            case .processingCancelled:
                throw CancellationError()
            default:
                break
            }
        }
    }

    /// Builds the project files (mesh, thumbnail, info) once `model.usdz` exists in the folder.
    @MainActor
    static func finishProject(_ project: ScanProject, store: ProjectStore) async throws -> ScanProject {
        let folder = store.folder(for: project)
        let model = folder.appendingPathComponent(ProjectFile.model)
        let saved: ScanProject = try await Task.detached(priority: .userInitiated) {
            let mesh = try SceneExport.meshData(fromModelAt: model)
            try mesh.write(to: folder.appendingPathComponent(ProjectFile.mesh))
            if let scene = try? SCNScene(url: model, options: nil), let thumb = SceneExport.thumbnail(of: scene) {
                try? thumb.write(to: folder.appendingPathComponent(ProjectFile.thumbnail))
            }
            var p = project
            let size = mesh.bounds.max - mesh.bounds.min
            let units = UnitSystem.current
            p.summary = "\(units.length(size.x)) × \(units.length(size.z)) × \(units.length(size.y))"
            return p
        }.value
        // Photos are no longer needed once the model is built.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(ProjectFile.images))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(ProjectFile.checkpoint))
        store.save(saved)
        return saved
    }
}

// MARK: - Guided capture

@MainActor
final class ObjectCaptureModel: ObservableObject {
    @Published var state: ObjectCaptureSession.CaptureState = .initializing
    @Published var shots = 0
    @Published var feedback: [String] = []
    @Published var passComplete = false
    @Published var processing = false
    @Published var progress: Double = 0
    @Published var step = "Building 3D model"
    @Published var errorMessage: String?

    /// Released before the model is built: Apple's capture session holds the camera and a lot of memory, and
    /// building the model alongside it can stall or get the app closed.
    @Published private(set) var session: ObjectCaptureSession?
    let project: ScanProject
    private var timer: Timer?
    private var listener: Task<Void, Never>?

    init(project: ScanProject) { self.project = project }

    func start(store: ProjectStore) {
        guard session == nil else { return }
        let folder = store.folder(for: project)
        let images = folder.appendingPathComponent(ProjectFile.images, isDirectory: true)
        let checkpoint = folder.appendingPathComponent(ProjectFile.checkpoint, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't make a folder for the photos: \(error.localizedDescription)"
            return
        }
        let session = ObjectCaptureSession()
        self.session = session
        // Listen before starting, so no change of state is missed.
        listener = Task { [weak self] in
            for await s in session.stateUpdates {
                self?.state = s
            }
        }
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpoint
        config.isOverCaptureEnabled = true
        do {
            try session.start(imagesDirectory: images, configuration: config)
        } catch {
            errorMessage = "The camera couldn't start Object Capture: \(error.localizedDescription)"
            return
        }
        // Also read the state directly twice a second, in case an update is ever missed.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let session else { return }
        shots = session.numberOfShotsTaken
        passComplete = session.userCompletedScanPass
        feedback = session.feedback.compactMap(Self.message).sorted()
        if !Self.same(session.state, state) { state = session.state }
    }

    private static func same(_ a: ObjectCaptureSession.CaptureState, _ b: ObjectCaptureSession.CaptureState) -> Bool {
        switch (a, b) {
        case (.initializing, .initializing), (.ready, .ready), (.detecting, .detecting), (.capturing, .capturing),
             (.finishing, .finishing), (.completed, .completed), (.failed, .failed):
            return true
        default:
            return false
        }
    }

    private static func message(_ f: ObjectCaptureSession.Feedback) -> String? {
        switch f {
        case .objectTooClose: return "Move back a little"
        case .objectTooFar: return "Move closer to the object"
        case .movingTooFast: return "Move more slowly"
        case .environmentLowLight: return "More light would help"
        case .environmentTooDark: return "Too dark to capture"
        case .outOfFieldOfView: return "Point the camera at the object"
        case .overCapturing: return "This side is done, move on"
        default: return nil
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        listener?.cancel(); listener = nil
    }

    func cancel() {
        stop()
        session?.cancel()
        session = nil
    }

    func process(store: ProjectStore) async -> ScanProject? {
        stop()
        session = nil                      // release the camera and its memory before building
        processing = true
        ProcessingMonitor.begin()
        ProcessingMonitor.stage("Object Capture: building the model")
        let folder = store.folder(for: project)
        let images = folder.appendingPathComponent(ProjectFile.images, isDirectory: true)
        let count = ((try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []).filter { !$0.hasPrefix(".") }.count
        guard count >= 10 else {
            processing = false
            ProcessingMonitor.end()
            errorMessage = "Only \(count) photos were saved, which isn't enough to build a model. Try again and walk all the way round the object."
            return nil
        }
        do {
            step = "Building 3D model from \(count) photos"
            try await Photogrammetry.reconstruct(
                images: images,
                checkpoint: folder.appendingPathComponent(ProjectFile.checkpoint, isDirectory: true),
                output: folder.appendingPathComponent(ProjectFile.model)) { p in
                    Task { @MainActor in self.progress = p }
                }
            step = "Saving"
            ProcessingMonitor.stage("Object Capture: saving")
            let saved = try await Photogrammetry.finishProject(project, store: store)
            ProcessingMonitor.end()
            return saved
        } catch {
            ProcessingMonitor.end()
            processing = false
            errorMessage = "Building the model failed: \(error.localizedDescription)"
            return nil
        }
    }
}

struct ObjectCaptureFlowView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ObjectCaptureModel
    var onSaved: (ScanProject) -> Void

    init(project: ScanProject, onSaved: @escaping (ScanProject) -> Void) {
        _model = StateObject(wrappedValue: ObjectCaptureModel(project: project))
        self.onSaved = onSaved
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.processing {
                ProcessingView(progress: model.progress, title: model.step)
            } else {
                if let session = model.session {
                    ObjectCaptureView(session: session).ignoresSafeArea()
                }
                VStack(spacing: 10) {
                    HStack {
                        Button("Cancel") { cancel() }.buttonStyle(.bordered).tint(.white)
                        Spacer()
                        if model.shots > 0 {
                            Text("\(model.shots) photos").font(.footnote.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .padding()
                    ForEach(model.feedback, id: \.self) { text in
                        Label(text, systemImage: "exclamationmark.circle.fill").font(.callout.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.orange.opacity(0.9), in: Capsule())
                    }
                    Spacer()
                    controls.padding(.bottom, 30)
                }
            }
        }
        .onAppear {
            do { _ = try store.makeFolder(for: model.project) } catch { model.errorMessage = error.localizedDescription }
            model.start(store: store)
        }
        .onDisappear { model.stop() }
        .onChange(of: isCompleted) { _, done in
            guard done else { return }
            Task {
                if let saved = await model.process(store: store) { onSaved(saved); dismiss() }
            }
        }
        .alert("Object Capture", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { cancel() }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var isCompleted: Bool {
        if case .completed = model.state { return true }
        return false
    }

    @ViewBuilder private var controls: some View {
        switch model.state {
        case .initializing:
            HStack(spacing: 10) { ProgressView().tint(.white); Text("Starting the camera…") }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .ready:
            VStack(spacing: 10) {
                hint("Point the camera at the object, then tap Continue.")
                bigButton("Continue", "viewfinder") { _ = model.session?.startDetecting() }
            }
        case .detecting:
            VStack(spacing: 10) {
                hint("Adjust the box around the object, then tap Start capture.")
                bigButton("Start capture", "camera.fill") { _ = model.session?.startCapturing() }
                Button("Reset box") { _ = model.session?.resetDetection() }.buttonStyle(.bordered).tint(.white)
            }
        case .capturing:
            VStack(spacing: 10) {
                hint(model.passComplete
                     ? "Round complete. Tap New pass to go round again higher or lower, or Finish."
                     : "Walk slowly all the way round the object. Photos are taken automatically.")
                HStack {
                    Button("New pass") { _ = model.session?.beginNewScanPass() }.buttonStyle(.bordered).tint(.white)
                    bigButton("Finish", "checkmark.circle.fill") { _ = model.session?.finish() }
                        .disabled(model.shots < 10)
                }
            }
        case .finishing:
            HStack(spacing: 10) { ProgressView().tint(.white); Text("Saving photos…") }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let error):
            VStack(spacing: 10) {
                Text("Object Capture stopped: \(error.localizedDescription)").multilineTextAlignment(.center)
                    .padding().background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                Button("Close") { cancel() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        default:
            EmptyView()
        }
    }

    private func bigButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: 220) }
            .buttonStyle(.borderedProminent).controlSize(.large)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).multilineTextAlignment(.center)
            .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
    }

    private func cancel() {
        model.cancel()
        store.delete(model.project)
        dismiss()
    }
}

// MARK: - Photos → 3D

struct PhotosTo3DView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PhotosPickerItem] = []
    @State private var working = false
    @State private var status = ""
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    var onSaved: (ScanProject) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if working {
                    ProcessingView(progress: progress, title: status)
                } else {
                    Image(systemName: "photo.stack").font(.system(size: 56)).foregroundStyle(.tint)
                    Text("Turn photos into a 3D model").font(.title2.bold())
                    Text("Pick 20–200 overlapping photos taken all around an object or small scene. Processing runs on your iPhone and can take several minutes.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
                    PhotosPicker(selection: $items, maxSelectionCount: 300, matching: .images) {
                        Label(items.isEmpty ? "Choose photos" : "\(items.count) photos selected", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    Button { Task { await run() } } label: {
                        Label("Build model", systemImage: "cube.fill").frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(items.count < 10)
                }
            }
            .padding()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(working) } }
            .alert("Could not build model", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func run() async {
        working = true
        let project = ScanProject(name: store.nextName(for: .object), kind: .object)
        do {
            let folder = try store.makeFolder(for: project)
            let images = folder.appendingPathComponent(ProjectFile.images, isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            for (i, item) in items.enumerated() {
                status = "Importing photo \(i + 1) of \(items.count)…"
                progress = Double(i) / Double(items.count)
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                try data.write(to: images.appendingPathComponent(String(format: "IMG_%04d.%@", i, ext)))
            }
            status = "Building 3D model…"
            progress = 0
            try await Photogrammetry.reconstruct(images: images, checkpoint: nil,
                                                 output: folder.appendingPathComponent(ProjectFile.model)) { p in
                Task { @MainActor in progress = p }
            }
            status = "Finishing…"
            let saved = try await Photogrammetry.finishProject(project, store: store)
            onSaved(saved)
            dismiss()
        } catch {
            store.delete(project)
            working = false
            errorMessage = error.localizedDescription
        }
    }
}

struct ProcessingView: View {
    var progress: Double
    var title: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress).progressViewStyle(.linear).frame(maxWidth: 260)
            Text(title).font(.headline)
            Text("\(Int(progress * 100))%").font(.title.monospacedDigit().bold())
            Text("Keep the app open.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(30)
    }
}
