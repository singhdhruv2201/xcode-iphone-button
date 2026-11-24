import SwiftUI
import Network
import ProbeCore

@main
struct PhoneInstallProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

@MainActor
final class ProbeModel: ObservableObject {
    @Published var projectCache = ProjectCache.load()
    @Published var catalogLoading = false
    @Published var catalogMessage = ""
    @Published var selectedProjectID = ""
    @Published var availableSchemes: [String] = []
    @Published var selectedScheme = ""
    @Published var flow: BuildFlowState?
    @Published var helpersReady = UserDefaults.standard.bool(forKey: "networkHelpersReady") {
        didSet { UserDefaults.standard.set(helpersReady, forKey: "networkHelpersReady") }
    }
    @Published var busy = false
    @Published var reports: [String] = []
    @Published var wifiPath = "Checking"
    @Published var pairingStatus = "Not loaded"
    @Published var pairingReady = false
    @Published var liveStatus = ""
    @Published var candidate: InstallCandidate?
    @Published var downloadReady = false
    @Published var downloadStatus = "Private Mac connection not loaded"
    @Published var artifactSource = "Staged locally"
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)

    init() {
        reports = UserDefaults.standard.stringArray(forKey: "sanitizedReports") ?? []
        if let last = UserDefaults.standard.string(forKey: "unfinishedTestStatus") {
            liveStatus = "Previous test ended without a final result: \(last). Check the installed version before repeating an installation."
        }
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            let status = path.status == .satisfied ? "Available" : "Not available"
            Task { @MainActor in self?.wifiPath = status }
        }
        selectedProjectID = projectCache.selection?.projectID ?? ""
        selectedScheme = projectCache.selection?.scheme ?? ""
        if !selectedScheme.isEmpty { availableSchemes = [selectedScheme] }
        loadFlow()
        wifiMonitor.start(queue: DispatchQueue(label: "PhoneInstallProbe.wifi"))
    }

    deinit { wifiMonitor.cancel() }

    func refreshPairing() {
        guard !busy else { return }
        candidate = try? InstallCandidate.load()
        refreshSource()
        do {
            try DownloadSettingsVault.importFromUSB()
            _ = try DownloadSettingsVault.load()
            downloadReady = true
            downloadStatus = "Private Mac connection ready"
        } catch {
            downloadReady = false
            downloadStatus = "Private Mac connection needs initial USB preparation"
        }
        do {
            _ = try PairingVault.importFromUSB()
            _ = try PairingVault.load()
            pairingReady = true
            pairingStatus = "Ready — stored privately on this iPhone"
        } catch {
            pairingReady = false
            pairingStatus = "Not ready — USB preparation needed"
        }
    }

    func refreshSource() {
        let marker = try? String(contentsOf: InstallCandidate.folder().appendingPathComponent("source.txt"), encoding: .utf8)
        artifactSource = marker == "private-download" ? "Downloaded from Mac over private HTTPS" : "Staged locally"
    }

    func downloadBuild(stage: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let before = wifiPath
        let started = Date()
        liveStatus = "Connecting to the Mac…"
        var lines = ["Download test — stage (user selected): \(stage)", "Wi-Fi path before: \(before)"]
        do {
            candidate = try await BuildDownloader.download { [weak self] line in
                Task { @MainActor in self?.liveStatus = line }
            }
            refreshSource()
            lines += ["Pinned HTTPS and authenticated manifest: accepted",
                      "Downloaded artifact: size and SHA-256 verified",
                      "Downloaded build: saved for offline installation"]
            liveStatus = "Download complete. Disconnect Tailscale, connect LocalDevVPN, turn Cellular Data off, then install."
        } catch {
            candidate = try? InstallCandidate.load()
            let message: String
            if let failure = error as? DownloadConnectionFailure {
                message = "Download connection failed:\n\(failure.diagnostic)"
            } else if let error = error as? URLError {
                message = "Download failed (network code \(error.code.rawValue)). Check Tailscale and the Mac server."
            } else if case DownloadIssue.http(let code) = error {
                message = "Download rejected (HTTP \(code))."
            } else {
                message = "Download failed validation or private configuration; no new build marked ready."
            }
            lines.append(message)
            liveStatus = message
        }
        lines += ["Wi-Fi path after: \(wifiPath)",
                  "Elapsed: \(String(format: "%.1f", Date().timeIntervalSince(started)))s",
                  "Installation: NOT REQUESTED by download"]
        reports.append(lines.joined(separator: "\n"))
        UserDefaults.standard.set(reports, forKey: "sanitizedReports")
    }

    func authenticate(host: String, stage: String, install: Bool = false) async {
        guard !busy else { return }
        busy = true
        liveStatus = "Starting authenticated test…"
        defer { busy = false }
        let before = wifiPath
        let reminder = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.liveStatus += "\nStill waiting. Do not start a second test. If you close the app during installation, its outcome is unknown; check the installed build before retrying."
        }
        defer { reminder.cancel() }
        let results = await AuthenticatedProbe.run(host: host, bundleID: Bundle.main.bundleIdentifier ?? "", installStaged: install) { [weak self] line in
            Task { @MainActor in
                self?.liveStatus = line
                UserDefaults.standard.set(line, forKey: "unfinishedTestStatus")
            }
        }
        reports.append((["\(install ? "Installation" : "Authenticated") test — stage (user selected): \(stage)",
                         "Wi-Fi path before: \(before)"] + results +
                        ["Wi-Fi path after: \(wifiPath)", "Restore cellular data after the test."]).joined(separator: "\n"))
        liveStatus = "Finished. Restore cellular data."
        UserDefaults.standard.set(reports, forKey: "sanitizedReports")
        UserDefaults.standard.removeObject(forKey: "unfinishedTestStatus")
    }

    func run(host: String, stage: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let before = wifiPath
        var lines = ["Stage (user selected): \(stage)", "Wi-Fi path before: \(before)"]
        #if targetEnvironment(simulator)
        lines.append("SIMULATOR: cannot validate iPhone service availability.")
        #endif
        for kind in ProbeProtocol.allCases {
            let result = await DeviceProbe().run(host: host, kind: kind)
            lines.append("\(kind.rawValue): \(result.outcome) (\(String(format: "%.2f", result.seconds))s)")
        }
        lines.append("Wi-Fi path after: \(wifiPath)")
        lines.append("Authentication and installation: NOT TESTED")
        reports.append(lines.joined(separator: "\n"))
    }
}

