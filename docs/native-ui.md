# Native iPhone interface

The UI uses stock iOS patterns: grouped lists and forms, large navigation titles, semantic system colors, a standard prominent Build & Install button, and four native tabs. Custom branded headings, gradient controls, hand-drawn cards and press scaling have been removed. The app uses real project and flow state; the prototype's sample projects, connection status and simulated progress are not shipped as live data.

| Tab | What lives here |
| --- | --- |
| Build | Private connection check, setup reminder, selected target, Build & Install, current phase/result and recovery |
| Projects | Search, refresh, project/workspace selection and a separate app-scheme screen |
| Activity | Current status, saved diagnostic reports, report detail, sharing and confirmed clearing |
| Settings | Resumable setup guide, four Shortcut imports, private USB preparation, connection checks, appearance, recovery and advanced diagnostics |

Appearance supports **System**, **Light** and **Dark** and is saved on the phone. Navigation stacks, sheets, lists, pickers, progress indicators and the tab bar use Apple components. System controls supply press feedback, navigation transitions, scrolling and sheet gestures. Setup progress respects Reduce Motion, and a single haptic acknowledges starting a build. Text follows Dynamic Type; rows and primary buttons grow with their content. System surfaces adapt to accessibility contrast and transparency settings without custom color overlays.

The setup walkthrough retains all nine steps and setup deep links. Settings → Diagnostics retains manual download, authenticated service lookup, staged installation and local service checks. Those tools remain separate from the routine one-tap flow.

The UI retains the existing `@MainActor` model and coordinator. View-owned catalog tasks use SwiftUI task lifetime; the build/install coordinator remains independent of tab navigation. There is no concurrency-mode migration or replacement of the signing, pairing, transport or installation implementation. Reports receive stable in-memory identifiers for navigation, without changing the persisted report format. A configured Mac is not labeled connected until checked; a successful check shows its time rather than promising continuous reachability.

Validation of the stock-controls revision: PhoneInstallProbe compiled for the iPhone 18 Pro simulator with zero errors. The prebuilt device-service library emits deployment-target linker warnings. The combined simulator build/run tool timed out during launch while the simulator remained on its boot screen. A subsequent signed device build succeeded in Xcode and was installed and launched on a paired iPhone over Wi-Fi, with no USB-connected iPhone. Detailed visual review is still pending. The earlier UI checkpoint passed Swift core tests (18 executed, one credential-dependent live HTTPS test skipped, zero failures); the core implementation is unchanged in this revision. Before merging, review light/dark appearance, the setup walkthrough and accessibility text sizes, then recheck the complete master Shortcut flow on a paired iPhone. Simulator compilation does not prove VPN switching or physical-device installation.
