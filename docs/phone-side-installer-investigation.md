> Update: the one-button coordinator has passed the physical-phone test. The user confirmed installation, restored internet, and successful launch. See [setup and validation](build-install-one-tap.md).

# Phone-side cellular installation investigation

This is a chronological research log; “next” and “pending” below describe that stage, not current feature status. The final coordinator is documented separately.

Investigation started: 2026-11-22. **On-phone installation of a USB-staged, Personal Team signed build succeeded in the reported Wi-Fi-off, Cellular-Data-off LocalDevVPN setup.** The installed bundle and build matched. The user repeated the installation with a newer build and confirmed that the app opened. Probe build 5 successfully downloaded and verified a build over the reported cellular/Tailscale connection. The user subsequently confirmed that the downloaded copy installed, opened, and worked.

## Intended behavior

An iPhone app requests a build from the user's Mac through Tailscale while using cellular. The Mac builds and signs with its existing Xcode Personal Team. The app downloads and stores the signed artifact, then installs it through a local connection to the iPhone's development services. No Wi-Fi session should be required before each remote installation. One-time USB pairing and initial installation are allowed.

## Why this differs from the previous experiment

The earlier Mac-to-iPhone tunnel reset during Wi-Fi-to-cellular handoff while Tailscale remained reachable. Its pairing and tunnel ports refused replacements until Wi-Fi returned. Those observations do not establish whether a connection originating on the phone through a local VPN also fails.

Tailscale remains the transport for requesting the build and downloading the artifact. LocalDevVPN supplies a different route: the app back to development services on the same phone. The design should stage these operations so it does not depend on two packet-tunnel VPNs operating simultaneously.

## Evidence and limits

