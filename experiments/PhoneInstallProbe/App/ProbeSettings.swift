import SwiftUI

struct ProbeSettings: View {
    @ObservedObject var model: ProbeModel
    @Binding var appearance: ProbeAppearance
    let openSetup: () -> Void

    var body: some View {
        Form {
            Section("Setup") {
                Button(action: openSetup) { Label("Setup Guide", systemImage: "book.closed") }
                    .disabled(model.busy || !model.flowIsIdle)
                NavigationLink { ProbeShortcutSettings(model: model) } label: {
                    Label("Shortcuts Installer", systemImage: "square.3.layers.3d")
                }
                NavigationLink { ProbeConnectionSettings(model: model) } label: {
                    Label("Mac & Pairing", systemImage: "laptopcomputer.and.iphone")
                }
            }
            Section {
                Picker(selection: $appearance) {
                    ForEach(ProbeAppearance.allCases) { Text($0.title).tag($0) }
                } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                    .pickerStyle(.navigationLink)
            } footer: { Text("System follows your iPhone’s appearance.") }
            Section {
                Button("Restore Internet", systemImage: "antenna.radiowaves.left.and.right") { model.restoreInternet() }
                    .disabled(model.busy)
            } header: { Text("Recovery") } footer: {
                Text("If a run stops offline, restore your connection before retrying. You can also turn Cellular Data on, disconnect LocalDevVPN and reconnect Tailscale in Settings.")
            }
            Section {
                NavigationLink { ProbeDiagnostics(model: model) } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            } header: { Text("Advanced") } footer: {
                Text("Development signing must stay valid for this app and your builds. Renew expired profiles through Xcode.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
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
