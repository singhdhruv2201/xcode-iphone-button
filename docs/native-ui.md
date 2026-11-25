# Native iPhone interface

The UI branch adapts the Build Button Framer reference into SwiftUI: a quiet canvas, blue circular build control, rounded cards, and four native tabs. The app uses real project and flow state; the prototype's sample projects, connection status and simulated progress are not shipped as live data.

| Tab | What lives here |
| --- | --- |
| Build | Private connection check, setup reminder, selected target, Build & Install, current phase/result and recovery |
| Projects | Search, refresh, project/workspace selection and a separate app-scheme screen |
| Activity | Current status, saved diagnostic reports, report detail, sharing and confirmed clearing |
| Settings | Resumable setup guide, four Shortcut imports, private USB preparation, connection checks, appearance, recovery and advanced diagnostics |

Appearance supports **System**, **Light** and **Dark** and is saved on the phone. Navigation stacks, sheets, lists, pickers, progress indicators and the tab bar use Apple components. Button press feedback, scoped progress animation and haptics use native SwiftUI APIs. Custom motion respects Reduce Motion; text follows Dynamic Type and the main action becomes a flexible rounded rectangle at accessibility sizes.

The setup walkthrough retains all nine steps and setup deep links. Settings → Diagnostics retains manual download, authenticated service lookup, staged installation and local service checks. Those tools remain separate from the routine one-tap flow.

The UI retains the existing `@MainActor` model and coordinator. View-owned catalog tasks use SwiftUI task lifetime; the build/install coordinator remains independent of tab navigation. There is no concurrency-mode migration or replacement of the signing, pairing, transport or installation implementation. Reports receive stable in-memory identifiers for navigation, without changing the persisted report format. A configured Mac is not labeled connected until checked; a successful check shows its time rather than promising continuous reachability.

Validation: simulator compilation and launch; first-launch walkthrough; light/dark appearance; large accessibility text with Reduce Motion; Swift core tests (18 executed, one credential-dependent live HTTPS test skipped, zero failures). Simulator validation does not prove VPN switching or installation on a physical iPhone. Recheck the complete master Shortcut flow on a paired phone before merging.
