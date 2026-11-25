import SwiftUI
import ProbeCore

struct BuildDashboard: View {
    @ObservedObject var model: ProbeModel
    let chooseProject: () -> Void
    let openSetup: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var buildTap = 0

    private var setupReady: Bool { model.pairingReady && model.downloadReady && model.helpersReady && model.masterReady }
    private var canBuild: Bool {
        setupReady && !model.busy && !model.catalogLoading && model.flowIsIdle && model.projectCache.selection != nil
    }
    private var active: Bool { !model.flowIsIdle || model.busy }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    ProbeHeading(title: "Build")
                    MacConnectionCard(model: model)
                    if !setupReady {
                        Button(action: openSetup) {
                            ProbeCard { ProbeRow(title: "Finish your setup", detail: "Connect your Mac and add the Shortcuts", symbol: "checklist") }
                        }.buttonStyle(ProbePressStyle()).disabled(active)
                    }
                    Spacer(minLength: 8)
                    Button {
                        buildTap += 1
                        model.startBuildInstall()
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: active ? "arrow.triangle.2.circlepath" : "hammer.fill")
                                .font(.system(.largeTitle).weight(.semibold))
                                .accessibilityHidden(true)
                            Text(active ? "Build in progress" : "Build & Install").font(.title3.bold())
                            Text(model.projectCache.selection?.projectName ?? "Choose a project")
                                .font(.subheadline).lineLimit(2)
                        }
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(28)
                        .frame(width: typeSize.isAccessibilitySize ? nil : 228,
                               height: typeSize.isAccessibilitySize ? nil : 228)
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                        .background {
                            if typeSize.isAccessibilitySize {
                                RoundedRectangle(cornerRadius: 32).fill(heroGradient)
                            } else { Circle().fill(heroGradient) }
                        }
                        .shadow(color: ProbePalette.accent(scheme).opacity(canBuild ? 0.2 : 0.07), radius: 18, y: 8)
                    }
                    .buttonStyle(ProbePressStyle())
                    .disabled(!canBuild)
                    .opacity(canBuild || active ? 1 : 0.55)
                    .sensoryFeedback(.impact(weight: .medium), trigger: buildTap)
                    .accessibilityHint("Builds the selected app on your Mac and starts the master Shortcut.")
                    if !model.liveStatus.isEmpty {
                        BuildStatusCard(phase: model.flow?.phase, message: model.liveStatus, busy: model.busy)
                            .transition(.opacity)
                    } else {
                        Text("Your Mac builds. Your iPhone installs.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("BUILD TARGET").font(.system(.caption2, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                        Button(action: chooseProject) {
                            ProbeCard {
                                ProbeRow(title: model.projectCache.selection?.projectName ?? "Choose a project",
                                         detail: model.projectCache.selection.map { "\($0.scheme) · This iPhone" } ?? "Browse projects on your Mac",
                                         symbol: "square.3.layers.3d")
                            }
                        }.buttonStyle(ProbePressStyle())
                        Text(model.wifiPath == "Available" ? "Turn Wi-Fi off in Settings before building. Unplug USB and keep cellular on." : "Keep your phone unlocked and USB unplugged. Internet pauses briefly during installation.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if active || model.flow != nil {
                        Button("Restore Internet", systemImage: "antenna.radiowaves.left.and.right") { model.restoreInternet() }
                            .buttonStyle(.bordered).disabled(model.busy)
                    }
                }
                .frame(maxWidth: 580)
                .padding(.horizontal, 22).padding(.vertical, 16)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .frame(maxWidth: .infinity)
            }
        }
        .background(ProbePalette.canvas(scheme))
        .toolbar(.hidden, for: .navigationBar)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: active)
    }

    private var heroGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.22, green: 0.43, blue: 1), Color(red: 0.12, green: 0.24, blue: 0.76)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct MacConnectionCard: View {
    @ObservedObject var model: ProbeModel
    private var title: String {
        if !model.downloadReady { return "Connect your Mac" }
        if let reachable = model.connectionReachable { return reachable ? "Mac connection verified" : "Mac not reachable" }
        return "Mac configured"
    }
    private var detail: String {
        if let date = model.connectionCheckedAt {
            return "Last checked \(date.formatted(date: .omitted, time: .shortened)) · Tap to recheck"
        }
        return model.downloadReady ? "Tap to check your private connection" : "Complete private USB preparation in Settings"
    }
    var body: some View {
        Button { Task { await model.diagnoseMacConnection() } } label: {
            ProbeCard { ProbeRow(title: title, detail: detail, symbol: "laptopcomputer", chevron: false) }
        }
        .buttonStyle(ProbePressStyle())
        .disabled(!model.downloadReady || model.busy || model.catalogLoading || !model.flowIsIdle)
    }
}

struct BuildStatusCard: View {
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
        ProbeCard {
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
