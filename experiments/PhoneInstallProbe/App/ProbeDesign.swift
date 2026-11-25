import SwiftUI

enum ProbeAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct ProbeReportEntry: Identifiable {
    let id = UUID()
    let text: String
    var title: String { String(text.split(separator: "\n").first ?? "Report") }
}
