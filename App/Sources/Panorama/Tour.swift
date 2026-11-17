import SwiftUI
import ARKit
import simd

// A tour is a set of 360 panoramas ("stops") taken in one tracked session, so the app knows where each one is
// relative to the others. The viewer moves from stop to stop, like a street-level map of a floor.

struct TourStop: Codable, Identifiable {
    var id: Int
    /// Where the stop was taken (ARKit world, metres; y is up).
    var position: [Float]
    /// Extra turn about the vertical axis (radians), from corrections ARKit made after the stop was taken.
    var rotation: Float = 0
    /// The ARKit anchor left at the stop while capturing (used to pick up those corrections).
    var anchor: String?
    var photos = 0
    var stitched = false

    var folderName: String { String(format: "Stops/%02d", id) }
    var point: SIMD3<Float> { SIMD3(position[0], position[1], position[2]) }
    static let panoramaName = "pano.jpg"
}

struct Tour: Codable {
    var version = 1
    var stops: [TourStop] = []

    static func load(_ folder: URL) -> Tour? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ProjectFile.tour)) else { return nil }
        return try? JSONDecoder().decode(Tour.self, from: data)
    }

    func save(_ folder: URL) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: folder.appendingPathComponent(ProjectFile.tour), options: .atomic)
        }
    }

    /// The stops you can step to from stop `i` (indices into `stops`): the ones taken just before and after
    /// it, plus the nearest few others on the same level. There is no knowledge of walls, so a close stop in
    /// the next room may be offered too.
    func links(of i: Int) -> [Int] {
        guard stops.indices.contains(i) else { return [] }
        var out: [Int] = []
        for j in [i - 1, i + 1] where stops.indices.contains(j) && stops[j].stitched { out.append(j) }
        let here = stops[i].point
        let near = stops.indices
            .filter { $0 != i && !out.contains($0) && stops[$0].stitched }
            .map { j -> (Int, Float) in
                let d = stops[j].point - here
                return (j, abs(d.y) < 1.2 ? simd_length(SIMD2(d.x, d.z)) : .greatestFiniteMagnitude)
            }
            .filter { $0.1 < 5 }
            .sorted { $0.1 < $1.1 }
            .prefix(3)
        out.append(contentsOf: near.map { $0.0 })
        return out
    }
}

/// Stitches the stops of a tour.
enum TourBuilder {
    struct Outcome {
        var stitched = 0
        var failed = 0
    }

    /// Stitches every stop that isn't stitched yet (or all of them with `force`).
    static func stitchAll(folder: URL, force: Bool = false, progress: @escaping (Double, String) -> Void) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            var outcome = Outcome()
            guard var tour = Tour.load(folder) else { return outcome }
            ProcessingMonitor.begin()
            defer { ProcessingMonitor.end() }
            let todo = tour.stops.indices.filter { force || !tour.stops[$0].stitched }
            var log = ["Tour, stitched \(Date().formatted())"]
            var thumbnailDone = FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectFile.thumbnail).path) && !force
            for (n, i) in todo.enumerated() {
                let stop = tour.stops[i]
                let dir = folder.appendingPathComponent(stop.folderName, isDirectory: true)
                let label = "Stop \(n + 1) of \(todo.count)"
                autoreleasepool {
                    do {
                        // Every stop is laid out on the same axes (the middle of the picture faces ARKit's -z),
                        // so directions match from one stop to the next.
                        let (image, result) = try PanoramaBuilder.stitch(
                            shots: dir, to: dir.appendingPathComponent(TourStop.panoramaName),
                            width: PanoramaBuilder.tourWidth, centreYaw: 0, refine: true) { f, s in
                                progress((Double(n) + f) / Double(todo.count), "\(label): \(s)")
                            }
                        if !thumbnailDone {
                            PanoramaBuilder.writeThumbnail(image, to: folder.appendingPathComponent(ProjectFile.thumbnail))
                            thumbnailDone = true
                        }
                        tour.stops[i].stitched = true
                        outcome.stitched += 1
                        log.append("stop \(stop.id): " + result.report.summary.replacingOccurrences(of: "\n", with: "; "))
                    } catch {
                        outcome.failed += 1
                        log.append("stop \(stop.id): failed, \(error.localizedDescription)")
                    }
                }
                tour.save(folder)
            }
            try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("processing.txt"), atomically: true, encoding: .utf8)
            return outcome
        }.value
    }
}

