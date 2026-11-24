import SwiftUI
import ProbeCore

extension ProbeModel {
    var flowIsIdle: Bool { flow == nil || flow?.phase == .done }
    var canChangeProject: Bool { !busy && !catalogLoading && flowIsIdle }

    func connectAndRefresh() {
        guard canChangeProject, helpersReady, downloadReady else { return }
        flow = BuildFlowState()
        flow?.purpose = "catalog"
        handoff(.connect)
    }

    func refreshProjects(afterConnecting: Bool = false) async {
        guard !busy, !catalogLoading, flowIsIdle || afterConnecting else { return }
        catalogLoading = true
        catalogMessage = "Finding projects on your Mac…"
        defer { catalogLoading = false }
        do {
            var list: ProjectList?
            for attempt in 0..<(afterConnecting ? 5 : 1) {
                do { list = try await ProjectCatalogClient.projects(); break }
                catch {
                    if !afterConnecting || attempt == 4 { throw error }
                    try await Task.sleep(for: .seconds(2))
                }
            }
            guard let list else { throw DownloadIssue.invalidResponse }
            projectCache.projects = list.projects
            projectCache.refreshed = Date()
            if !list.projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = ""
                selectedScheme = ""
                availableSchemes = []
                projectCache.selection = nil
            }
            projectCache.save()
            catalogMessage = list.limited ? "Scan limit reached. Narrow the Mac’s configured folders to see other projects." : (list.projects.isEmpty ? "No projects found in the Mac’s configured folders." : "Projects refreshed from Mac.")
            if !selectedProjectID.isEmpty { try await loadSelectedSchemes() }
        } catch {
            catalogMessage = "Could not refresh. Keep the Mac awake and try Connect & Refresh. Your saved list is still available."
        }
    }

    func chooseProject(_ identifier: String) async {
        guard canChangeProject else { return }
        selectedProjectID = identifier
        selectedScheme = ""
        availableSchemes = []
        projectCache.selection = nil
        projectCache.save()
        guard !identifier.isEmpty else { return }
        catalogLoading = true
        catalogMessage = "Loading schemes from Xcode…"
        defer { catalogLoading = false }
        do { try await loadSelectedSchemes() }
        catch { catalogMessage = "Could not load schemes. Connect to your Mac and refresh." }
    }

    private func loadSelectedSchemes() async throws {
        let identifier = selectedProjectID
        let result = try await ProjectCatalogClient.schemes(for: identifier)
        guard identifier == selectedProjectID else { return }
        availableSchemes = result.schemes
        if !availableSchemes.contains(selectedScheme) {
            selectedScheme = availableSchemes.count == 1 ? availableSchemes[0] : ""
        }
        rememberScheme(selectedScheme)
        catalogMessage = availableSchemes.isEmpty ? "No schemes found. Create or share an iPhone app scheme in Xcode." : "Select the scheme that builds your iPhone app."
    }

    func rememberScheme(_ scheme: String) {
        selectedScheme = scheme
        if availableSchemes.contains(scheme), let project = projectCache.projects.first(where: { $0.id == selectedProjectID }) {
            projectCache.selection = project.selection(scheme: scheme)
        } else { projectCache.selection = nil }
        projectCache.save()
    }
}

struct ProjectPickerSection: View {
    @ObservedObject var model: ProbeModel
    var body: some View {
        Section("Projects on your Mac") {
            Picker("Project", selection: Binding(get: { model.selectedProjectID }, set: { identifier in
                Task { await model.chooseProject(identifier) }
            })) {
                Text("Choose a project").tag("")
                ForEach(model.projectCache.projects) { project in
                    Text("\(project.name) · \(project.kind)").tag(project.id)
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(!model.canChangeProject)
            if let project = model.projectCache.projects.first(where: { $0.id == model.selectedProjectID }) {
                Text(project.displayPath).font(.caption).foregroundStyle(.secondary)
                Picker("Scheme", selection: Binding(get: { model.selectedScheme }, set: { model.rememberScheme($0) })) {
                    Text("Choose an app scheme").tag("")
                    ForEach(model.availableSchemes, id: \.self) { Text($0).tag($0) }
                }.disabled(!model.canChangeProject || model.availableSchemes.isEmpty)
            }
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshProjects() } }
                    .disabled(!model.canChangeProject || !model.downloadReady)
                Spacer()
                if model.catalogLoading { ProgressView() }
            }
            Button("Connect & Refresh", systemImage: "network") { model.connectAndRefresh() }
                .disabled(!model.canChangeProject || !model.helpersReady || !model.downloadReady)
            if !model.catalogMessage.isEmpty { Text(model.catalogMessage).font(.footnote).foregroundStyle(.secondary) }
            if let refreshed = model.projectCache.refreshed {
                Text("Last refreshed \(refreshed.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Text("Projects can stay closed on your Mac. Your selection is remembered for the next build.").font(.caption)
        }
    }
}
