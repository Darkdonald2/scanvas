import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("units") private var unitsRaw = UnitSystem.metric.rawValue
    @AppStorage("cadUnit") private var cadUnitRaw = CADUnit.millimetres.rawValue
    @AppStorage("wallThickness") private var wallThickness = 0.12
    @AppStorage("captureColour") private var captureColour = true

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
                    Toggle("Capture colour", isOn: $captureColour)
                } header: { Text("Space scans") } footer: {
                    Text("Keeps small camera snapshots while scanning to colour the mesh. Turn off for very long scans to save memory.")
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
