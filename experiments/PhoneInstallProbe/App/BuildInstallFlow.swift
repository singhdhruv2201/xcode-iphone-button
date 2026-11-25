import SwiftUI
import AppIntents
import ProbeCore

struct BuildAndInstallIntent: AppIntent {
    static var title: LocalizedStringResource = "Build & Install"
    static var description = IntentDescription("Build the selected app on your Mac, download it, and install it using your network helpers.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "requestedBuildInstall")
        NotificationCenter.default.post(name: .init("requestedBuildInstall"), object: nil)
        return .result()
    }
}
struct ProbeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BuildAndInstallIntent(), phrases: ["Build and install with \(.applicationName)"], shortTitle: "Build & Install", systemImageName: "hammer.fill")
    }
}

extension ProbeModel {
    func saveFlow() {
        if let flow, let data = try? JSONEncoder().encode(flow) {
            UserDefaults.standard.set(data, forKey: "buildInstallFlow")
        }
    }
    func loadFlow() {
        guard let data = UserDefaults.standard.data(forKey: "buildInstallFlow"),
              var restored = try? JSONDecoder().decode(BuildFlowState.self, from: data) else { return }
        if [.checking, .building, .downloading, .installing].contains(restored.phase), !MasterCoordinator.shared.working {
            restored.phase = .interrupted
            restored.result = "The app stopped mid-process. Restore Internet first. An installation may have completed; check the target app."
        }
        flow = restored
        if restored.phase != .done { liveStatus = "Previous flow paused. Use Restore Internet to recover." }
    }
    func consumeBuildRequest() {
        guard UserDefaults.standard.bool(forKey: "requestedBuildInstall") else { return }
        UserDefaults.standard.removeObject(forKey: "requestedBuildInstall")
        startBuildInstall()
    }
    func startLegacyBuildInstall() {
        guard !busy, !catalogLoading, flowIsIdle else { return }
        guard pairingReady, downloadReady, helpersReady else {
            liveStatus = "Complete the private preparation and network helper setup first."
            return
        }
        guard wifiPath == "Not available" else {
            liveStatus = "Turn Wi-Fi off in Settings before this cellular test."
            return
        }
        guard let selection = projectCache.selection else {
            liveStatus = "Select a project and scheme first."
            return
        }
        flow = BuildFlowState()
        flow?.selection = selection
        flow?.phase = .checking
        saveFlow()
        let identifier = flow!.job
        busy = true
        liveStatus = "Checking the private Mac connection…"
        Task {
            let check = await BuildDownloader.checkMacConnection()
            reports.append(check.diagnostic + (check.reachable ? "\nConnect helper: skipped." : "\nConnect helper: required."))
            UserDefaults.standard.set(reports, forKey: "sanitizedReports")
            busy = false
            guard flow?.job == identifier, flow?.phase == .checking else { return }
            if check.reachable { await buildAndDownload() }
            else { handoff(.connect) }
        }
    }
    func handoff(_ phase: BuildFlowState.Phase) {
        guard flow != nil else { return }
        flow?.handoff(phase)
        saveFlow()
        let name: String
        switch phase {
        case .connect: name = "Probe Connect to Mac"
        case .prepare: name = "Probe Prepare Installation"
        default: name = "Probe Restore Internet"
        }
        liveStatus = "Running \(name)…"
        UIApplication.shared.open(flow!.shortcutURL(name: name)) { [weak self] opened in
            Task { @MainActor in
                if !opened { self?.liveStatus = "Could not open Shortcuts. Use Restore Internet and check helper setup." }
            }
        }
    }
    func restoreInternet() {
        guard !busy else { return }
        if flow == nil { flow = BuildFlowState() }
        flow?.purpose = nil
        flow?.started = Date()
        handoff(.restore)
    }
    func handleCallback(_ url: URL) {
        if let current = MasterCoordinator.load(), current.acceptsMasterCallback(url) {
            let outcome = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "outcome" }?.value
            var updated = current
            updated.phase = .interrupted
            updated.nonce = UUID()
            updated.result = outcome == "success" ? "Master Shortcut ended without a final result. Check the installed app and restore internet." : "Master Shortcut was cancelled or failed. Run Restore Internet; an install may have completed."
            MasterCoordinator.save(updated)
            syncMasterFlow()
            return
        }
        guard !busy, let current = flow, current.accepts(url) else { return }
        let success = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "outcome" }.map(\.value) == ["success"]
        // Consume before scheduling work; duplicate callbacks cannot install twice.
        flow?.nonce = UUID()
        saveFlow()
        if !success {
            flow?.result = "Network helper was cancelled or failed. No further installation was started."
            flow?.phase = .interrupted
            saveFlow()
            liveStatus = "Helper failed. Tap Restore Internet; if unavailable, turn Cellular Data on in Settings."
            return
        }
        switch current.phase {
        case .connect:
            Task {
                if current.purpose == "catalog" {
                    await refreshProjects(afterConnecting: true)
                    flow?.phase = .done
                    liveStatus = "Mac connection helper completed."
                    saveFlow()
                } else { await buildAndDownload() }
            }
        case .prepare: Task { await installDownloadedBuild() }
        case .restore:
            flow?.phase = .done
            liveStatus = (flow?.result.isEmpty == false ? flow!.result : "Recovery complete.") + " Internet restoration helper completed."
            saveFlow()
        default: break
        }
    }
    func buildAndDownload() async {
        guard !busy, let identifier = flow?.job, let selection = flow?.selection else { return }
        busy = true
        flow?.phase = .building
        saveFlow()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do {
            var job: BuildDownloader.Job?
            // Tailscale's action can finish before the route is ready. Reuse the same UUID.
            for attempt in 0..<6 {
                do { job = try await BuildDownloader.job(id: identifier, submit: true, selection: selection); break }
                catch {
                    if attempt == 5 { throw error }
                    liveStatus = "Waiting for the private Mac connection…"
                    try await Task.sleep(for: .seconds(2))
                }
            }
            let deadline = Date().addingTimeInterval(1000)
            while job?.status == "building", Date() < deadline {
                liveStatus = "Building and signing on your Mac… Keep this app open."
                try await Task.sleep(for: .seconds(3))
                job = try await BuildDownloader.job(id: identifier, submit: false, selection: selection)
            }
            guard let ready = job, ready.status == "ready", let selected = ready.manifest else {
                if job?.status == "failed" { liveStatus = job?.message ?? "Build failed." }
                throw DownloadIssue.invalidResponse
            }
            candidate = try await BuildDownloader.download(job: ready, selection: selection) { [weak self] message in
                Task { @MainActor in self?.liveStatus = message }
            }
            flow?.artifactHash = selected.sha256
            refreshSource()
            saveFlow()
            handoff(.prepare)
        } catch {
            flow?.result = "Build or download failed; installation was not started. Check the Mac and retry."
            if liveStatus.hasPrefix("Xcode ") || liveStatus.hasPrefix("Choose a scheme") { flow?.result = liveStatus }
            if let failure = error as? DownloadConnectionFailure {
                reports.append("Build & Install connection: \(failure.diagnostic)")
            } else if case DownloadIssue.http(let status) = error {
                reports.append("Build & Install HTTP status: \(status)")
            }
            persistFlowReport()
            handoff(.restore)
        }
    }
    func installDownloadedBuild() async {
        guard !busy else { return }
        busy = true
        flow?.phase = .installing
        saveFlow()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        let reminder = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.liveStatus = "Still waiting for the installation service. Do not start another install. If you leave the app, use the standalone Restore Internet Shortcut; the installation outcome may be unknown."
        }
        defer { reminder.cancel() }
        do {
            let selected = try InstallCandidate.load()
            guard selected.sha256 == flow?.artifactHash, wifiPath == "Not available" else { throw DownloadIssue.invalidResponse }
            try selected.verifyArtifact(at: InstallCandidate.artifactURL())
            liveStatus = "Waiting for the local installation connection…"
            // An actual TCP check, not merely a successful Shortcut callback.
            var ready = false
            for _ in 0..<3 {
                let result = await DeviceProbe().run(host: "10.7.0.1", kind: .remotePairing)
                if result.tcpAccepted { ready = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            guard ready else { throw DownloadIssue.invalidResponse }
            let result = await AuthenticatedProbe.runResult(host: "10.7.0.1", bundleID: Bundle.main.bundleIdentifier ?? "", installStaged: true) { [weak self] message in
                Task { @MainActor in self?.liveStatus = message }
            }
            reports.append((["Build & Install"] + result.lines).joined(separator: "\n"))
            switch result.outcome {
            case .verified: flow?.result = "Installed \(selected.displayName) build \(selected.buildVersion). Open the app to test it."
            case .alreadyInstalled: flow?.result = "The selected build is already installed."
            case .unverified: flow?.result = "Installation outcome is uncertain. Check the installed app before retrying."
            case .notRequested: flow?.result = "Local installation connection failed; no install request was sent."
            }
        } catch {
            flow?.result = "Offline preparation or artifact check failed; no installation was requested."
        }
        persistFlowReport()
        handoff(.restore)
    }
    func persistFlowReport() {
        if let result = flow?.result, !result.isEmpty { reports.append(result) }
        UserDefaults.standard.set(reports, forKey: "sanitizedReports")
        saveFlow()
    }
}
