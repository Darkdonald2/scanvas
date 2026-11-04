import SwiftUI
import Network

/// The raw capture saved with a scan, ready to go to Scanvas Studio.
struct RawPackage {
    let folder: URL
    let name: String

    init(project: ScanProject) {
        folder = ProjectStore.folder(for: project.id).appendingPathComponent(RawRecorder.folderName, isDirectory: true)
        name = project.name
    }

    static func exists(for project: ScanProject) -> Bool {
        FileManager.default.fileExists(atPath: ProjectStore.folder(for: project.id)
            .appendingPathComponent(RawRecorder.folderName).appendingPathComponent("capture.json").path)
    }

    /// Adds the scan's other data (pipe survey, name) so the computer has everything.
    func prepare() {
        let project = folder.deletingLastPathComponent()
        for file in [ProjectFile.pipes, ProjectFile.info] {
            let src = project.appendingPathComponent(file), dst = folder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }

    /// Every file, relative to the folder, with its size.
    func files() -> [(path: String, size: Int64)] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return [] }
        var out: [(String, Int64)] = []
        let base = folder.standardizedFileURL.path + "/"
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            out.append((String(url.standardizedFileURL.path.dropFirst(base.count)), Int64(v?.fileSize ?? 0)))
        }
        return out
    }

    var frameCount: Int {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("capture.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return json["frames"] as? Int ?? 0
    }

    /// Zips the folder (iOS does this itself when a folder is read "for uploading").
    func zip() throws -> URL {
        prepare()
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe) raw.zip")
        try? FileManager.default.removeItem(at: out)
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { zipURL in
            do { try FileManager.default.copyItem(at: zipURL, to: out) } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw e }
        return out
    }
}

/// A computer running Scanvas Studio, found on the Wi-Fi or typed in.
struct StudioComputer: Identifiable, Hashable {
    var name: String
    var host: String
    var port: Int
    var id: String { "\(host):\(port)" }
}

/// Finds Scanvas Studio on the local network (it advertises itself over Bonjour).
final class StudioBrowser: ObservableObject {
    @Published var found: [StudioComputer] = []
    private var browser: NWBrowser?

    func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_scanvas._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var list: [StudioComputer] = []
            for r in results {
                guard case let .bonjour(txt) = r.metadata, let addr = txt["addr"], let port = Int(txt["port"] ?? "") else { continue }
                var name = txt["name"] ?? "Computer"
                if case let .service(service, _, _, _) = r.endpoint { name = txt["name"] ?? service }
                if let host = addr.split(separator: ",").first.map(String.init), !host.isEmpty {
                    list.append(StudioComputer(name: name, host: host, port: port))
                }
            }
            DispatchQueue.main.async { self?.found = list }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() { browser?.cancel(); browser = nil }
}

/// Sends a raw capture to Scanvas Studio over Wi-Fi, one file at a time.
@MainActor
final class StudioSender: ObservableObject {
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var sending = false
    @Published var done = false
    @Published var error: String?
    private var task: Task<Void, Never>?

    func send(_ package: RawPackage, to computer: StudioComputer, code: String) {
        guard !sending else { return }
        sending = true; done = false; error = nil; progress = 0
        status = "Connecting…"
        task = Task {
            do {
                let base = "http://\(computer.host):\(computer.port)"
                var hello = URLRequest(url: URL(string: base + "/hello")!)
                hello.timeoutInterval = 8
                hello.setValue(code, forHTTPHeaderField: "X-Scanvas-Code")
                let (_, response) = try await URLSession.shared.data(for: hello)
                try check(response)
                package.prepare()
                let files = package.files()
                let total = max(1, files.reduce(Int64(0)) { $0 + $1.size })
                let transfer = UUID().uuidString
                var sent: Int64 = 0
                for (i, file) in files.enumerated() {
                    try Task.checkCancellation()
                    status = "Sending \(i + 1) of \(files.count)…"
                    let path = file.path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
                    var req = URLRequest(url: URL(string: "\(base)/upload/\(transfer)/\(path)")!)
                    req.httpMethod = "PUT"
                    req.timeoutInterval = 120
                    req.setValue(code, forHTTPHeaderField: "X-Scanvas-Code")
                    var attempt = 0
                    while true {
                        do {
                            let (_, r) = try await URLSession.shared.upload(for: req, fromFile: package.folder.appendingPathComponent(file.path))
                            try check(r)
                            break
                        } catch {
                            attempt += 1
                            if attempt >= 3 || error is CancellationError { throw error }
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    }
                    sent += file.size
                    progress = Double(sent) / Double(total)
                }
                let name = package.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Scan"
                var finish = URLRequest(url: URL(string: "\(base)/done/\(transfer)?name=\(name)&files=\(files.count)")!)
                finish.httpMethod = "POST"
                finish.setValue(code, forHTTPHeaderField: "X-Scanvas-Code")
                let (_, r) = try await URLSession.shared.data(for: finish)
                try check(r)
                status = "Sent. Scanvas Studio is processing it now."
                done = true
            } catch is CancellationError {
                status = "Cancelled"
            } catch let e as SendError {
                error = e.message
            } catch {
                self.error = "Couldn't reach the computer: \(error.localizedDescription). Check both are on the same Wi-Fi and Scanvas Studio is open."
            }
            sending = false
        }
    }

    func cancel() { task?.cancel() }

    struct SendError: Error { var message: String }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 403 { throw SendError(message: "Wrong pairing code. Type the code shown in Scanvas Studio.") }
        if http.statusCode >= 400 { throw SendError(message: "The computer refused the file (error \(http.statusCode)).") }
    }
}

