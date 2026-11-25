import SwiftUI

struct ProbeSettings: View {
    @ObservedObject var model: ProbeModel
    @Binding var appearance: ProbeAppearance
    let openSetup: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProbeHeading(title: "Settings")
                Text("SETUP").font(.system(.caption2, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                Button(action: openSetup) {
                    ProbeCard { ProbeRow(title: "Setup guide", detail: "Pick up where you left off", symbol: "book.closed.fill") }
                }.buttonStyle(ProbePressStyle()).disabled(model.busy || !model.flowIsIdle)
                NavigationLink {
                    ProbeShortcutSettings(model: model)
                } label: {
                    ProbeCard { ProbeRow(title: "Shortcuts installer", detail: "Add or revisit the four Shortcuts", symbol: "square.3.layers.3d") }
                }.buttonStyle(ProbePressStyle())
                NavigationLink {
                    ProbeConnectionSettings(model: model)
                } label: {
                    ProbeCard { ProbeRow(title: "Mac & pairing", detail: "Private preparation and connection check", symbol: "laptopcomputer.and.iphone") }
                }.buttonStyle(ProbePressStyle())
                ProbeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Appearance", systemImage: "circle.lefthalf.filled").font(.headline)
                        Picker("Appearance", selection: $appearance) {
                            ForEach(ProbeAppearance.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Text("System follows your iPhone's appearance.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text("TOOLS & RECOVERY").font(.system(.caption2, design: .monospaced)).tracking(2).foregroundStyle(.secondary).padding(.top, 8)
                NavigationLink {
                    ProbeDiagnostics(model: model)
                } label: {
                    ProbeCard { ProbeRow(title: "Diagnostics", detail: "Manual download, service and install tools", symbol: "slider.horizontal.3") }
                }.buttonStyle(ProbePressStyle())
                ProbeRecoveryCard(model: model)
                Text("Development signing must stay valid for both this app and your builds. Renew expired profiles through Xcode.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: 640).padding(22).frame(maxWidth: .infinity)
        }
        .background(ProbePalette.canvas(scheme))
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct ProbeRecoveryCard: View {
    @ObservedObject var model: ProbeModel
    var body: some View {
        ProbeCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Get back online", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                Text("If a run stops offline, restore your connection before retrying.").font(.subheadline).foregroundStyle(.secondary)
                Button("Restore Internet", systemImage: "arrow.clockwise") { model.restoreInternet() }
                    .buttonStyle(.bordered).disabled(model.busy)
                Text("If unavailable: turn Cellular Data on, disconnect LocalDevVPN, then reconnect Tailscale. Do not start a second installation while one is active.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct ProbeShortcutSettings: View {
    @ObservedObject var model: ProbeModel
    var body: some View {
        Form {
            Section("Master Shortcut setup") {
                ProbeShortcutImport(resource: .master)
                Toggle("Master Shortcut is configured", isOn: $model.masterReady)
                Text("Start with Build & Install in this app. Keep the master’s name unchanged.").font(.footnote)
            }
            Section("Connection and recovery helpers") {
                ForEach([InstallResource.connect, .prepare, .restore], id: \.self) { resource in
                    ProbeShortcutImport(resource: resource)
                }
                Toggle("All three helpers are configured", isOn: $model.helpersReady)
                Button("Run Probe Restore Internet") { model.restoreInternet() }
                Text("Approve first-use prompts, then confirm cellular and Tailscale are on. Keep all three names unchanged.").font(.footnote)
            }
            Section {
                Text("Installing an app update does not replace imported Shortcuts. Reimport them when their actions change. In older Tailscale actions, turn Show When Run off to hide completion dialogs.")
            }
        }
        .disabled(model.busy || !model.flowIsIdle)
        .navigationTitle("Shortcuts installer").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

struct ProbeShortcutImport: View {
    let resource: InstallResource
    var body: some View {
        if let url = Bundle.main.url(forResource: resource.title, withExtension: "shortcut") {
            ShareLink(item: url) { Label("Add " + resource.title, systemImage: "square.and.arrow.down") }
                .accessibilityHint("Choose Shortcuts in the share sheet, then Add Shortcut.")
        } else {
            Label("Missing “\(resource.title)”. Generate the Shortcuts on your Mac and rebuild this app.", systemImage: "exclamationmark.triangle")
        }
    }
}

struct ProbeConnectionSettings: View {
    @ObservedObject var model: ProbeModel
    var body: some View {
        Form {
            Section("Private USB preparation") {
                Label(model.pairingStatus, systemImage: model.pairingReady ? "checkmark.shield.fill" : "shield")
                Label(model.downloadStatus, systemImage: model.downloadReady ? "checkmark.circle.fill" : "circle")
                Button("Load private USB preparation", systemImage: "cable.connector") { model.refreshPairing() }
                    .disabled(model.busy || !model.flowIsIdle)
                Text("Import the preparation from your trusted Mac once. Pairing and connection credentials stay private on this iPhone.").font(.footnote)
            }
            Section("Mac connection") {
                Button("Check private Mac connection", systemImage: "network") { Task { await model.diagnoseMacConnection() } }
                    .disabled(!model.downloadReady || model.busy || model.catalogLoading || !model.flowIsIdle)
                Text("Keep Tailscale connected and the Mac server running. This check does not build, install or switch networks.").font(.footnote)
                if !model.liveStatus.isEmpty { Text(model.liveStatus).font(.footnote).textSelection(.enabled) }
            }
            Section("Network") {
                LabeledContent("Wi-Fi path", value: model.wifiPath)
                Text("A path check cannot confirm that USB is unplugged or identify the active VPN. Turn Wi-Fi off in Settings before a cellular install.").font(.footnote)
            }
        }.navigationTitle("Mac & pairing").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
