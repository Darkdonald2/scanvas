import SwiftUI
import RoomPlan
import ARKit

/// Drives RoomPlan's RoomCaptureView. Several rooms can be scanned in one session and are merged into one plan.
final class RoomScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    enum Phase { case scanning, processing, reviewing }

    @Published var phase: Phase = .scanning
    @Published var rooms: [CapturedRoom] = []
    @Published var errorMessage: String?

    let arSession = ARSession()
    private(set) lazy var captureView: RoomCaptureView = {
        let view = RoomCaptureView(frame: .zero, arSession: arSession)
        view.delegate = self
        return view
    }()

    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}

    func start() {
        phase = .scanning
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Ends the current room; the AR session keeps running so the next room lines up with this one.
    func finishRoom() {
        phase = .processing
        captureView.captureSession.stop(pauseARSession: false)
    }

    func cancel() {
        captureView.captureSession.stop()
        arSession.pause()
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async {
            if let error { self.errorMessage = error.localizedDescription }
            self.rooms.append(processedResult)
            self.phase = .reviewing
        }
    }
}

private struct RoomCaptureContainer: UIViewRepresentable {
    let controller: RoomScanController
    func makeUIView(context: Context) -> RoomCaptureView { controller.captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct RoomScanView: View {
    @EnvironmentObject private var store: ProjectStore
    @StateObject private var controller = RoomScanController()
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wallThickness") private var wallThickness = 0.12
    @State private var saving = false
    var onSaved: (ScanProject) -> Void

    var body: some View {
        ZStack {
            RoomCaptureContainer(controller: controller).ignoresSafeArea()

            VStack {
                HStack {
                    Button("Cancel") { controller.cancel(); dismiss() }
                        .buttonStyle(.bordered).tint(.white)
                    Spacer()
                    if !controller.rooms.isEmpty {
                        Text("\(controller.rooms.count) room\(controller.rooms.count == 1 ? "" : "s") captured")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding()
                Spacer()
                controls.padding(.bottom, 30)
            }
            if saving {
                ProgressView("Building model…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear { controller.start() }
        .alert("Scan problem", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(controller.errorMessage ?? "") }
    }

    @ViewBuilder private var controls: some View {
        switch controller.phase {
        case .scanning:
            Button { controller.finishRoom() } label: {
                Label("Done with this room", systemImage: "checkmark.circle.fill").frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        case .processing:
            ProgressView("Processing room…")
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .reviewing:
            VStack(spacing: 12) {
                Button { save() } label: {
                    Label("Save scan", systemImage: "square.and.arrow.down.fill").frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { controller.start() } label: {
                    Label("Scan another room", systemImage: "plus.square.on.square").frame(maxWidth: 280)
                }
                .buttonStyle(.bordered).controlSize(.large).tint(.white)
            }
            .disabled(saving)
        }
    }

    private func save() {
        saving = true
        let rooms = controller.rooms
        let thickness = Float(wallThickness)
        let project = ScanProject(name: store.nextName(for: .room), kind: .room)
        Task {
            do {
                let folder = try store.makeFolder(for: project)
                var plan: PlanModel
                // Merging also aligns rooms scanned in one session; it works for a single room too.
                if let structure = try? await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms) {
                    plan = RoomPlanConverter.plan(from: structure, wallThickness: thickness)
                    try? structure.export(to: folder.appendingPathComponent(ProjectFile.roomUSDZ))
                } else {
                    plan = RoomPlanConverter.plan(from: rooms[0], wallThickness: thickness)
                    for extra in rooms.dropFirst() {
                        let p = RoomPlanConverter.plan(from: extra, wallThickness: thickness)
                        plan.elements += p.elements; plan.floors += p.floors; plan.labels += p.labels
                    }
                }
                try JSONEncoder().encode(plan).write(to: folder.appendingPathComponent(ProjectFile.plan))
                if let raw = try? JSONEncoder().encode(rooms) {
                    try? raw.write(to: folder.appendingPathComponent(ProjectFile.rooms))
                }
                let parts = PlanMesher.parts(plan)
                if let thumb = SceneExport.thumbnail(of: SceneExport.scene(parts: parts)) {
                    try? thumb.write(to: folder.appendingPathComponent(ProjectFile.thumbnail))
                }
                var saved = project
                saved.summary = plan.summary + " · " + UnitSystem.current.area(plan.floorArea)
                store.save(saved)
                controller.cancel()
                saving = false
                onSaved(saved)
                dismiss()
            } catch {
                saving = false
                controller.errorMessage = "Could not save: \(error.localizedDescription)"
            }
        }
    }
}
