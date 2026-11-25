import SwiftUI
import ProbeCore

/// Manual transport tools remain separate from the everyday build flow.
struct ProbeDiagnostics: View {
    @ObservedObject var model: ProbeModel
    @State private var host = "10.7.0.1"
    @State private var stage = "Cellular + Tailscale"
    @State private var wifiOff = false
    private let stages = ["Cellular + Tailscale", "Cellular + LocalDevVPN", "Data off + LocalDevVPN", "Wi-Fi control"]

    var body: some View {
        Form {
                Section {
                    Text("Can this iPhone reach its own development service without Wi-Fi?")
                    Text("Download a signed build from your Mac, then install it during a brief offline step. The controls below remain available for manual diagnostics.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Download from Mac · v6") {
                    Text(model.downloadStatus).font(.footnote)
                    Button("Check private Mac connection") { Task { await model.diagnoseMacConnection() } }
                        .disabled(model.busy || model.catalogLoading || !model.flowIsIdle || !model.downloadReady)
                    Button("Download latest build") {
                        Task { await model.downloadBuild(stage: stage) }
                    }
                    .disabled(model.busy || !model.downloadReady || !wifiOff || stage != "Cellular + Tailscale")
                    Text("Unplug USB and keep Wi-Fi off. Leave Cellular Data ON, disconnect LocalDevVPN, and connect Tailscale. Select Cellular + Tailscale in Test setup, then download. Keep this app open until it finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Authenticated test · v6") {
                    Text(model.pairingStatus).font(.footnote)
                    Button("Load private USB preparation") { model.refreshPairing() }
                        .disabled(model.busy)
                    Button("Test authenticated service") {
                        Task { await model.authenticate(host: host.trimmingCharacters(in: .whitespacesAndNewlines), stage: stage) }
                    }
                    .disabled(model.busy || !model.pairingReady || !wifiOff || stage != "Data off + LocalDevVPN" || !DeviceProbe.isLocalAddress(host))
                    Text("For this test, unplug USB, keep Wi-Fi off, connect LocalDevVPN, and turn Cellular Data off. Select Data off + LocalDevVPN in Test setup. Afterward, restore Cellular Data.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The service test only looks up this probe. The library may request trust again if verification fails. Some protocol waits have no overall deadline.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.liveStatus.isEmpty { Text(model.liveStatus).font(.footnote).textSelection(.enabled) }
                }
                Section("Staged installation") {
                    if let candidate = model.candidate {
                        Text("\(candidate.displayName) · build \(candidate.buildVersion)")
                        Text("\(candidate.byteCount / 1_024) KiB · \(model.artifactSource)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Install staged build") {
                            Task { await model.authenticate(host: host.trimmingCharacters(in: .whitespacesAndNewlines), stage: stage, install: true) }
                        }
                        .disabled(model.busy || !model.pairingReady || !wifiOff || stage != "Data off + LocalDevVPN" || !DeviceProbe.isLocalAddress(host))
                        Text("Updates this app if it is already installed. Verifies the staged file, requests installation, and checks the installed build number. Open the target app manually afterward.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No signed build staged. Download a build from the Mac first.")
                    }
                }
                Section("Test setup") {
                    Picker("Current setup", selection: $stage) {
                        ForEach(stages, id: \.self) { Text($0) }
                    }
                    TextField("Device IP from LocalDevVPN", text: $host)
                        .keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Use Device IP in LocalDevVPN Settings, without /32. This is not your Mac’s address or the VPN’s Tunnel IP.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Wi-Fi path", value: model.wifiPath)
                    Toggle("Wi-Fi is off in Settings; USB unplugged", isOn: $wifiOff)
                    Text("Select a setup only after changing it yourself. A network-path check alone cannot verify the radio or VPN app in use.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy)
                Section {
                    Button {
                        let endpoint = host.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await model.run(host: endpoint, stage: stage) }
                    } label: {
                        HStack {
                            Text(model.busy ? "Checking…" : "Check local services")
                            Spacer()
                            if model.busy { ProgressView() }
                        }
                    }
                    .disabled(model.busy || (!wifiOff && stage != "Wi-Fi control") || !DeviceProbe.isLocalAddress(host))
                    Text("Each check takes at most about 12 seconds. An open port is only a first step; it does not prove installation works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
        }
        .disabled(!model.flowIsIdle)
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
