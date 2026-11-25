import SwiftUI

struct ProbeActivity: View {
    @ObservedObject var model: ProbeModel
    @State private var confirmClear = false
    var body: some View {
        List {
            if !model.liveStatus.isEmpty {
                Section("Latest Status") {
                    BuildStatusRow(phase: model.flow?.phase, message: model.liveStatus, busy: model.busy)
                }
            }
            if !model.reportEntries.isEmpty {
                Section("Reports · Newest First") {
                    ForEach(model.reportEntries.reversed()) { entry in
                        NavigationLink {
                            ScrollView {
                                Text(entry.text).font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                            }.navigationTitle("Report").navigationBarTitleDisplayMode(.inline)
                        } label: { Label(entry.title, systemImage: "doc.text") }
                    }
                }
                Section {
                    ShareLink("Share Results", item: model.reports.joined(separator: "\n\n"))
                    Button("Clear Reports", role: .destructive) { confirmClear = true }
                        .disabled(model.busy || !model.flowIsIdle)
                } footer: { Text("Review reports before sharing. Project names and build information may be private.") }
            }
        }
        .overlay {
            if model.reportEntries.isEmpty && model.liveStatus.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "clock", description: Text("Build progress and connection reports will appear here."))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("Clear saved reports?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear reports", role: .destructive) {
                guard !model.busy, model.flowIsIdle else { return }
                model.reports = []
                UserDefaults.standard.removeObject(forKey: "sanitizedReports")
            }
        } message: { Text("This removes local reports only. Your setup and installed apps are kept.") }
    }
}
