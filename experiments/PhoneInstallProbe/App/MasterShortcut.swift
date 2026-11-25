import SwiftUI
import AppIntents
import Network
import ProbeCore

struct PollMasterBuildIntent: AppIntent {
    static var title: LocalizedStringResource = "Check selected Mac build"
    static var openAppWhenRun = false
    @Parameter(title: "Run") var run: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await MasterCoordinator.shared.poll(run))
    }
}
struct DownloadMasterBuildIntent: AppIntent {
    static var title: LocalizedStringResource = "Download selected Mac build"
    static var openAppWhenRun = true
    @Parameter(title: "Run") var run: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await MasterCoordinator.shared.download(run))
    }
}
struct InstallMasterBuildIntent: AppIntent {
    static var title: LocalizedStringResource = "Install selected Mac build"
    static var openAppWhenRun = true
    @Parameter(title: "Run") var run: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await MasterCoordinator.shared.install(run))
    }
}
struct FinishMasterBuildIntent: AppIntent {
    static var title: LocalizedStringResource = "Finish build and install"
    static var openAppWhenRun = true
    @Parameter(title: "Run") var run: String
    @MainActor func perform() async throws -> some IntentResult {
        MasterCoordinator.shared.finish(run)
        return .result()
    }
}

/// The Shortcut owns networking and sequencing. These actions never launch another Shortcut.
@MainActor
final class MasterCoordinator {
    static let shared = MasterCoordinator()
    private(set) var working = false

    static func load() -> BuildFlowState? {
        guard let data = UserDefaults.standard.data(forKey: "buildInstallFlow") else { return nil }
        return try? JSONDecoder().decode(BuildFlowState.self, from: data)
    }
    static func save(_ flow: BuildFlowState) {
        guard let data = try? JSONEncoder().encode(flow) else { return }
        UserDefaults.standard.set(data, forKey: "buildInstallFlow")
        notify()
    }
    static func notify() { NotificationCenter.default.post(name: .init("masterFlowChanged"), object: nil) }
    static func report(_ text: String) {
        var reports = UserDefaults.standard.stringArray(forKey: "sanitizedReports") ?? []
        reports.append(text)
        UserDefaults.standard.set(reports, forKey: "sanitizedReports")
    }
    private func current(_ token: String, _ phases: [BuildFlowState.Phase]) -> BuildFlowState? {
        guard let flow = Self.load(), flow.acceptsMasterRun(token, phases: phases) else { return nil }
        return flow
    }
    private func unchanged(_ flow: BuildFlowState) -> Bool {
        guard let current = Self.load() else { return false }
        return current.purpose == "master" && current.masterToken == flow.masterToken && current.phase == flow.phase
    }
    private func fail(_ flow: inout BuildFlowState, _ message: String) -> String {
        guard unchanged(flow) else { return "failed" }
        flow.phase = .restore
        flow.result = message
        Self.save(flow)
        Self.report(message)
        return "failed"
    }
    private func endedWork() { working = false; Self.notify() }

    func poll(_ token: String) async -> String {
        guard var flow = current(token, [.master, .building, .downloadReady]) else { return "failed" }
        if flow.phase == .downloadReady { return "ready" }
        guard !working else { return "waiting" }
        guard Date().timeIntervalSince(flow.started) < 1000, let selection = flow.selection else {
            return fail(&flow, "The Mac build timed out. Installation was not requested.")
        }
        working = true
        defer { endedWork() }
        flow.phase = .building
        flow.result = "Building on the Mac. The master Shortcut will continue automatically."
        Self.save(flow)
        do {
            let job = try await BuildDownloader.job(id: flow.job, submit: flow.masterSubmitted != true,
                                                     selection: selection, timeout: 12)
            guard unchanged(flow) else { return "failed" }
            flow.masterSubmitted = true
            flow.masterFailures = 0
            if job.status == "ready", let manifest = job.manifest {
                try manifest.validate()
                flow.masterManifest = manifest
                flow.phase = .downloadReady
                flow.result = "Build ready. Downloading next…"
                Self.save(flow)
                return "ready"
            }
            if job.status == "failed" { return fail(&flow, job.message) }
            Self.save(flow)
            return "waiting"
        } catch {
            guard unchanged(flow) else { return "failed" }
            flow.masterFailures = (flow.masterFailures ?? 0) + 1
            if flow.masterFailures! >= 6 {
                return fail(&flow, "Could not reach or validate the Mac job. Installation was not requested.")
            }
            flow.result = "Waiting for the private Mac connection…"
            Self.save(flow)
            return "waiting"
        }
    }

