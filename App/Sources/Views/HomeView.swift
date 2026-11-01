import SwiftUI
import RoomPlan
import RealityKit

enum CaptureMode: String, Identifiable {
    case room, space, object, photos, measure, pipes
    var id: String { rawValue }
}

struct HomeView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var capture: CaptureMode?
    @State private var path: [ScanProject] = []
    @State private var showSettings = false
    @State private var unsupported: String?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modes
                    if store.projects.isEmpty {
                        emptyState
                    } else {
                        Text("Your scans").font(.title3.bold()).padding(.top, 6)
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.projects) { p in
                                NavigationLink(value: p) { ProjectCard(project: p) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) { store.delete(p) } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Scanvas")
            .navigationDestination(for: ScanProject.self) { p in
                if p.kind == .pipe { PipeDetailView(project: p) } else { ProjectDetailView(project: p) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { store.reload() }
        }
        .fullScreenCover(item: $capture) { mode in
            Group {
                switch mode {
                case .room: RoomScanView(onSaved: open)
                case .space: MeshScanView(onSaved: open)
                case .object: ObjectCaptureFlowView(project: ScanProject(name: store.nextName(for: .object), kind: .object), onSaved: open)
                case .photos: PhotosTo3DView(onSaved: open)
                case .measure: MeasureView()
                case .pipes: PipeSurveyView(onSaved: open)
                }
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Not available on this device", isPresented: Binding(get: { unsupported != nil }, set: { if !$0 { unsupported = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(unsupported ?? "") }
    }

    private func open(_ project: ScanProject) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { path = [project] }
    }

    private var modes: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ModeTile(title: "Room", subtitle: "Floor plans, walls, doors, furniture", icon: "square.split.bottomrightquarter", color: .green) {
                    start(.room, supported: RoomCaptureSession.isSupported, reason: "Room scanning needs an iPhone or iPad with a LiDAR sensor.")
                }
                ModeTile(title: "Space", subtitle: "Large areas as a colour 3D mesh", icon: "cube.transparent", color: .blue) {
                    start(.space, supported: MeshScanner.isSupported, reason: "Space scanning needs a LiDAR sensor.")
                }
            }
            HStack(spacing: 12) {
                ModeTile(title: "Object", subtitle: "Guided photo capture → textured model", icon: "shippingbox", color: .orange) {
                    start(.object, supported: ObjectCaptureSession.isSupported, reason: "Object Capture needs a LiDAR iPhone or iPad on iOS 17 or later.")
                }
                ModeTile(title: "Photos", subtitle: "Build a model from photos you took", icon: "photo.stack", color: .purple) {
                    start(.photos, supported: Photogrammetry.isSupported, reason: "On-device photo reconstruction needs a LiDAR iPhone or iPad.")
                }
            }
            HStack(spacing: 12) {
                ModeTile(title: "Pipes", subtitle: "Trace drainage runs: lengths, falls, levels, photos", icon: "point.topleft.down.curvedto.point.bottomright.up", color: .cyan) {
                    start(.pipes, supported: MeshScanner.isSupported, reason: "Pipe surveys need a LiDAR sensor.")
                }
                ModeTile(title: "Measure", subtitle: "Tap-to-measure distances in AR", icon: "ruler", color: .pink) {
                    start(.measure, supported: true, reason: "")
                }
            }
        }
    }

    private func start(_ mode: CaptureMode, supported: Bool, reason: String) {
        if supported { capture = mode } else { unsupported = reason }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "viewfinder").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No scans yet").font(.headline)
            Text("Pick a mode above to start. Everything in Scanvas is free, with unlimited scans and exports.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

private struct ModeTile: View {
    var title: String, subtitle: String, icon: String, color: Color
    var wide = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: wide ? .center : .top, spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: wide ? 0 : 92, alignment: .topLeading)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

struct ProjectCard: View {
    @EnvironmentObject private var store: ProjectStore
    var project: ScanProject

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color(white: 0.12)
                if let img = UIImage(contentsOfFile: store.url(ProjectFile.thumbnail, in: project).path) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: project.kind.symbol).font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 120).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 4) {
                Image(systemName: project.kind.symbol).font(.caption)
                Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Text(project.created.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
