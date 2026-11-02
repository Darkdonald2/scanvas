import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("units") private var unitsRaw = UnitSystem.metric.rawValue
    @AppStorage("cadUnit") private var cadUnitRaw = CADUnit.millimetres.rawValue
    @AppStorage("wallThickness") private var wallThickness = 0.12
    @AppStorage("captureColour") private var captureColour = true
    @AppStorage("smoothMesh") private var smoothMesh = true
    @AppStorage("lockExposure") private var lockExposure = true
    @AppStorage("cleanMesh") private var cleanMesh = false
    @AppStorage("refineCameras") private var refineCameras = false
    @AppStorage("compactTextures") private var compactTextures = true
    @AppStorage("fullResPhotos") private var fullResPhotos = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Measurements", selection: $unitsRaw) {
                        ForEach(UnitSystem.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("CAD export units", selection: $cadUnitRaw) {
                        ForEach(CADUnit.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section {
                    Stepper(value: $wallThickness, in: 0.05...0.5, step: 0.01) {
                        LabeledContent("Wall thickness", value: (UnitSystem(rawValue: unitsRaw) ?? .metric).length(Float(wallThickness)))
                    }
                } header: { Text("Room scans") } footer: {
                    Text("RoomPlan measures wall surfaces, not their thickness. This value is used for walls in DXF, IFC and 3D exports.")
                }
                Section {
                    Toggle("Photo textures", isOn: $captureColour)
                    Toggle("Smooth mesh", isOn: $smoothMesh)
                    Toggle("Lock exposure while scanning", isOn: $lockExposure)
                } header: { Text("Space scans") } footer: {
                    Text("Photo textures: takes photos while you scan and wraps the mesh in them afterwards. Smooth mesh: removes LiDAR bumps and noise. Lock exposure: keeps brightness and colour the same in every photo so walls don't look patchy; turn it off if you walk between very bright and very dark areas. Turn photo textures off for very long scans to save memory.")
                }
                Section {
                    Toggle("Sharper textures (compact packing)", isOn: $compactTextures)
                    Toggle("Full-resolution photos", isOn: $fullResPhotos)
                    Toggle("Refine camera positions", isOn: $refineCameras)
                    Toggle("Clean mesh (remove floating bits)", isOn: $cleanMesh)
                } header: { Text("Processing (testing)") } footer: {
                    Text("New processing steps you can switch on and off to compare. Each scan's ⋯ menu shows which ones it was made with.")
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Text("Scanvas is free: unlimited scans and every export format, with no account and no subscription. Scans stay on your device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