    func download(_ token: String) async -> String {
        guard var flow = current(token, [.downloadReady]), !working,
              let selection = flow.selection, let expected = flow.masterManifest else { return "failed" }
        working = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer { endedWork(); UIApplication.shared.isIdleTimerDisabled = false }
        flow.phase = .downloading
        flow.result = "Downloading the selected build…"
        Self.save(flow)
        do {
            let job = try await BuildDownloader.job(id: flow.job, submit: false, selection: selection, timeout: 12)
            guard job.status == "ready", job.manifest?.sha256 == expected.sha256,
                  job.manifest?.bundleID == expected.bundleID, job.manifest?.buildVersion == expected.buildVersion else {
                throw DownloadIssue.wrongApp
            }
            let artifact = try await BuildDownloader.download(job: job, selection: selection, progress: { _ in })
            guard unchanged(flow) else { return "failed" }
            flow.artifactHash = artifact.sha256
            flow.phase = .installReady
            flow.result = "Download verified. The master Shortcut is preparing offline installation…"
            Self.save(flow)
            return "ready"
        } catch { return fail(&flow, "Download failed. No installation was requested; restoring internet next.") }
    }

    func install(_ token: String) async -> String {
        guard var flow = current(token, [.installReady]), !working else { return "failed" }
        // Persist before native work. Repeated or interrupted calls cannot replay an install.
        working = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer { endedWork(); UIApplication.shared.isIdleTimerDisabled = false }
        flow.phase = .installing
        flow.result = "Installing the verified build…"
        Self.save(flow)
        do {
            guard await WiFiCheck().isUnavailable() else { throw DownloadIssue.invalidResponse }
            let candidate = try InstallCandidate.load()
            guard candidate.sha256 == flow.artifactHash,
                  candidate.bundleID == flow.masterManifest?.bundleID,
                  candidate.buildVersion == flow.masterManifest?.buildVersion else { throw DownloadIssue.wrongApp }
            try candidate.verifyArtifact(at: InstallCandidate.artifactURL())
            let connection = await DeviceProbe().run(host: "10.7.0.1", kind: .remotePairing)
            guard connection.tcpAccepted else { throw DownloadIssue.invalidResponse }
            let result = await AuthenticatedProbe.runResult(host: "10.7.0.1", bundleID: Bundle.main.bundleIdentifier ?? "",
                                                           installStaged: true, progress: { _ in })
            Self.report((["Master Shortcut installation"] + result.lines).joined(separator: "\n"))
            guard unchanged(flow) else { return "failed" }
            switch result.outcome {
            case .verified: flow.result = "Installed \(candidate.displayName) build \(candidate.buildVersion). Open the app to test it."
            case .alreadyInstalled: flow.result = "The selected build is already installed."
            case .unverified: flow.result = "Installation outcome is uncertain. Check the target before retrying."
            case .notRequested: flow.result = "Local installation failed; no install request was sent."
            }
            flow.phase = .restore
            Self.save(flow)
            return result.outcome == .verified || result.outcome == .alreadyInstalled ? "installed" : "failed"
        } catch { return fail(&flow, "Offline connection or artifact verification failed. No install request was sent.") }
    }

    func finish(_ token: String) {
        guard var flow = current(token, [.master, .building, .downloadReady, .installReady, .restore]), !working else { return }
        if flow.phase != .restore { flow.result = "Master Shortcut ended before installation. No install request was sent." }
        flow.phase = .done
        flow.result += " Internet restoration actions completed."
        Self.report(flow.result)
        Self.save(flow)
    }
}

/// Fail closed if the radio path cannot be established within a short observation window.
private final class WiFiCheck: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhoneInstallProbe.masterWiFi")
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var continuation: CheckedContinuation<Bool, Never>?
    func isUnavailable() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.monitor.pathUpdateHandler = { path in self.finish(path.status == .unsatisfied) }
                self.queue.asyncAfter(deadline: .now() + 2) { self.finish(false) }
                self.monitor.start(queue: self.queue)
            }
        }
    }
    private func finish(_ result: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        monitor.cancel()
        continuation.resume(returning: result)
    }
}

extension ProbeModel {
    func syncMasterFlow() {
        guard let stored = MasterCoordinator.load(), stored.purpose == "master" else { return }
        flow = stored
        busy = MasterCoordinator.shared.working
        liveStatus = stored.result
        reports = UserDefaults.standard.stringArray(forKey: "sanitizedReports") ?? []
        candidate = try? InstallCandidate.load()
        refreshSource()
    }
    func startBuildInstall() {
        guard !busy, !catalogLoading, flowIsIdle else { return }
        guard masterReady, helpersReady, pairingReady, downloadReady else {
            liveStatus = "Add the master Shortcut and complete private preparation first."
            return
        }
        guard wifiPath == "Not available", let selection = projectCache.selection else {
            liveStatus = "Select a project and scheme, and turn Wi-Fi off in Settings."
            return
        }
        var state = BuildFlowState()
        state.purpose = "master"
        state.phase = .master
        state.selection = selection
        state.result = "Starting the master Shortcut…"
        flow = state
        MasterCoordinator.save(state)
        UIApplication.shared.open(state.shortcutURL(name: "Probe Build & Install", input: state.masterToken)) { opened in
            if !opened {
                Task { @MainActor in
                    guard var current = MasterCoordinator.load(), current.job == state.job else { return }
                    current.phase = .done
                    current.result = "Could not open the master Shortcut. Check its setup."
                    MasterCoordinator.save(current)
                }
            }
        }
    }
}
