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
    @Published var masterReady = UserDefaults.standard.bool(forKey: "masterShortcutReady") {
        didSet { UserDefaults.standard.set(masterReady, forKey: "masterShortcutReady") }
    }
    @Published var helpersReady = UserDefaults.standard.bool(forKey: "networkHelpersReady") {
        didSet { UserDefaults.standard.set(helpersReady, forKey: "networkHelpersReady") }
    }
    @Published var busy = false
    @Published var reports: [String] = [] {
        didSet { updateReportEntries() }
    }
    @Published private(set) var reportEntries: [ProbeReportEntry] = []
    @Published var connectionCheckedAt: Date?
    @Published var connectionReachable: Bool?
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
        updateReportEntries()
        loadFlow()
        wifiMonitor.start(queue: DispatchQueue(label: "PhoneInstallProbe.wifi"))
    }

    deinit { wifiMonitor.cancel() }

    private func updateReportEntries() {
        reportEntries = reports.enumerated().map { index, text in
            if reportEntries.indices.contains(index), reportEntries[index].text == text {
                return reportEntries[index]
            }
            return ProbeReportEntry(text: text)
        }
    }

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

    func diagnoseMacConnection() async {
        guard !busy, !catalogLoading, flowIsIdle else { return }
        busy = true
        liveStatus = "Checking the private Mac connection…"
        defer { busy = false }
        let check = await BuildDownloader.checkMacConnection()
        connectionReachable = check.reachable
        connectionCheckedAt = Date()
        liveStatus = check.diagnostic
        reports.append(check.diagnostic)
        UserDefaults.standard.set(reports, forKey: "sanitizedReports")
    }

    func refreshSource() {
        let marker = try? String(contentsOf: InstallCandidate.folder().appendingPathComponent("source.txt"), encoding: .utf8)
        artifactSource = marker == "private-download" ? "Downloaded from Mac over private HTTPS" : "Staged locally"
    }

    func downloadBuild(stage: String) async {
        guard !busy, flowIsIdle else { return }
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
        guard !busy, flowIsIdle else { return }
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
        guard !busy, flowIsIdle else { return }
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
