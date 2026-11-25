import SwiftUI

struct ProbeInstallGuide: View {
    @ObservedObject var model: ProbeModel
    @Binding var stepIndex: Int
    let requestedResource: InstallResource?
    var onComplete: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openFailed = false
    private var step: InstallStep { InstallStep(rawValue: stepIndex) ?? .welcome }
    private var canContinue: Bool {
        !model.busy && model.flowIsIdle && (step != .pairing || (model.pairingReady && model.downloadReady))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(step.progress).font(.subheadline).foregroundStyle(.secondary)
                            ProgressView(value: Double(step.rawValue + 1), total: Double(InstallStep.allCases.count))
                                .accessibilityLabel("Setup progress").accessibilityValue(step.progress)
                                .animation(reduceMotion ? nil : .smooth, value: step)
                            Text(step.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                            Text(step.instructions)
                        }.padding(.vertical, 4)
                    }.id(step)
                    if !step.resources.isEmpty {
                        Section {
                            ForEach(step.resources, id: \.self) { resource in
                                resourceControl(resource).id(resource)
                            }
                        }
                    }
                    if step == .pairing {
                        Section("Preparation Status") {
                            Label(model.pairingStatus, systemImage: model.pairingReady ? "checkmark.circle" : "circle")
                            Label(model.downloadStatus, systemImage: model.downloadReady ? "checkmark.circle" : "circle")
                        }
                    }
                    if step == .project {
                        Section {
                            NavigationLink { ProjectBrowser(model: model) } label: {
                                Label("Projects on Your Mac", systemImage: "folder")
                            }
                        }
                    }
                    Section {
                        Button(action: advance) {
                            Text(step.nextTitle).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canContinue)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                    if step != .welcome {
                        Section {
                            Button("Previous Step", systemImage: "chevron.left") { stepIndex = step.rawValue - 1 }
                                .disabled(model.busy || !model.flowIsIdle)
                        }
                    }
                }
                .task(id: requestedResource) {
                    if let requestedResource, step.resources.contains(requestedResource) {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        reader.scrollTo(requestedResource, anchor: .center)
                    }
                }
                .onChange(of: step) { reader.scrollTo(step, anchor: .top) }
            }
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .alert("Couldn’t open the link", isPresented: $openFailed) {
                Button("OK", role: .cancel) {}
            } message: { Text("For internet recovery, open Shortcuts and run Probe Restore Internet. If it’s missing, return to the helper step to add it.") }
        }
        .tint(.blue)
    }

    private func advance() {
        if step == .recoveryTest { model.helpersReady = true }
        if step == .master { model.masterReady = true }
        if step == .result {
            stepIndex = 0
            onComplete()
            dismiss()
        } else { stepIndex = step.rawValue + 1 }
    }

    private func resourceLabel(_ resource: InstallResource, importing: Bool = false) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text((importing ? "Add " : "") + resource.title)
                Text(resource.detail).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: resource.icon) }
    }

    @ViewBuilder private func resourceControl(_ resource: InstallResource) -> some View {
        if resource.isImport {
            if let file = Bundle.main.url(forResource: resource.title, withExtension: "shortcut") {
                ShareLink(item: file) { resourceLabel(resource, importing: true) }
                    .accessibilityHint("Choose Shortcuts, then Add Shortcut.")
            } else {
                Label("Missing signed file for " + resource.title + ". Generate the shortcuts on your Mac and rebuild Phone Install Probe.", systemImage: "exclamationmark.triangle")
            }
        } else if resource == .preparation {
            Button { model.refreshPairing() } label: { resourceLabel(resource) }
                .disabled(model.busy || !model.flowIsIdle)
        } else if resource == .testRestore {
            Button { openURL(resource.url) { opened in openFailed = !opened } } label: { resourceLabel(resource) }
                .disabled(model.busy || !model.flowIsIdle)
        } else {
            Link(destination: resource.url) { resourceLabel(resource) }
        }
    }
}