- [SideStore's public prerequisites](https://docs.sidestore.io/docs/installation/prerequisites) still require Wi-Fi and explain the local VPN's role. Treat ordinary supported setup separately from experimental behavior.
- [SideStore's cellular-refresh implementation](https://github.com/SideStore/SideStore/blob/develop/SideStore/Core/Shortcuts/CellularRefreshManager.swift) calls user-created Shortcuts to disable and re-enable cellular data and waits for its local endpoint to become ready. [Its issue discussion](https://github.com/SideStore/SideStore/issues/1505) includes successful reports. Refreshing an existing app is not proof of installing a new signed app on our iOS version.
- [LocalDevVPN's source](https://github.com/jkcoxson/LocalDevVPN/blob/main/TunnelProv/PacketTunnelProvider.swift) creates a local packet tunnel. Its peer address and the tunnel interface's own address serve different roles. Verify the installed app's Device IP rather than guessing it from the status label.
- [SideInstaller's compatibility notes](https://github.com/FrizzleM/SideInstaller#ios-264-to-26x-a-remote-pairing-file) report that iOS 26.4+ needs RemotePairing for the local route rather than classic Lockdown pairing. This is a reason to test the newer route; it is not proof of cellular-only operation. Its [development notes](https://github.com/FrizzleM/SideInstaller/blob/main/NOTES.md) also distinguish hardware evidence from unverified implementation.
- [Minimuxer](https://github.com/SideStore/minimuxer) and [idevice](https://github.com/jkcoxson/idevice) provide existing device-protocol implementations to evaluate for the authenticated stage. Pin the chosen revision and review its license before incorporation. No third-party implementation is copied into the initial probe.

## Candidate flow

1. **Download:** cellular and Tailscale on. Request an explicit build job and retrieve its signed artifact over an authenticated private connection. Download to disk, verify completeness and integrity, and show the app identity before proceeding.
2. **Local connection:** after the entire artifact is stored, switch from Tailscale to LocalDevVPN. Try a fresh local development connection while Wi-Fi is off and cellular remains on.
3. **Optional offline stage:** if the local connection is unavailable with cellular enabled, test temporarily disabling cellular data without enabling Wi-Fi. This follows the experimental SideStore pattern. The phone cannot keep downloading from the Mac during this stage; the build must already be stored.
4. **Install:** authenticate with the phone's private pairing record, reach the actual installation service, upload the signed application through AFC, request installation, and wait for its final result. Preserve Xcode signing; no Apple account credentials need to be sent to the installer for this design.
5. **Restore:** restore cellular and Tailscale, report the installation result, and separately verify launch/version on the physical device. Error and cancellation paths must also guide network restoration.

Steps 3–4 succeeded for a USB-staged artifact in the reported offline configuration. Step 2 with Cellular Data enabled previously timed out. A complete remote workflow still requires a cellular download followed by installation and confirmation of the new build running. A VPN status, open port, successful lookup or downloaded IPA alone is insufficient.

## Experiment prepared

[Phone Install Probe](../experiments/PhoneInstallProbe/README.md) is an independent SwiftUI app and local Swift package. Its initial port checks require no pairing record or Apple password. It checks the usual RemotePairing port and a classic Lockdown query separately; the newer route must not be dismissed solely because the classic one fails. Build 2 adds a separate authenticated service test using a privately imported pairing record.

The experiment compares cellular with Tailscale, cellular with LocalDevVPN, and data disabled with LocalDevVPN, while Wi-Fi stays off and USB stays unplugged. A later Wi-Fi control is recorded separately. Authentication, the installation-service lookup, and build 3's installation experiment succeeded in the reported offline configuration below.

### Preparation verified on 2026-11-22

- Connected physical test device: physical iPhone, iOS 26.5.1; model and OS read over USB rather than inferred from its display name.
- Four host-side protocol tests passed. The simulator build succeeded, but the combined simulator launch tool timed out; simulator launch is not claimed as verified.
- Xcode built and installed the probe over USB with the existing local Personal Team. Its signature verified, its profile was unexpired and included the test device, and a device-service lookup confirmed installation.
- Xcode waited for debugger attachment. After stopping that debugger session, the user confirmed the app opened normally from the Home Screen.
- LocalDevVPN was installed by the user. Individual network test results follow below.

### First phone-side result: cellular data enabled

The user supplied this probe output for `Cellular + LocalDevVPN` on 2026-11-22:

| Observation | Result |
| --- | --- |
| Wi-Fi-specific path before and after | Not available |
| RemotePairing TCP on the tested port | Timed out at six seconds; 6.37 seconds elapsed |
| Lockdown QueryType | Timed out at six seconds; 6.32 seconds elapsed |
| Authentication and installation | Not tested |

Neither check completed within its deadline. This is not a pairing/signing rejection and does not prove the local route works. The current probe does not export its selected route, connection waiting reason, or the Lockdown substage that timed out; its results therefore cannot distinguish a missing VPN route, a wrong peer address, an unavailable service, or a silent/stalled response.

The next comparison disabled Cellular Data; its result follows.

### Second phone-side result: cellular data disabled

The user supplied this output for `Data off + LocalDevVPN`, with Wi-Fi unavailable before and after:

- RemotePairing TCP: accepted immediately (0.00 seconds); authentication not tested.
- Lockdown QueryType: connection reset immediately (0.00 seconds).
- Authentication and installation: not tested.

This shows a reachable TCP listener in the offline configuration. It supports investigating a **download over cellular, then install during a brief offline phase** workflow. It does not establish that cellular can remain enabled during installation, identify the listener through authentication, or prove installation works. The classic Lockdown reset does not invalidate the separate RemotePairing result.

### Authenticated follow-up prepared

Build 2 links the official idevice v0.1.68 release binary, verified against its published SHA-256 and pinned in the package manifest. Its iOS slice declares iOS 17.0 as its minimum. The MIT license is embedded in the probe's resource bundle. The host tests deliberately avoid linking the binary's newer-macOS slice.

The app privately imports the existing pairing identity over USB, validates matching Ed25519 keys, and stores it in the device-only, unlocked-only Keychain. It requests a RemotePairing tunnel plus RSD handshake, then an Installation Proxy connection and a lookup restricted to the probe's own bundle. There is no installation request or artifact download. The native library may repair pairing if existing verification fails; app operations are read-only, but pairing state can change. Raw library logs and credential contents are not exported.

Eight host-side tests passed, including malformed record and mismatched-key rejection. Xcode's physical-device build succeeded. The native API combines authentication, tunnel creation and RSD discovery in one call; failures are therefore reported at that combined stage with numeric codes. Some internal waits are not bounded by its global timeout, so the UI warns after 60 seconds and requires force-closing a stuck test before retrying.

The updated probe was installed over USB and its signature verified. The existing pairing record was converted in memory, transferred over USB, and privately compared with the staged bytes. The user confirmed the app displayed **Ready — stored privately on this iPhone**. A subsequent USB container check confirmed that `PairingImport.plist` had been deleted, and that verification session was closed. The next result must come from the phone with USB unplugged and Wi-Fi off; preparation is not evidence of authenticated local connectivity.

Two Mac crash dialogs during preparation were separately traced to Simulator processes (`InputUI` and `MobileCal`, parent `launchd_sim`) terminated by launch/scene watchdogs. Neither is evidence of the physical phone probe crashing. No further simulator launch is needed for this experiment.

### Authenticated result: success with Cellular Data off

The user returned the following physical-phone results on 2026-11-22, after instructions to unplug USB, keep Wi-Fi off, connect LocalDevVPN and disable Cellular Data:

| Milestone | Elapsed time |
| --- | --- |
| Private pairing record loaded | 0.0 s |
| Authenticated tunnel and RSD connected | 0.1 s |
| Installation service connected | 0.1 s |
| Lookup restricted to the probe found one app | 0.2 s |

The Wi-Fi-specific path was unavailable before and after. The radio, VPN and USB states are operator-controlled, not independently measured by the app. No install request was sent. This establishes an authenticated local route to Installation Proxy in the reported offline setup; it does not establish installation with Cellular Data enabled or successful installation of a downloaded build.

Next: test one fresh Xcode-signed app, first staged over USB to isolate AFC upload and installation. Require a successful install response and an exact installed build-number match, followed by a manual launch check. Only after that succeeds, replace USB artifact staging with a private download over cellular. Do not describe USB preparation as a remotely downloaded installation.

### Installation experiment prepared (build 3)

The user selected an existing test app. Its current local sources were rebuilt with a distinct build number; its signature verified and its profile was unexpired and included the connected phone. The target was **not** installed from the Mac. The updated probe was installed over USB with its existing Keychain credential retained; the target's signed IPA and private manifest were staged in the probe cache and the transferred hash was verified.

The installation path checks artifact integrity, refuses self-update or an already-matching target build, uploads via authenticated AFC, requests installation with Developer package options, then checks the exact installed bundle and build. Ten host tests passed, covering the earlier protocol/credential validation plus corrupted, truncated and invalid artifact metadata. The physical-device probe build and USB preparation succeeded. The next required evidence is the unplugged phone's installation report and a manual launch check. Cellular download remains unimplemented.

### Installation result: service success and exact build match

The user returned the build 3 installation report on 2026-11-22 for `Data off + LocalDevVPN`, after instructions to unplug USB and keep Wi-Fi off. The Wi-Fi-specific path was unavailable before and after; the physical USB/radio/VPN states remain operator-reported.

| Milestone | Elapsed time |
| --- | --- |
| Staged artifact size and SHA-256 verified; private record loaded | 0.0 s |
| Authenticated tunnel, RSD and Installation Proxy connected | 0.1 s |
| Target lookup confirmed a different build was installed | 0.2 s |
| AFC upload complete; installation request sent | 0.2 s |
| Installation service reported success | 1.0 s |
| Post-install exact bundle ID and build-number match | 1.0 s |

This is evidence of a real app update through the phone-side connection, beyond authentication or an open port. The artifact had been staged over USB; the result does not demonstrate remote artifact transfer or installation while Cellular Data remains enabled. Manual launch is pending. Next, confirm launch, then implement and test private download over cellular before switching to the already-tested offline installation phase.

### Repeat installation and launch

Repeat-test result: at the user's request, a subsequent distinct target build was built and staged over USB. Its signature, profile/device eligibility and staged hash were checked by the same helper. The user then confirmed successful on-phone installation and that the target app opened. This completes the USB-staged installation/launch experiment.

### Private download experiment (build 4)

The probe now downloads the latest prepared target build over a private HTTPS connection to the Mac's Tailscale IPv4 address. The server binds only to that address, requires a bearer token, and serves only the manifest and content-addressed IPA artifacts. It has no build-execution endpoint, directory listing, or private-key/configuration download route. Mac credentials and artifacts live outside the repository with restrictive file permissions.

The phone receives its endpoint, token, pinned certificate and allowed target bundle via initial USB preparation, imports them into device-only Keychain storage, and removes the import file. No target artifact is sent over USB for this phase; the helper removes earlier staged target files. The TLS client checks the exact certificate, validity and IP identity, refuses redirects, restricts endpoints to canonical Tailscale IPv4 HTTPS URLs, and enforces response/size/hash checks before replacing the staged build. Downloading and installing remain separate explicit actions. The source label distinguishes a network download from local staging.

Build 4 declares `NSAllowsLocalNetworking` for its IP-address connection; it does not disable ATS globally. See Apple's [local networking policy](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) and [manual trust authentication](https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication). The build 5 policy correction is recorded below.

Validation: physical-device build succeeded. Twelve Swift tests passed, including a real HTTPS download against the private Mac server, artifact verification, rejection of a wrong token, and rejection of a mismatched certificate. Three Python server tests passed for authentication, private-file/path exclusion, and non-tailnet bind rejection. These Mac-side tests do not prove cellular connectivity. Next: unplug USB, leave Wi-Fi off, connect Tailscale with Cellular Data on, download, then switch to LocalDevVPN with Cellular Data off for installation and verify launch again.

### First cellular download: secure-connection failure; build 5 follow-up

The user returned a build 4 download report for `Cellular + Tailscale`, with the Wi-Fi path unavailable before and after: network code **-1200**, elapsed **1.0 s**, and no installation requested. This is a secure-connection failure, not evidence of a signing or installation rejection. The report did not identify whether the trust callback was reached or the underlying TLS error.

The Mac server continued to return HTTPS 200. A Mac harness with the original ATS dictionary also succeeded, so the failure was not reproduced on the Mac. It remains premature to claim a definitive iPhone root cause.

Build 5 adds an ATS exception restricted to `100.64.0.0/10` permitting manual trust evaluation of the private pinned certificate, while retaining TLS 1.2 minimum and forward secrecy. Apple's [exception documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsexceptionallowsinsecurehttploads) explains that this key is also needed when loosening default HTTPS trust requirements for a private certificate. The downloader still rejects HTTP URLs, other address ranges, redirects, certificate-pin mismatches, expired certificates and IP identity mismatches; no global arbitrary-load exception is added.

Build 5 also exports sanitized milestones for the TLS challenge, pin checks and certificate evaluation, plus numeric underlying errors. It does not export raw error descriptions, endpoints, keys or tokens. Twelve Swift tests passed, including live HTTPS success and negative token/certificate checks. The physical-device build succeeded.

### Cellular download result: success with build 5

The user supplied a successful `Cellular + Tailscale` download report on 2026-11-22. The Wi-Fi-specific path was unavailable before and after. The pinned HTTPS connection and authenticated manifest were accepted, the artifact's size and SHA-256 verified, and the downloaded build saved for offline installation in **0.9 seconds**. No installation was requested during download. The user had been instructed to unplug USB; the preparation helper had cleared old staged target files and transferred only the probe and private connection settings, not the target artifact.

This verifies the download stage in the reported cellular configuration. The successful retry after the scoped ATS-policy change supports that change as the resolution for this setup; no independent low-level trace established the original rejection's exact internal cause. Next: keep USB unplugged and Wi-Fi off, switch from Tailscale to LocalDevVPN, disable Cellular Data, install this downloaded artifact, then restore data and verify launch. The user subsequently reported successful installation, then confirmed that the app opened and worked. The post-download installation report was not pasted, so this final installation/launch confirmation is user-reported. At this milestone the complete manual download-to-install-to-launch flow worked. The subsequent one-button implementation and successful device run are recorded in the [current guide](build-install-one-tap.md).

## One-button design recorded before implementation

The next design is one Build & Install button in the app, with short, separately installed Shortcuts handling system network settings. The app should own the long-running build/download/install state and resume after each network handoff, rather than keeping a long Shortcut running while Xcode builds.

1. Prepare download mode: Cellular Data on, LocalDevVPN disabled, Tailscale connected; return to the app.
2. Request a bounded build job for the configured Xcode project/scheme on the Mac, wait for a successful signed artifact, then download and verify it.
3. Prepare installation mode: Tailscale disconnected, LocalDevVPN enabled, Cellular Data off; return to the app and verify local service readiness.
4. Install the exact artifact from that build job and verify its installed identity/version.
5. Restore Cellular Data, disable LocalDevVPN, restore the chosen normal VPN state, and show completion with an option to open the target app.

[Tailscale documents Connect, Disconnect and Get Status actions](https://tailscale.com/docs/features/mac-ios-shortcuts). [LocalDevVPN's source exposes Enable/Disable operations through App Intents](https://github.com/jkcoxson/LocalDevVPN/blob/main/LocalDevVPN/VPNShortcuts.swift). [Apple supports launching saved Shortcuts from an app using a URL scheme](https://support.apple.com/en-gb/guide/shortcuts/apda283236d7/ios). The existing SideStore cellular refresh pattern uses Shortcuts for Cellular Data changes. These capabilities make orchestration plausible, but the combined handoffs still require testing on the phone, including first-run prompts and cancellation.

Implementation should persist the current phase and an unguessable job/handoff identifier, verify actual readiness after a Shortcut returns, avoid overlapping jobs, retain original artifacts until installation is verified, and expose Restore Internet for interruptions. Opening a Shortcut URL is not proof that its actions completed. If the app is killed during the offline phase, restoration cannot be guaranteed until the user resumes or runs the recovery shortcut. The Mac must remain awake with the helper available. The current server only serves prepared builds; build-job execution and app/Shortcut handoffs remain to be added.

## Constraints to preserve

- Free Personal Team provisioning and app limits still apply to both installer and target app. The installer itself must stay provisioned; this design does not promise recovery after its profile expires.
- Pairing records are credentials. Keep them out of source, exported diagnostics and public repositories; use protected on-device storage if the authenticated stage is implemented.
- A pymobiledevice3 RemotePairing record may need format adaptation for a different library. Validate field semantics and host identity, not just filename extensions; do not fabricate a new identity for existing keys.
- Do not store the user's team identifier, signing certificate, SSH credentials, tailnet address or app artifact in public source. `Signing.local.xcconfig` is ignored.
- No publishing, paid enrollment, certificate revocation, or removal of existing apps is part of this experiment.

## Final coordinator result

The app coordinator, fixed-project Mac job endpoint, and three signed network helpers were implemented. The user imported the helpers and confirmed Restore Internet. Starting unplugged with Wi-Fi off, one tap triggered a new Mac build, download, phone-side installation, and restored connectivity. The Mac recorded the completed job; the user confirmed installation and that the updated app opened and worked. The complete final installation report was not pasted, so distinguish that user confirmation from the captured earlier protocol reports. See [complete setup](one-tap-installation.md).
