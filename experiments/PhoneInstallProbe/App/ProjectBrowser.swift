import SwiftUI
import ProbeCore

struct ProjectBrowser: View {
    @ObservedObject var model: ProbeModel
    @State private var query = ""
    @State private var visibleProjects: [MacProject] = []

    var body: some View {
        List {
            Section {
                if model.projectCache.projects.isEmpty {
                    ContentUnavailableView("No Projects", systemImage: "folder", description: Text(model.downloadReady && model.helpersReady ? "Connect to your Mac to find projects in its configured folders." : "Complete the setup guide in Settings to connect to your Mac."))
                } else if visibleProjects.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(visibleProjects) { project in
                    NavigationLink(value: project.id) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                Text(project.displayPath).font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: model.projectCache.selection?.projectID == project.id ? "checkmark.circle" : "folder")
                                .foregroundStyle(.tint)
                                .accessibilityLabel(model.projectCache.selection?.projectID == project.id ? "Selected project" : "Project")
                        }
                    }.disabled(!model.canChangeProject)
                }
            } header: { Text("On Your Mac") } footer: {
                Text("Choose a project, then its app scheme. Projects can stay closed on your Mac.")
            }
            Section {
                if model.catalogLoading { ProgressView("Loading from Xcode…") }
                if !model.catalogMessage.isEmpty { Text(model.catalogMessage).font(.subheadline).foregroundStyle(.secondary) }
                Button("Connect & Refresh", systemImage: "network") { model.connectAndRefresh() }
                    .disabled(!model.canChangeProject || !model.helpersReady || !model.downloadReady)
                Button("Refresh Projects", systemImage: "arrow.clockwise") { Task { await model.refreshProjects() } }
                    .disabled(!model.canChangeProject || !model.downloadReady)
            } footer: {
                if let refreshed = model.projectCache.refreshed {
                    Text("Last refreshed \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Find a project")
        .refreshable { await model.refreshProjects() }
        .onChange(of: query, initial: true) { filterProjects() }
        .onChange(of: model.projectCache.projects) { filterProjects() }
        .navigationDestination(for: String.self) { identifier in
            ProjectSchemeScreen(model: model, projectID: identifier)
        }
    }

    private func filterProjects() {
        visibleProjects = model.projectCache.projects.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.displayPath.localizedStandardContains(query)
        }
    }
}

struct ProjectSchemeScreen: View {
    @ObservedObject var model: ProbeModel
    let projectID: String
    @Environment(\.dismiss) private var dismiss
    private var project: MacProject? { model.projectCache.projects.first { $0.id == projectID } }

    var body: some View {
        List {
            if let project {
                Section {
                    Label(project.name, systemImage: "square.3.layers.3d").font(.headline)
                    Text(project.displayPath).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Choose an app scheme") {
                    if model.catalogLoading { ProgressView("Loading schemes from Xcode…") }
                    ForEach(model.availableSchemes, id: \.self) { name in
                        Button {
                            model.rememberScheme(name)
                            dismiss()
                        } label: {
                            HStack {
                                Text(name).foregroundStyle(.primary)
                                Spacer()
                                if model.selectedScheme == name { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                            }.frame(minHeight: 44)
                        }.disabled(!model.canChangeProject || model.selectedProjectID != projectID)
                    }
                    if !model.catalogMessage.isEmpty { Text(model.catalogMessage).font(.footnote).foregroundStyle(.secondary) }
                    Button("Reload schemes", systemImage: "arrow.clockwise") { Task { await model.chooseProject(projectID) } }
                        .disabled(!model.canChangeProject)
                }
                Section {
                    Text("Choose the scheme that builds your iPhone app. Then return to Build to install it.")
                }
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark", description: Text("Return to Projects and refresh your Mac's folders."))
            }
        }
        .navigationTitle("App scheme").navigationBarTitleDisplayMode(.inline)
        .task(id: projectID) { await model.chooseProject(projectID) }
    }
}