/// "Send to computer": Wi-Fi straight into Scanvas Studio, or a zip through AirDrop, Files, OneDrive and so on.
struct RawTransferView: View {
    let project: ScanProject
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = StudioBrowser()
    @StateObject private var sender = StudioSender()
    @AppStorage("studioCode") private var code = ""
    @AppStorage("studioAddress") private var manualAddress = ""
    @State private var zipURL: URL?
    @State private var zipping = false
    @State private var zipError: String?
    @State private var size: Int64 = 0
    @State private var frames = 0

    private var package: RawPackage { RawPackage(project: project) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Photos with depth", value: frames.formatted())
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                } footer: {
                    Text("Scanvas Studio on a Mac or Windows PC turns this into a dense, sharp, photo-textured model.")
                }
                Section {
                    TextField("Pairing code shown in Scanvas Studio", text: $code)
                        .keyboardType(.numberPad)
                    if browser.found.isEmpty {
                        Label("Looking for Scanvas Studio on this Wi-Fi…", systemImage: "wifi").foregroundStyle(.secondary)
                    }
                    ForEach(browser.found) { computer in
                        Button { sender.send(package, to: computer, code: code) } label: {
                            Label("Send to \(computer.name)", systemImage: "desktopcomputer")
                        }
                        .disabled(sender.sending || code.isEmpty)
                    }
                    HStack {
                        TextField("Or type its address, e.g. 192.168.1.20", text: $manualAddress)
                            .keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Send") {
                            if let c = parse(manualAddress) { sender.send(package, to: c, code: code) }
                        }
                        .disabled(sender.sending || code.isEmpty || parse(manualAddress) == nil)
                    }
                    if sender.sending || sender.done {
                        ProgressView(value: sender.progress)
                        Text(sender.status).font(.footnote)
                        if sender.sending { Button("Cancel", role: .destructive) { sender.cancel() } }
                    }
                    if let e = sender.error { Text(e).font(.footnote).foregroundStyle(.red) }
                } header: { Text("Send over Wi-Fi") } footer: {
                    Text("Open Scanvas Studio on the computer, keep this phone unlocked, and stay on the same Wi-Fi.")
                }
                Section {
                    if let zipURL {
                        ShareLink(item: zipURL) { Label("Share zip…", systemImage: "square.and.arrow.up") }
                    } else {
                        Button { makeZip() } label: {
                            if zipping { HStack { ProgressView(); Text("Making zip…") } } else { Label("Make a zip", systemImage: "doc.zipper") }
                        }
                        .disabled(zipping)
                    }
                    if let zipError { Text(zipError).font(.footnote).foregroundStyle(.red) }
                } header: { Text("Or share a zip") } footer: {
                    Text("AirDrop it to a Mac, or save it to Files, iCloud Drive, OneDrive or a USB drive, then open it in Scanvas Studio.")
                }
                Section {
                    Link(destination: URL(string: "https://github.com/Darkdonald2/scanvas/releases/tag/studio")!) {
                        Label("Get Scanvas Studio", systemImage: "arrow.down.circle")
                    }
                }
            }
            .navigationTitle("Send to computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            browser.start()
            UIApplication.shared.isIdleTimerDisabled = true
            let p = package
            Task.detached {
                let total = p.files().reduce(Int64(0)) { $0 + $1.size }
                let n = p.frameCount
                await MainActor.run { size = total; frames = n }
            }
        }
        .onDisappear {
            browser.stop()
            sender.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            if let zipURL { try? FileManager.default.removeItem(at: zipURL) }
        }
    }

    private func parse(_ text: String) -> StudioComputer? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? Int(parts[1]) ?? 8765 : 8765
        guard host.contains(".") || host.hasSuffix("local") else { return nil }
        return StudioComputer(name: host, host: host, port: port)
    }

    private func makeZip() {
        zipping = true; zipError = nil
        let p = package
        Task.detached {
            do {
                let url = try p.zip()
                await MainActor.run { zipURL = url; zipping = false }
            } catch {
                await MainActor.run { zipError = error.localizedDescription; zipping = false }
            }
        }
    }
}
