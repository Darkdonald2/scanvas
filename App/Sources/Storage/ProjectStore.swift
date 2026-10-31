import Foundation
import SwiftUI

/// Keeps every scan in Documents/Scans/<id>/ and exports in Documents/Exports/ (both visible in the Files app).
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ScanProject] = []

    nonisolated static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    nonisolated static var scansRoot: URL { documents.appendingPathComponent("Scans", isDirectory: true) }
    nonisolated static var exportsRoot: URL { documents.appendingPathComponent("Exports", isDirectory: true) }

    init() { reload() }

    func folder(for project: ScanProject) -> URL { Self.folder(for: project.id) }

    nonisolated static func folder(for id: UUID) -> URL {
        scansRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(_ file: String, in project: ScanProject) -> URL { folder(for: project).appendingPathComponent(file) }

    func has(_ file: String, in project: ScanProject) -> Bool {
        FileManager.default.fileExists(atPath: url(file, in: project).path)
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.scansRoot, withIntermediateDirectories: true)
        var dirs = (try? fm.contentsOfDirectory(at: Self.scansRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        // Clean up leftovers of scans that never finished saving (app closed mid-processing, failed save).
        dirs.removeAll { dir in
            guard !fm.fileExists(atPath: dir.appendingPathComponent(ProjectFile.info).path) else { return false }
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard Date().timeIntervalSince(modified) > 3600 else { return false }
            try? fm.removeItem(at: dir)
            return true
        }
        projects = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(ProjectFile.info)) else { return nil }
            return try? JSONDecoder().decode(ScanProject.self, from: data)
        }
        .sorted { $0.created > $1.created }
    }

    /// Creates the folder for a new project; the caller fills it, then calls `save`.
    func makeFolder(for project: ScanProject) throws -> URL {
        let dir = folder(for: project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func save(_ project: ScanProject) {
        do {
            let dir = try makeFolder(for: project)
            let data = try JSONEncoder().encode(project)
            try data.write(to: dir.appendingPathComponent(ProjectFile.info), options: .atomic)
        } catch {
            print("Save failed: \(error)")
        }
        reload()
    }

    func rename(_ project: ScanProject, to name: String) {
        var p = project
        p.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? project.name : name
        save(p)
    }

    func delete(_ project: ScanProject) {
        try? FileManager.default.removeItem(at: folder(for: project))
        reload()
    }

    func nextName(for kind: ScanKind) -> String {
        let n = projects.filter { $0.kind == kind }.count + 1
        return "\(kind.title) \(n)"
    }

    func loadPlan(_ project: ScanProject) -> PlanModel? {
        guard let data = try? Data(contentsOf: url(ProjectFile.plan, in: project)) else { return nil }
        return try? JSONDecoder().decode(PlanModel.self, from: data)
    }

    func loadMesh(_ project: ScanProject) -> MeshData? {
        try? MeshData(contentsOf: url(ProjectFile.mesh, in: project))
    }
}
