import SwiftUI

@MainActor
struct ProbeView: View {
    enum Tab: Hashable { case build, projects, activity, settings }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = ProbeModel()
    @AppStorage("probeAppearance") private var appearance = ProbeAppearance.system
    @AppStorage("iphoneGuidePresented") private var guidePresentedBefore = false
    @AppStorage("iphoneGuideStep") private var guideStep = 0
    @State private var selectedTab = Tab.build
    @State private var guide: GuidePresentation?

    private struct GuidePresentation: Identifiable {
        let id = UUID()
        var resource: InstallResource?
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                BuildDashboard(model: model, chooseProject: { selectedTab = .projects }, openSetup: presentGuide)
            }.tabItem { Label("Build", systemImage: "hammer.fill") }.tag(Tab.build)
            NavigationStack {
                ProjectBrowser(model: model)
            }.tabItem { Label("Projects", systemImage: "folder.fill") }.tag(Tab.projects)
            NavigationStack {
                ProbeActivity(model: model)
            }.tabItem { Label("Activity", systemImage: "waveform.path.ecg") }.tag(Tab.activity)
            NavigationStack {
                ProbeSettings(model: model, appearance: $appearance, openSetup: presentGuide)
            }.tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(Tab.settings)
        }
        .tint(ProbePalette.accent(appearance.scheme ?? colorScheme))
        .preferredColorScheme(appearance.scheme)
        .task {
            model.refreshPairing()
            model.consumeBuildRequest()
            if !guidePresentedBefore && model.flowIsIdle && !model.busy { presentGuide() }
            if model.downloadReady && model.flowIsIdle { await model.refreshProjects() }
        }
        .sheet(item: $guide) { presentation in
            ProbeInstallGuide(model: model, stepIndex: $guideStep, requestedResource: presentation.resource,
                              onComplete: { selectedTab = .projects })
                .preferredColorScheme(appearance.scheme)
        }
        .onOpenURL { url in
            if url.scheme == "phoneinstallprobe", url.host == "setup" {
                guard !model.busy, model.flowIsIdle,
                      let item = InstallResource(rawValue: url.lastPathComponent),
                      item.isImport || item == .preparation,
                      let step = InstallStep.allCases.first(where: { $0.resources.contains(item) }) else { return }
                guideStep = step.rawValue
                guidePresentedBefore = true
                guide = GuidePresentation(resource: item)
            } else {
                guide = nil
                selectedTab = .build
                model.handleCallback(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("masterFlowChanged"))) { _ in
            model.syncMasterFlow()
            if !model.flowIsIdle { guide = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("requestedBuildInstall"))) { _ in
            guide = nil
            selectedTab = .build
            model.consumeBuildRequest()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.syncMasterFlow(); model.refreshPairing(); model.consumeBuildRequest() }
        }
    }

    private func presentGuide() {
        guard !model.busy, model.flowIsIdle else { return }
        guidePresentedBefore = true
        guide = GuidePresentation()
    }
}
