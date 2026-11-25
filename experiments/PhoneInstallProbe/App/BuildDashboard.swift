import SwiftUI
import ProbeCore

struct BuildDashboard: View {
    @ObservedObject var model: ProbeModel
    let chooseProject: () -> Void
    let openSetup: () -> Void
    @State private var buildTap = 0

    private var setupReady: Bool { model.pairingReady && model.downloadReady && model.helpersReady && model.masterReady }
    private var canBuild: Bool {
        setupReady && !model.busy && !model.catalogLoading && model.flowIsIdle && model.projectCache.selection != nil
    }
    private var active: Bool { !model.flowIsIdle || model.busy }

    var body: some View {
        List {
            if !setupReady {
                Section {
                    Button(action: openSetup) {
                        Label("Finish Setup", systemImage: "checklist")
                    }.disabled(active)
                } footer: {
                    Text("Connect your Mac and add the Shortcuts before your first build.")
                }
            }
            Section {
                Button(action: chooseProject) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.projectCache.selection?.projectName ?? "Choose a Project")
                                .foregroundStyle(.primary)
                            Text(model.projectCache.selection?.scheme ?? "Browse projects on your Mac")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "folder") }
                }.disabled(active)
                LabeledContent("Install on", value: "This iPhone")
            } header: { Text("Selected App") }
            Section {
                Button {
                    buildTap += 1
                    model.startBuildInstall()
                } label: {
                    Label(active ? "Build in Progress" : "Build & Install", systemImage: "hammer.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canBuild)
                .sensoryFeedback(.impact(weight: .medium), trigger: buildTap)
                .accessibilityHint("Builds the selected app on your Mac and starts the master Shortcut.")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text(model.wifiPath == "Available"
                     ? "Turn Wi-Fi off in Settings before building. Unplug USB and keep cellular on."
                     : "Keep your iPhone unlocked and USB unplugged. Internet pauses briefly during installation.")
            }
            if !model.liveStatus.isEmpty {
                Section("Latest Status") {
                    BuildStatusRow(phase: model.flow?.phase, message: model.liveStatus, busy: model.busy)
                }
            }
            Section("Mac Connection") { MacConnectionRow(model: model) }
            if active || model.flow != nil {
                Section {
                    Button("Restore Internet", systemImage: "antenna.radiowaves.left.and.right") { model.restoreInternet() }
                        .disabled(model.busy)
                } footer: { Text("Use this if a run stops before your internet connection returns.") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Build")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct MacConnectionRow: View {
    @ObservedObject var model: ProbeModel
    private var title: String {
        if !model.downloadReady { return "Mac Not Configured" }
        if let reachable = model.connectionReachable { return reachable ? "Connection Verified" : "Mac Not Reachable" }
        return "Check Connection"
    }
    private var detail: String {
        if let date = model.connectionCheckedAt {
            return "Last checked \(date.formatted(date: .omitted, time: .shortened)). Tap to check again."
        }
        return model.downloadReady ? "Check your private connection to the Mac." : "Complete private USB preparation in Settings."
    }
    var body: some View {
        Button { Task { await model.diagnoseMacConnection() } } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "laptopcomputer") }
        }
        .disabled(!model.downloadReady || model.busy || model.catalogLoading || !model.flowIsIdle)
    }
}

struct BuildStatusRow: View {
    let phase: BuildFlowState.Phase?
    let message: String
    let busy: Bool
    private var title: String {
        switch phase {
        case .master, .connect, .checking: "Connecting"
        case .building: "Building on your Mac"
        case .downloadReady, .downloading: "Downloading your build"
        case .installReady, .prepare: "Preparing installation"
        case .installing: "Installing on this iPhone"
        case .restore: "Restoring internet"
        case .interrupted: "Needs attention"
        case .done: "Run finished"
        case nil: "Status"
        }
    }
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if busy { ProgressView().accessibilityLabel(title) }
                }
                Text(message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
