import SwiftUI

struct ProbeActivity: View {
    @ObservedObject var model: ProbeModel
    @Environment(\.colorScheme) private var scheme
    @State private var confirmClear = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ProbeHeading(title: "Activity")
                if !model.liveStatus.isEmpty {
                    BuildStatusCard(phase: model.flow?.phase, message: model.liveStatus, busy: model.busy)
                }
                if model.reportEntries.isEmpty {
                    ContentUnavailableView("No reports yet", systemImage: "waveform.path.ecg", description: Text("Start a build or check your Mac connection. Progress and diagnostic reports appear here."))
                } else {
                    Text("REPORTS · NEWEST FIRST").font(.system(.caption2, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                    ForEach(model.reportEntries.reversed()) { entry in
                        NavigationLink {
                            ScrollView {
                                Text(entry.text).font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                            }.navigationTitle("Report").navigationBarTitleDisplayMode(.inline)
                                .toolbar(.visible, for: .navigationBar)
                        } label: {
                            ProbeCard { ProbeRow(title: entry.title, detail: "View diagnostic details", symbol: "doc.text") }
                        }.buttonStyle(ProbePressStyle())
                    }
                    ShareLink("Share results", item: model.reports.joined(separator: "\n\n"))
                        .buttonStyle(.bordered)
                    Text("Review reports before sharing. Project names and build information may be private.").font(.footnote).foregroundStyle(.secondary)
                    Button("Clear reports", role: .destructive) { confirmClear = true }
                        .disabled(model.busy || !model.flowIsIdle)
                }
            }.frame(maxWidth: 640).padding(22).frame(maxWidth: .infinity)
        }
        .background(ProbePalette.canvas(scheme))
        .navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Clear saved reports?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear reports", role: .destructive) {
                guard !model.busy, model.flowIsIdle else { return }
                model.reports = []
                UserDefaults.standard.removeObject(forKey: "sanitizedReports")
            }
        } message: { Text("This removes local reports only. Your setup and installed apps are kept.") }
    }
}
