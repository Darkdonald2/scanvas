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
    @AppStorage("refineCameras") private var refineCameras = true
    @AppStorage("compactTextures") private var compactTextures = true
    @AppStorage("fullResPhotos") private var fullResPhotos = true
    @AppStorage("rawCapture") private var rawCapture = false
    @AppStorage("raw4K") private var raw4K = false

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
                    Toggle("Raw capture for computer", isOn: $rawCapture)
                    Toggle("4K photos", isOn: $raw4K).disabled(!rawCapture)
                    Link(destination: URL(string: "https://github.com/Darkdonald2/scanvas/releases/tag/studio")!) {
                        Label("Get Scanvas Studio for Mac or Windows", systemImage: "desktopcomputer")
                    }
                } header: { Text("Computer processing") } footer: {
                    Text("Space and Pipes scans also save every photo at full camera resolution with its LiDAR depth and exact camera position (about 6 photos a second, roughly 1–2 GB per 10 minutes). Send them from the scan's ⋯ menu to Scanvas Studio on a Mac or PC, which builds a much denser, sharper model. The phone then shows a quick coloured preview instead of making textures itself. 4K photos are sharper but larger, and need iPhone 12 Pro or newer.")
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
