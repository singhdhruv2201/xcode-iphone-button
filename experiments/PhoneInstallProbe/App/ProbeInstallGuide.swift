import SwiftUI

struct ProbeInstallGuide: View {
    @ObservedObject var model: ProbeModel
    @Binding var stepIndex: Int
    let requestedResource: InstallResource?
    var onComplete: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openFailed = false
    private var step: InstallStep { InstallStep(rawValue: stepIndex) ?? .welcome }
    private var canContinue: Bool {
        !model.busy && model.flowIsIdle && (step != .pairing || (model.pairingReady && model.downloadReady))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ProbeHeading(title: "Setup guide")
                        VStack(alignment: .leading, spacing: 10) {
                            Text(step.progress.uppercased()).font(.system(.caption2, design: .monospaced)).tracking(1.5).foregroundStyle(.secondary)
                            ProgressView(value: Double(step.rawValue + 1), total: Double(InstallStep.allCases.count))
                                .accessibilityLabel("Setup progress").accessibilityValue(step.progress)
                                .animation(reduceMotion ? nil : .smooth, value: step)
                        }
                        VStack(spacing: 12) {
                            Text(step.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                            Text(step.instructions).font(.body).foregroundStyle(.secondary)
                        }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        VStack(spacing: 10) {
                            ForEach(step.resources, id: \.self) { resource in
                                resourceControl(resource).id(resource)
                            }
                        }
                        if step == .pairing {
                            ProbeCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label(model.pairingStatus, systemImage: model.pairingReady ? "checkmark.circle.fill" : "circle")
                                    Label(model.downloadStatus, systemImage: model.downloadReady ? "checkmark.circle.fill" : "circle")
                                }.font(.subheadline)
                            }
                        }
                        if step == .project {
                            NavigationLink {
                                ProjectBrowser(model: model)
                            } label: {
                                ProbeCard { ProbeRow(title: "Projects on your Mac", detail: model.projectCache.selection?.projectName ?? "Connect, refresh and choose a scheme", symbol: "folder.fill") }
                            }.buttonStyle(ProbePressStyle())
                        }
                    }
                    .frame(maxWidth: 580).padding(22).frame(maxWidth: .infinity)
                    .id(step)
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
            .background(ProbePalette.canvas(scheme))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        if step == .recoveryTest { model.helpersReady = true }
                        if step == .master { model.masterReady = true }
                        if step == .result {
                            stepIndex = 0
                            onComplete()
                            dismiss()
                        } else { stepIndex = step.rawValue + 1 }
                    } label: {
                        Text(step.nextTitle).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canContinue)
                    if step != .welcome {
                        Button("Previous step") { stepIndex = step.rawValue - 1 }
                            .frame(minHeight: 44).disabled(model.busy || !model.flowIsIdle)
                    }
                }
                .frame(maxWidth: 580).padding(.horizontal, 22).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(ProbePalette.canvas(scheme))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .navigationBarTitleDisplayMode(.inline)
            .alert("Couldn’t open the link", isPresented: $openFailed) {
                Button("OK", role: .cancel) {}
            } message: { Text("For internet recovery, open Shortcuts and run Probe Restore Internet. If it’s missing, return to the helper step to add it.") }
        }
        .tint(ProbePalette.accent(scheme))
    }

    @ViewBuilder private func resourceControl(_ resource: InstallResource) -> some View {
        if resource.isImport {
            if let file = Bundle.main.url(forResource: resource.title, withExtension: "shortcut") {
                ShareLink(item: file) {
                    ProbeCard { ProbeRow(title: "Add " + resource.title, detail: resource.detail, symbol: resource.icon) }
                }
                .buttonStyle(ProbePressStyle())
                .accessibilityHint("Choose Shortcuts, then Add Shortcut.")
            } else {
                ProbeCard {
                    Label("Missing signed file for " + resource.title + ". Generate the shortcuts on your Mac and rebuild Phone Install Probe.", systemImage: "exclamationmark.triangle")
                }
            }
        } else if resource == .preparation {
            Button { model.refreshPairing() } label: {
                ProbeCard { ProbeRow(title: resource.title, detail: resource.detail, symbol: resource.icon) }
            }.buttonStyle(ProbePressStyle()).disabled(model.busy || !model.flowIsIdle)
        } else if resource == .testRestore {
            Button {
                openURL(resource.url) { opened in openFailed = !opened }
            } label: {
                ProbeCard { ProbeRow(title: resource.title, detail: resource.detail, symbol: resource.icon) }
            }.buttonStyle(ProbePressStyle()).disabled(model.busy || !model.flowIsIdle)
        } else {
            Link(destination: resource.url) {
                ProbeCard { ProbeRow(title: resource.title, detail: resource.detail, symbol: resource.icon) }
            }.buttonStyle(ProbePressStyle())
        }
    }
}