/// A small top-down map of the stops. North is ARKit's -z, so a heading of 0 points up.
struct TourMap: View {
    var points: [SIMD2<Float>]            // x, z of every stop
    var current: Int?
    var me: SIMD2<Float>?                 // where the camera is now (while capturing)
    var heading: Double?
    var onTap: ((Int) -> Void)?

    private struct Frame {
        var origin: SIMD2<Float>
        var scale: CGFloat
        var size: CGSize

        init(points: [SIMD2<Float>], size: CGSize) {
            var lo = points.first ?? .zero, hi = lo
            for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            let span = max(hi.x - lo.x, hi.y - lo.y, 2)          // never zoom in closer than 2 m across
            origin = (lo + hi) / 2
            scale = (min(size.width, size.height) - 24) / CGFloat(span)
            self.size = size
        }

        func place(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: size.width / 2 + CGFloat(p.x - origin.x) * scale, y: size.height / 2 + CGFloat(p.y - origin.y) * scale)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let all = points + (me.map { [$0] } ?? [])
            let frame = Frame(points: all, size: geo.size)
            Canvas { ctx, _ in
                if points.count > 1 {
                    var path = Path()
                    path.move(to: frame.place(points[0]))
                    for p in points.dropFirst() { path.addLine(to: frame.place(p)) }
                    ctx.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1.5)
                }
                let eye = me ?? current.flatMap { points.indices.contains($0) ? points[$0] : nil }
                if let eye, let heading {
                    let c = frame.place(eye)
                    var wedge = Path()
                    wedge.move(to: c)
                    wedge.addArc(center: c, radius: 22, startAngle: .radians(heading - .pi / 2 - 0.5),
                                 endAngle: .radians(heading - .pi / 2 + 0.5), clockwise: false)
                    wedge.closeSubpath()
                    ctx.fill(wedge, with: .color(.yellow.opacity(0.45)))
                }
                for (i, p) in points.enumerated() {
                    let c = frame.place(p)
                    let r: CGFloat = i == current ? 6 : 4
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(i == current ? .yellow : .white))
                }
                if let me {
                    let c = frame.place(me)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.yellow), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let onTap else { return }
                var best = -1
                var bestDistance: CGFloat = 28
                for (i, p) in points.enumerated() {
                    let c = frame.place(p)
                    let d = hypot(c.x - location.x, c.y - location.y)
                    if d < bestDistance { bestDistance = d; best = i }
                }
                if best >= 0 { onTap(best) }
            }
        }
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Capture

struct TourCaptureView: View {
    private enum Phase { case walking, capturing, building }

    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PanoramaCaptureModel
    @State private var tour = Tour()
    @State private var phase = Phase.walking
    @State private var quick = true
    @State private var nextID = 0
    @State private var currentID = 0
    @State private var progress = 0.0
    @State private var step = "Stitching"
    @State private var confirmCancel = false
    @State private var ending = false
    /// Kept as state: the screen that presents this one makes a new project value (with a new id) every time
    /// it redraws, and this capture must stay with the one it started with.
    @State private var project: ScanProject
    var onSaved: (ScanProject) -> Void

    init(project: ScanProject, onSaved: @escaping (ScanProject) -> Void) {
        _project = State(initialValue: project)
        self.onSaved = onSaved
        let stops = ProjectStore.folder(for: project.id).appendingPathComponent(ProjectFile.tourStops, isDirectory: true)
        _model = StateObject(wrappedValue: PanoramaCaptureModel(folder: stops))
    }

