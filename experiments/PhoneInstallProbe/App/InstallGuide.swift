import Foundation

enum InstallResource: String, CaseIterable {
    case macGuide, tailscale, deviceVPN, shortcutsApp, preparation
    case connect, prepare, restore, master, testRestore, troubleshooting

    var title: String {
        switch self {
        case .macGuide: "Mac and USB setup"
        case .tailscale: "Tailscale"
        case .deviceVPN: "LocalDevVPN"
        case .shortcutsApp: "Apple Shortcuts"
        case .preparation: "Load private USB preparation"
        case .connect: "Probe Connect to Mac"
        case .prepare: "Probe Prepare Installation"
        case .restore: "Probe Restore Internet"
        case .master: "Probe Build & Install"
        case .testRestore: "Run Probe Restore Internet"
        case .troubleshooting: "Troubleshooting guide"
        }
    }
    var isImport: Bool { [.connect, .prepare, .restore, .master].contains(self) }
    var detail: String {
        switch self {
        case .connect: "Connect to the Mac over Tailscale"
        case .prepare: "Switch to the local installation network"
        case .restore: "Bring cellular data and Tailscale back"
        case .master: "Coordinate the build, download and install"
        case .testRestore: "Approve prompts and verify connectivity"
        case .preparation: "Check pairing and the private Mac connection"
        case .macGuide, .troubleshooting: "Open instructions"
        default: "Open in the App Store"
        }
    }
    var icon: String {
        if isImport { return "square.and.arrow.down" }
        switch self {
        case .preparation: return "cable.connector"
        case .testRestore: return "play.circle"
        case .macGuide, .troubleshooting: return "book"
        default: return "arrow.up.right.square"
        }
    }
    var url: URL {
        let docs = "https://github.com/singhdhruv2201/xcode-iphone-button/blob/main/docs/one-tap-installation.md"
        let address: String
        switch self {
        case .macGuide: address = docs
        case .troubleshooting: address = docs + "#troubleshooting-by-symptom"
        case .tailscale: address = "https://apps.apple.com/app/id1470499037"
        case .deviceVPN: address = "https://apps.apple.com/app/id6755608044"
        case .shortcutsApp: address = "https://apps.apple.com/app/id1462947752"
        case .testRestore: address = "shortcuts://run-shortcut?name=Probe%20Restore%20Internet"
        default: address = "phoneinstallprobe://setup/" + rawValue
        }
        return URL(string: address)!
    }
}

enum InstallStep: Int, CaseIterable {
    case welcome, apps, pairing, helpers, recoveryTest, master, project, build, result

    var title: String {
        switch self {
        case .welcome: "Set up your iPhone"
        case .apps: "Install the three apps"
        case .pairing: "Load your private setup"
        case .helpers: "Add the three helpers"
        case .recoveryTest: "Test internet recovery"
        case .master: "Add the master shortcut"
        case .project: "Choose a project and scheme"
        case .build: "Make your first build"
        case .result: "Check the installation"
        }
    }
    var instructions: String {
        switch self {
        case .welcome: "Start with Phone Install Probe on your iPhone. Your Mac needs working Xcode signing, configured project folders, a running build server and one-time USB preparation for this phone."
        case .apps: "Sign in to the same Tailscale network as your Mac. Open both VPN apps to approve their setup prompts. Keep LocalDevVPN’s default Device IP."
        case .pairing: "Load the USB preparation in Phone Install Probe. Look for “Ready — stored privately on this iPhone” and “Private Mac connection ready.” If either is missing, revisit Mac and USB setup."
        case .helpers: "Add each helper below. In the iPhone share sheet, choose Shortcuts, then Add Shortcut. Keep each name exactly as shown and return here for the next one."
        case .recoveryTest: "Run Restore Internet once and approve the first-use prompts. Check that Cellular Data is on and Tailscale connects. Then confirm that all three helpers are configured."
        case .master: "Choose Shortcuts in the share sheet and add the master with its original name. Return here to confirm. Start each build inside Phone Install Probe so it receives the selected project."
        case .project: "Keep the Mac awake on its own network with the build server running. Connect Tailscale on both devices and disconnect LocalDevVPN. In Projects on your Mac, tap Connect & Refresh. Choose a project or workspace, then its app scheme. Your selection is remembered."
        case .build: "Unplug USB. Turn Wi-Fi off in Settings, leave Cellular Data on and Tailscale connected. Tap Build & Install once in the app and keep the iPhone unlocked. Let Shortcuts switch networks as the Mac builds, the phone downloads and LocalDevVPN handles installation."
        case .result: "Wait for the success message, check that internet access returned, then open the app from the Home Screen. For updates, select your scheme and build again. If interrupted, check the installed app before retrying. If offline, run Restore Internet or enable cellular data, disconnect LocalDevVPN and reconnect Tailscale."
        }
    }
    var resources: [InstallResource] {
        switch self {
        case .welcome: [.macGuide]
        case .apps: [.tailscale, .deviceVPN, .shortcutsApp]
        case .pairing: [.preparation, .macGuide]
        case .helpers: [.connect, .prepare, .restore]
        case .recoveryTest: [.testRestore]
        case .master: [.master]
        case .project, .build: []
        case .result: [.testRestore, .troubleshooting]
        }
    }
    var nextTitle: String {
        switch self {
        case .welcome: "Begin setup"
        case .pairing: "Both statuses are ready"
        case .recoveryTest: "All three helpers are configured"
        case .master: "Master shortcut is configured"
        case .result: "Go to projects"
        default: "Continue"
        }
    }
    var progress: String { "Step \(rawValue + 1) of \(Self.allCases.count)" }
}
