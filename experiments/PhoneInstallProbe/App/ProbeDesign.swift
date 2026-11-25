import SwiftUI

/// Framer's blue accent, quiet canvas and rounded surfaces, rendered natively.
enum ProbePalette {
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.40, green: 0.58, blue: 1) : Color(red: 0.13, green: 0.29, blue: 0.80)
    }
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.06, green: 0.07, blue: 0.09) : Color(red: 0.965, green: 0.969, blue: 0.961)
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.15) : .white
    }
}

enum ProbeAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct ProbeCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProbePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.07), lineWidth: 1) }
    }
}

struct ProbeHeading: View {
    let title: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("BUILD BUTTON")
            } icon: {
                Image(systemName: "square.3.layers.3d").foregroundStyle(ProbePalette.accent(scheme))
            }
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .tracking(2)
                .foregroundStyle(.secondary)
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProbeRow: View {
    let title: String
    let detail: String
    let symbol: String
    var chevron = true
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3.weight(.semibold))
                .foregroundStyle(ProbePalette.accent(scheme))
                .frame(width: 42, height: 42)
                .background(ProbePalette.accent(scheme).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true) }
        }.frame(minHeight: 44)
    }
}

struct ProbePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

struct ProbeReportEntry: Identifiable {
    let id = UUID()
    let text: String
    var title: String { String(text.split(separator: "\n").first ?? "Report") }
}