struct ProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ProbeModel()
    @State private var host = "10.7.0.1"
    @State private var stage = "Cellular + Tailscale"
    @State private var wifiOff = false
    private let stages = ["Cellular + Tailscale", "Cellular + LocalDevVPN", "Data off + LocalDevVPN", "Wi-Fi control"]

    var body: some View {
        NavigationStack {
            Form {
                ProjectPickerSection(model: model)
                Section("Build & Install") {
                    if let selection = model.projectCache.selection {
                        Text(selection.projectName).font(.headline)
                        Text(selection.scheme).font(.caption).foregroundStyle(.secondary)
                    } else { Text("Select a project and scheme above.").foregroundStyle(.secondary) }
                    Button {
                        model.startBuildInstall()
                    } label: {
                        Label("Build & Install", systemImage: "hammer.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.catalogLoading || model.projectCache.selection == nil || !model.helpersReady || !model.pairingReady || !model.downloadReady || (model.flow != nil && model.flow?.phase != .done))
                    if model.busy { ProgressView() }
                    if !model.liveStatus.isEmpty { Text(model.liveStatus).font(.footnote) }
                    Text("Keep the Mac awake and this app open. For this test, unplug USB and turn Wi-Fi off. Shortcuts will briefly switch networks, then return here.").font(.caption)
                    Button("Restore Internet", systemImage: "antenna.radiowaves.left.and.right") { model.restoreInternet() }
                        .disabled(model.busy)
                    Text("If the app stops while offline, turn Cellular Data on in Settings and disconnect LocalDevVPN. Restore Internet is also available as a standalone Shortcut.").font(.caption).foregroundStyle(.secondary)
                }
                Section("One-time Shortcut setup") {
                    ForEach(["Probe Connect to Mac", "Probe Prepare Installation", "Probe Restore Internet"], id: \.self) { name in
                        if let url = Bundle.main.url(forResource: name, withExtension: "shortcut") {
                            ShareLink(item: url) { Label("Add " + name, systemImage: "square.and.arrow.up") }
                        }
                    }
                    Text("Add the three helpers to Shortcuts using the buttons above. Keep their exact names. Run Restore Internet once to approve initial prompts.").font(.caption)
                    Toggle("All three helpers are configured", isOn: $model.helpersReady)
                }.disabled(model.busy)
                Section {
                    Text("Can this iPhone reach its own development service without Wi-Fi?")
                    Text("Download a signed build from your Mac, then install it during a brief offline step. The controls below remain available for manual diagnostics.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Download from Mac · v6") {
                    Text(model.downloadStatus).font(.footnote)
                    Button("Download latest build") {
                        Task { await model.downloadBuild(stage: stage) }
                    }
                    .disabled(model.busy || !model.downloadReady || !wifiOff || stage != "Cellular + Tailscale")
                    Text("Unplug USB and keep Wi-Fi off. Leave Cellular Data ON, disconnect LocalDevVPN, and connect Tailscale. Select Cellular + Tailscale in Test setup, then download. Keep this app open until it finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Authenticated test · v6") {
                    Text(model.pairingStatus).font(.footnote)
                    Button("Load private USB preparation") { model.refreshPairing() }
                        .disabled(model.busy)
                    Button("Test authenticated service") {
                        Task { await model.authenticate(host: host.trimmingCharacters(in: .whitespacesAndNewlines), stage: stage) }
                    }
                    .disabled(model.busy || !model.pairingReady || !wifiOff || stage != "Data off + LocalDevVPN" || !DeviceProbe.isLocalAddress(host))
                    Text("For this test, unplug USB, keep Wi-Fi off, connect LocalDevVPN, and turn Cellular Data off. Select Data off + LocalDevVPN in Test setup. Afterward, restore Cellular Data.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The service test only looks up this probe. The library may request trust again if verification fails. Some protocol waits have no overall deadline.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.liveStatus.isEmpty { Text(model.liveStatus).font(.footnote).textSelection(.enabled) }
                }
                Section("Staged installation") {
                    if let candidate = model.candidate {
                        Text("\(candidate.displayName) · build \(candidate.buildVersion)")
                        Text("\(candidate.byteCount / 1_024) KiB · \(model.artifactSource)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Install staged build") {
                            Task { await model.authenticate(host: host.trimmingCharacters(in: .whitespacesAndNewlines), stage: stage, install: true) }
                        }
                        .disabled(model.busy || !model.pairingReady || !wifiOff || stage != "Data off + LocalDevVPN" || !DeviceProbe.isLocalAddress(host))
                        Text("Updates this app if it is already installed. Verifies the staged file, requests installation, and checks the installed build number. Open the target app manually afterward.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No signed build staged. Download a build from the Mac first.")
                    }
                }
                Section("Test setup") {
                    Picker("Current setup", selection: $stage) {
                        ForEach(stages, id: \.self) { Text($0) }
                    }
                    TextField("Device IP from LocalDevVPN", text: $host)
                        .keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Use Device IP in LocalDevVPN Settings, without /32. This is not your Mac’s address or the VPN’s Tunnel IP.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Wi-Fi path", value: model.wifiPath)
                    Toggle("Wi-Fi is off in Settings; USB unplugged", isOn: $wifiOff)
                    Text("Select a setup only after changing it yourself. A network-path check alone cannot verify the radio or VPN app in use.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy)
                Section {
                    Button {
                        let endpoint = host.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await model.run(host: endpoint, stage: stage) }
                    } label: {
                        HStack {
                            Text(model.busy ? "Checking…" : "Check local services")
                            Spacer()
                            if model.busy { ProgressView() }
                        }
                    }
                    .disabled(model.busy || (!wifiOff && stage != "Wi-Fi control") || !DeviceProbe.isLocalAddress(host))
                    Text("Each check takes at most about 12 seconds. An open port is only a first step; it does not prove installation works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.reports.isEmpty {
                    Section("Results") {
                        ForEach(Array(model.reports.enumerated()), id: \.offset) { _, report in
                            Text(report).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                        ShareLink("Share results", item: model.reports.joined(separator: "\n\n"))
                        Button("Clear results", role: .destructive) {
                            model.reports = []
                            UserDefaults.standard.removeObject(forKey: "sanitizedReports")
                        }.disabled(model.busy)
                    }
                }
            }
            .navigationTitle("Phone Install Probe")
            .task {
                model.refreshPairing()
                model.consumeBuildRequest()
                if model.downloadReady && model.flowIsIdle { await model.refreshProjects() }
            }
            .onOpenURL { model.handleCallback($0) }
            .onReceive(NotificationCenter.default.publisher(for: .init("requestedBuildInstall"))) { _ in model.consumeBuildRequest() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshPairing(); model.consumeBuildRequest() } }
        }
    }
}