    private var folder: URL { store.folder(for: project) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if phase == .building {
                ProcessingView(progress: progress, title: step)
            } else {
                PanoARContainer(arView: model.arView).ignoresSafeArea()
                if phase == .capturing { PanoGuide.Reticle(model: model) }
                VStack(spacing: 10) {
                    HStack {
                        if phase == .capturing {
                            Button("Discard spot") { discardStop() }.buttonStyle(.bordered).tint(.white)
                        } else {
                            Button("Cancel") { if tour.stops.isEmpty { cancel() } else { confirmCancel = true } }
                                .buttonStyle(.bordered).tint(.white)
                        }
                        Spacer()
                        Text(phase == .capturing ? "\(model.shotsTaken) of \(model.targets.count)" : "\(tour.stops.count) stops")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding()
                    Text(message).font(.callout.weight(.semibold)).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(warning ? AnyShapeStyle(.orange.opacity(0.9)) : AnyShapeStyle(.ultraThinMaterial),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal)
                    if phase == .walking && !tour.stops.isEmpty {
                        HStack {
                            TourMap(points: tour.stops.map { SIMD2($0.position[0], $0.position[2]) }, current: nil,
                                    me: SIMD2(model.cameraPosition.x, model.cameraPosition.z), heading: model.cameraHeading)
                                .frame(width: 130, height: 130)
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                    Spacer()
                    controls.padding(.bottom, 30)
                }
            }
        }
        .onAppear {
            // Saved straight away, so the stops already taken are kept even if the app is closed part-way.
            var p = project
            p.summary = "Tour · not finished"
            store.save(p)
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent(ProjectFile.tourStops, isDirectory: true),
                                                     withIntermediateDirectories: true)
            UIApplication.shared.isIdleTimerDisabled = true
            model.startIdle()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.stop()
        }
        .onChange(of: model.allDone) { _, done in
            if done && phase == .capturing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { endStop() } }
        }
        .confirmationDialog("Discard this tour and its \(tour.stops.count) stops?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard tour", role: .destructive) { cancel() }
            Button("Keep capturing", role: .cancel) {}
        }
        .alert("Tour", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    private var warning: Bool {
        phase == .capturing ? (model.moved || model.tooFast) : !model.tracking
    }

    private var message: String {
        if phase == .capturing { return PanoGuide.message(model) }
        if !model.tracking { return "Move the phone around a little so it can work out where it is" }
        if tour.stops.isEmpty { return "Stand where you want the first 360, then tap Capture 360 here" }
        return "Walk to the next spot, then capture again. A stop every few steps, and one in each doorway, makes the tour easy to walk through."
    }

    @ViewBuilder private var controls: some View {
        if phase == .capturing {
            Button { endStop() } label: { Label("Done with this spot", systemImage: "checkmark.circle.fill").frame(maxWidth: 240) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.shotsTaken < 8 || ending)
        } else {
            VStack(spacing: 12) {
                Picker("Photos per stop", selection: $quick) {
                    Text("Quick · 20 photos").tag(true)
                    Text("Best · 30 photos").tag(false)
                }
                .pickerStyle(.segmented).frame(maxWidth: 320)
                Button { beginStop() } label: { Label("Capture 360 here", systemImage: "camera.fill").frame(maxWidth: 240) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.tracking)
                Button { finish() } label: { Label("Finish tour", systemImage: "flag.checkered").frame(maxWidth: 240) }
                    .buttonStyle(.bordered).tint(.white).controlSize(.large)
                    .disabled(tour.stops.isEmpty)
            }
            .padding(.horizontal)
        }
    }

    private func stopFolder(_ id: Int) -> URL {
        folder.appendingPathComponent(String(format: "%@/%02d", ProjectFile.tourStops, id), isDirectory: true)
    }

    private func beginStop() {
        currentID = nextID
        nextID += 1
        model.beginStop(folder: stopFolder(currentID),
                        targets: quick ? PanoramaCaptureModel.quickLayout() : PanoramaCaptureModel.layout())
        phase = .capturing
    }

    private func endStop() {
        guard phase == .capturing, !ending else { return }
        ending = true
        Task { @MainActor in
            // Let the last photo finish saving.
            for _ in 0..<50 where model.isSaving { try? await Task.sleep(nanoseconds: 100_000_000) }
            let photos = model.savedShots
            if photos >= 4, let end = model.endStop() {
                tour.stops.append(TourStop(id: currentID, position: [end.position.x, end.position.y, end.position.z],
                                           anchor: end.anchor.uuidString, photos: photos))
                tour.save(folder)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                _ = model.endStop()
                try? FileManager.default.removeItem(at: stopFolder(currentID))
            }
            ending = false
            phase = .walking
        }
    }

    private func discardStop() {
        guard !ending else { return }
        _ = model.endStop()
        try? FileManager.default.removeItem(at: stopFolder(currentID))
        phase = .walking
    }

    private func finish() {
        // ARKit may have corrected its map since the early stops were taken; the anchors left there moved with it.
        let anchors = model.anchorTransforms()
        for i in tour.stops.indices {
            guard let key = tour.stops[i].anchor, let id = UUID(uuidString: key), let m = anchors[id] else { continue }
            tour.stops[i].position = [m.columns.3.x, m.columns.3.y, m.columns.3.z]
            tour.stops[i].rotation = atan2(-m.columns.0.z, m.columns.0.x)
        }
        tour.save(folder)
        model.stop()
        phase = .building
        step = "Stitching"
        Task { @MainActor in
            let outcome = await TourBuilder.stitchAll(folder: folder) { f, s in
                Task { @MainActor in progress = f; step = s }
            }
            var p = project
            p.summary = outcome.failed == 0 ? "Tour · \(outcome.stitched) stops"
                                            : "Tour · \(outcome.stitched) stops (\(outcome.failed) not stitched)"
            store.save(p)
            onSaved(p)
            dismiss()
        }
    }

    private func cancel() {
        model.stop()
        store.delete(project)
        dismiss()
    }
}

// MARK: - Viewing

/// Holds the tour being viewed and moves between its stops.
final class TourNavigator: ObservableObject {
    let scene = PanoSceneController()
    @Published private(set) var tour = Tour()
    @Published private(set) var current = -1
    private var folder: URL?
    private var busy = false
    private var pushedSince: CFTimeInterval?
    private var lastMove: CFTimeInterval = 0

