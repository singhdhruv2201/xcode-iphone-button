import SwiftUI
import ProbeCore

struct ProjectBrowser: View {
    @ObservedObject var model: ProbeModel
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var visibleProjects: [MacProject] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ProbeHeading(title: "Projects")
                Text("ON YOUR MAC").font(.system(.caption2, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                if model.projectCache.projects.isEmpty {
                    ContentUnavailableView("Find your projects", systemImage: "folder.badge.plus", description: Text(model.downloadReady && model.helpersReady ? "Connect to your Mac to see projects in its configured folders." : "Complete the setup guide in Settings, then connect to see your Mac’s projects."))
                } else if visibleProjects.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(visibleProjects) { project in
                    NavigationLink(value: project.id) {
                        ProbeCard {
                            ProbeRow(title: project.name, detail: project.displayPath,
                                     symbol: model.projectCache.selection?.projectID == project.id ? "checkmark.square.fill" : "folder.fill")
                        }
                    }.buttonStyle(ProbePressStyle()).disabled(!model.canChangeProject)
                }
                if model.catalogLoading { ProgressView("Loading from Xcode…").padding(.vertical) }
                if !model.catalogMessage.isEmpty { Text(model.catalogMessage).font(.footnote).foregroundStyle(.secondary) }
                Button("Connect & Refresh", systemImage: "network") { model.connectAndRefresh() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canChangeProject || !model.helpersReady || !model.downloadReady)
                Button("Refresh projects", systemImage: "arrow.clockwise") { Task { await model.refreshProjects() } }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!model.canChangeProject || !model.downloadReady)
                if let refreshed = model.projectCache.refreshed {
                    Text("Last refreshed \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Projects can stay closed on your Mac. Refresh to discover new ones.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: 640).padding(22).frame(maxWidth: .infinity)
        }
        .background(ProbePalette.canvas(scheme))
        .navigationTitle("Projects").navigationBarTitleDisplayMode(.inline)
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