    init() {
        scene.stickMode = .walk
        scene.onTapMarker = { [weak self] index in self?.go(to: index) }
        scene.onStickMove = { [weak self] y in self?.stick(y) }
    }

    var hasPanoramas: Bool { tour.stops.contains { $0.stitched } }

    func open(_ folder: URL) {
        self.folder = folder
        tour = Tour.load(folder) ?? Tour()
        current = -1
        if let first = tour.stops.firstIndex(where: { $0.stitched }) { go(to: first, animated: false) }
    }

    func panoramaURL(_ index: Int) -> URL? {
        guard let folder, tour.stops.indices.contains(index) else { return nil }
        return folder.appendingPathComponent(tour.stops[index].folderName, isDirectory: true)
            .appendingPathComponent(TourStop.panoramaName)
    }

    func go(to index: Int, animated: Bool = true) {
        guard !busy, index != current, tour.stops.indices.contains(index), tour.stops[index].stitched,
              let url = panoramaURL(index) else { return }
        busy = true
        let rotation = tour.stops[index].rotation
        DispatchQueue.global(qos: .userInitiated).async {
            let image = UIImage(contentsOfFile: url.path)
            DispatchQueue.main.async {
                self.busy = false
                guard let image else { return }
                self.scene.show(image, rotation: rotation, animated: animated && self.current >= 0)
                self.current = index
                self.lastMove = CACurrentMediaTime()
                let here = self.tour.stops[index].point
                self.scene.setMarkers(self.tour.links(of: index).map {
                    PanoSceneController.Marker(id: $0, offset: self.tour.stops[$0].point - here)
                })
            }
        }
    }

    /// Joystick pushed forward or back: step to the stop that lies that way.
    private func stick(_ y: Float) {
        let now = CACurrentMediaTime()
        guard abs(y) > 0.55 else { pushedSince = nil; return }
        if pushedSince == nil { pushedSince = now }
        guard !busy, now - (pushedSince ?? now) > 0.12, now - lastMove > 0.9 else { return }
        let heading = scene.currentHeading + (y < 0 ? Double.pi : 0)
        if let next = neighbour(toward: heading) { go(to: next) }
    }

    /// The linked stop closest to the given direction, if one lies within about 55° of it.
    private func neighbour(toward heading: Double) -> Int? {
        guard tour.stops.indices.contains(current) else { return nil }
        let here = tour.stops[current].point
        var best: Int?
        var bestAngle = 55.0 * Double.pi / 180
        for j in tour.links(of: current) {
            let d = tour.stops[j].point - here
            var diff = Double(atan2(d.x, -d.z)) - heading
            while diff > Double.pi { diff -= 2 * Double.pi }
            while diff < -Double.pi { diff += 2 * Double.pi }
            if abs(diff) < bestAngle { bestAngle = abs(diff); best = j }
        }
        return best
    }
}

/// The map in the viewer: follows which way the viewer is looking.
private struct LiveTourMap: View {
    @ObservedObject var scene: PanoSceneController
    @ObservedObject var nav: TourNavigator

    var body: some View {
        TourMap(points: nav.tour.stops.map { SIMD2($0.position[0], $0.position[2]) }, current: nav.current,
                me: nil, heading: scene.heading) { nav.go(to: $0) }
    }
}

struct TourDetailView: View {
    @EnvironmentObject private var store: ProjectStore
    let project: ScanProject
    @StateObject private var nav = TourNavigator()
    @State private var useMotion = false
    @State private var building = false
    @State private var progress = 0.0
    @State private var step = ""
    @State private var showReport = false

    private var current: ScanProject { store.projects.first { $0.id == project.id } ?? project }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if building {
                ProcessingView(progress: progress, title: step)
            } else if nav.hasPanoramas {
                PanoSceneView(controller: nav.scene).ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .topTrailing) {
                        LiveTourMap(scene: nav.scene, nav: nav).frame(width: 130, height: 130).padding(12)
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stop \(nav.current + 1) of \(nav.tour.stops.count)").font(.footnote.weight(.semibold))
                            Text("Push the stick forward to walk, or tap an arrow on the floor").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: 190, alignment: .leading)
                        .padding(.leading, 14).padding(.bottom, 40)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        JoystickView { nav.scene.setStick($0) }.padding(.trailing, 22).padding(.bottom, 36)
                    }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "figure.walk").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(nav.tour.stops.isEmpty ? "This tour has no stops." : "This tour's \(nav.tour.stops.count) stops haven't been stitched yet.")
                        .foregroundStyle(.secondary)
                    if !nav.tour.stops.isEmpty {
                        Button { Task { await stitch(force: false) } } label: { Label("Stitch now", systemImage: "wand.and.stars") }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if nav.hasPanoramas && !building {
                    Button { useMotion.toggle() } label: {
                        Image(systemName: useMotion ? "iphone.gen3.radiowaves.left.and.right" : "hand.draw")
                    }
                    .accessibilityLabel(useMotion ? "Look around by dragging" : "Look around by moving the phone")
                    if let url = nav.panoramaURL(nav.current) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                Menu {
                    Button { Task { await stitch(force: false) } } label: { Label("Stitch missing stops", systemImage: "wand.and.stars") }
                    Button { Task { await stitch(force: true) } } label: { Label("Stitch everything again", systemImage: "arrow.triangle.2.circlepath") }
                    Button { showReport = true } label: { Label("Processing details", systemImage: "info.circle") }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(building)
            }
        }
        .task { nav.open(store.folder(for: project)) }
        .onChange(of: useMotion) { _, on in nav.scene.setMotion(on) }
        .onDisappear { nav.scene.stop() }
        .sheet(isPresented: $showReport) {
            NavigationStack {
                ScrollView {
                    Text((try? String(contentsOf: store.url("processing.txt", in: project), encoding: .utf8)) ?? "No details yet.")
                        .font(.footnote.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle("Processing details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showReport = false } } }
            }
        }
    }

    private func stitch(force: Bool) async {
        building = true
        step = "Stitching"
        progress = 0
        let folder = store.folder(for: project)
        let outcome = await TourBuilder.stitchAll(folder: folder, force: force) { f, s in
            Task { @MainActor in progress = f; step = s }
        }
        var p = current
        let total = (Tour.load(folder)?.stops.filter { $0.stitched }.count) ?? outcome.stitched
        p.summary = outcome.failed == 0 ? "Tour · \(total) stops" : "Tour · \(total) stops (\(outcome.failed) not stitched)"
        store.save(p)
        building = false
        nav.open(folder)
    }
}
