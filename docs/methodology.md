# How the remote build and phone-side installer were developed

## Result and boundary

A physical iPhone successfully initiated a new Mac build, downloaded the signed artifact over cellular/Tailscale, installed it through a phone-local connection with cellular temporarily disabled, restored internet, and launched the updated target app. The user confirmed the complete one-tap outcome. The Mac's completed job was independently observed; the final phone report was not pasted. Earlier manual installation reports included exact bundle/build matches.

The result is specific to the tested development-signing setup, iOS version, and VPN/library versions. It does not prove continuous cellular installation, arbitrary device support, a way around provisioning limits, or a way to install an unsigned app. The installer does not re-sign on the phone or collect an Apple password.

## The question we separated into smaller questions

The original request sounded like one operation: press a button on the phone, build in Xcode, and receive the new app. It actually spans several independently failing systems:

1. Can the phone reach the Mac and request work?
2. Can Xcode build and sign a usable artifact?
3. Can the Mac reach a development service on the phone?
4. If that path fails, can an app on the phone reach the same service locally?
5. Can that local connection authenticate and discover Installation Proxy?
6. Can a complete signed artifact be transferred and installed?
7. Does the installed identity/version match the intended build?
8. Does the app actually launch and behave correctly?
9. Can network changes and recovery be coordinated reliably with one user action?

We recorded each milestone separately. An SSH success message, a ping, an advertised service, an accepted TCP connection, an authenticated lookup, a download, an install response, and a successful launch are different observations.

## Experiment sequence

| Experiment | Observed result | Decision or limit |
| --- | --- | --- |
| iPhone Shortcut → Mac SSH over Tailscale/cellular | Remote command succeeded | Build control was reachable; this did not prove a device installation route. |
| Mac-to-phone development tunnel on Wi-Fi | App installation/launch worked | Established a positive control for signing, pairing, and the existing network transport. |
| Wi-Fi → cellular handoff, including periodic installation-service requests | Development connection failed; replacement service connections did not recover until Wi-Fi returned | Keeping requests active did not preserve this device-service path. Tailscale reachability alone was insufficient. |
| Native Xcode bridge through RoamRun on separate Wi-Fi networks | Deferred | Remains an alternative experiment, not evidence for the final cellular route. |
| Phone-local service probe with Wi-Fi off, LocalDevVPN and cellular on | Both tested connections timed out at approximately six seconds | Failure occurred before authentication; signing was not implicated by this result. |
| Same phone-local probe with Cellular Data off | RemotePairing TCP accepted immediately; classic Lockdown QueryType reset | Investigate the newer protocol rather than treating the old port's failure as decisive. |
| Private RemotePairing identity → authenticated tunnel/RSD → Installation Proxy lookup | Connection and restricted app lookup succeeded in approximately 0.2 seconds | An authenticated local installation-service route existed in the reported offline setup. No app was installed by this test. |
| Fresh signed target, staged over USB but installed after unplugging | AFC upload, install success, exact bundle/build verification in approximately 1 second | Proved installation independently of network download. The first artifact transport still used USB. |
| Repeat staged installation | User confirmed install and launch | Confirmed the target could run, not merely appear installed. |
| Cellular/Tailscale HTTPS download | First phone attempt failed with network code -1200; Mac HTTPS test worked | Investigate TLS/ATS rather than signing or installation. Initial report lacked sufficient detail to identify the exact TLS rejection. |
| Scoped ATS/private-certificate policy and clearer diagnostics | Phone accepted pinned HTTPS, verified size/hash, and staged the build in approximately 0.9 seconds | Fixed the observed setup while retaining certificate pinning and endpoint restrictions. No low-level trace established the original internal rejection precisely. |
| Downloaded artifact → offline local installation → launch | User confirmed success | Replaced target USB staging with a real cellular download. |
| App coordinator + fixed-project build jobs + three Shortcuts | User confirmed one-tap install, restored internet, and working target app | Combined the proven components; Mac job completion was independently recorded. |

A Wi-Fi-specific Network framework path was reported before and after phone probes. USB unplugged, Cellular Data state, and selected VPN remained operator-controlled observations, not independently measured by that path API.

## Why a phone-side installer worked differently

The failed approach asked the Mac to retain or create a connection into the phone's development services while the phone moved to cellular. A VPN can preserve reachability between tailnet peers without forcing iOS to keep a particular development endpoint available. Changing what Xcode displays or labeling cellular as Wi-Fi on the Mac would not establish that missing phone-side behavior.

The final approach moves the installation client onto the phone. Tailscale is needed only while requesting the build and downloading bytes. Once the complete artifact is on disk, the app can disconnect Tailscale and use LocalDevVPN's local packet tunnel to reach development services on the same phone. In the tested setup, temporarily disabling Cellular Data made that local route usable. We use this observed behavior rather than asserting an undocumented universal iOS rule.

The design serializes these modes rather than depending on Tailscale and LocalDevVPN remaining active simultaneously. It also separates artifact delivery from device authentication. An IPA file alone is not an installation mechanism: a valid signature/profile and an authenticated installation service are still required.

## Architecture and ownership

| Component | Responsibility | Private material |
| --- | --- | --- |
| Mac Xcode project | Build current local source and sign the target for the phone | Signing identity/profile and target source stay on the Mac. |
| Python build server | Authenticate requests, serialize/idempotently identify jobs, invoke a configured build, publish exact artifact metadata | Target paths, TLS key/certificate, token, artifacts and job files remain outside Git. |
| Pinned HTTPS client | Retrieve the selected job and artifact; verify endpoint, certificate, app identity, byte count and hash | Connection settings are in device-only Keychain storage. |
| Phone coordinator | Persist phase/job/nonce, orchestrate Shortcuts, consume callbacks once, surface recovery | Coordination state is saved locally; it contains no credential material. |
| Network helper Shortcuts | Explicitly enable/disable the required providers and Cellular Data, then return control | No SSH action, server address, token, personal VPN UUID or pairing key is embedded. Signed files stay local. |
| Native idevice library | RemotePairing, tunnel establishment, RSD, AFC and Installation Proxy | Authenticates with the phone's private imported pairing record. |
| LocalDevVPN | Route the app to development services on the same phone | Independently installed provider; default Device IP is required by the current coordinator. |

The native binary dependency is pinned by release URL and SHA-256. Its MIT license is bundled. Host tests avoid linking its newer macOS slice and validate the Swift protocol/state logic separately.

## Exact artifact and job discipline

The phone submits a canonical UUID to authenticated `POST /jobs`. The server accepts no project path, shell command, scheme, or signing identity from that request. Those belong to a private fixed configuration. Duplicate UUIDs return the same job, concurrent jobs are rejected, and unfinished jobs become failed records on server restart.

For a new job, the helper increments the configured project's integer build number, builds through Xcode for the generic iOS device destination, checks the build result, verifies the signed output/profile and expected version, then packages it. The manifest includes schema, display name, bundle ID, build version, byte count and SHA-256. The artifact is retrieved by its content hash, so a later job cannot silently replace the bytes associated with an earlier job.

The phone validates the candidate against its allowed target before publishing it to the staging cache. It removes the old valid manifest before replacing the artifact, and publishes the new manifest last. A crash during replacement must not label a partial file ready. Before installation, the coordinator checks that the staged hash still matches the selected job and verifies the file again.

Installation uses a unique AFC staging directory, Developer-package installation options, then an exact bundle/version lookup. An already-matching version is reported as already installed, not a fresh successful install. An install request without post-install verification is reported as uncertain. Launch remains a separate manual check.

## State machine and Shortcuts handoff

```text
connect → building/download → prepare → installing → restore → done
                                       ↘ failure/recovery
interrupted native work → explicit recovery; no automatic install replay
```

The saved state includes job UUID, phase, nonce, start time, selected artifact hash and result. Each handoff gets a new nonce. A callback is accepted only for the expected URL scheme/host, unique matching job/phase/nonce parameters, an allowed waiting phase, and the time window. It is consumed before asynchronous work is scheduled, preventing duplicate advancement.

Apple's Shortcuts completion callback indicates that the helper finished; merely opening the Shortcuts URL is not sufficient. Tailscale routes may take time after its Connect action returns, so requests retry using the same UUID. Before native authentication, bounded local TCP probes check service readiness. TCP acceptance itself is never reported as authenticated installation.

Helpers use explicit operations:

- **Probe Connect to Mac:** Cellular Data on → LocalDevVPN disable → Tailscale connect.
- **Probe Prepare Installation:** Tailscale disconnect → LocalDevVPN enable → Cellular Data off.
- **Probe Restore Internet:** Cellular Data on → LocalDevVPN disable → Tailscale connect.

Restoration enables data first, so a later VPN action error does not prevent that first recovery step. If a Shortcut fails/cancels or the process is killed, the user may need to run recovery explicitly. Some native calls have no overall cancellation deadline. The implementation does not free in-flight handles from an unrelated timer; it shows a reminder and warns against overlapping attempts.

## Security decisions

1. **Preserve existing development signing.** Build/sign on the Mac; do not move Apple account credentials or signing private keys into the phone app.
2. **Treat pairing records as credentials.** Transfer over trusted USB, validate key pairing and identity semantics, import to non-synchronizing device-only Keychain, delete temporary cache imports.
3. **Keep secrets outside Git.** Server state is rejected inside any Git checkout. Local signing settings, build caches, provisioning files, app artifacts and signed Shortcuts are ignored and manually audited before publication.
4. **Keep the endpoint private.** Bind only the chosen tailnet IPv4 address, require a bearer token, omit request logs, and expose no key/settings routes or directory listing. No firewall disablement or public router forwarding is part of setup.
5. **Retain transport verification.** Exact certificate pin, IP/validity evaluation, approved endpoint range, HTTPS-only URLs, no redirects, and size/hash/app checks. The ATS policy change is scoped rather than global.
6. **Keep remote execution bounded.** Fixed local project/scheme, one job at a time, idempotent UUIDs, bounded request body, sanitized errors, a build deadline, and a job-count cap.
7. **Report evidence precisely.** Numeric sanitized error categories and explicit stage outcomes; no raw endpoint/key/device output in shareable reports.

The bearer token still authorizes building the configured project, whose own build scripts run as the Mac user. This is a trusted personal-development tool, not a sandbox for untrusted projects or clients.

## Reproducibility and validation

- Original shell/AppleScript checks cover syntax, Xcode dictionary resolution, isolated installation, synthetic configuration, literal input, and rejection of missing/invalid settings.
- Python tests cover diagnostic cleanup, authentication, private-route/traversal exclusion, allowed bind range, job input constraints, duplicate requests, serialization, restart recovery, and sanitized failures.
- Swift tests cover frame bounds, valid protocol replies, pairing record/key validation, artifact metadata/integrity, allowed endpoints, callback freshness/consumption, and optional real private HTTPS success plus negative token/pin cases.
- The optional integration test reads a private settings file through an environment variable. CI does not receive personal device, signing, pairing, server or SSH credentials.
- Hardware evidence progresses from TCP through authentication, service lookup, artifact upload, install response, exact version lookup and manual launch. Simulator builds alone cannot establish the phone-local route.

The publication check reviews the exact staged files and all reachable Git history for known private values and common credential/device/path patterns, including author/committer metadata. Only synthetic fixture addresses and public dependency/license data are allowed. Generated signed Shortcut containers are intentionally omitted even though their workflow payload is credential-free.

## Current constraints and deferred work

- Only the tested phone/setup is verified; future iOS and provider behavior can differ.
- Initial trusted USB pairing, installer installation and connection import remain necessary. The documented upstream USB pairing bootstrap was checked in the pinned CLI help/source, not rerun on a clean device during publication.
- The coordinator builds one privately configured `.xcodeproj`, not whichever Xcode window is currently active. It expects integer build-number entries and a known output path.
- The Mac must stay awake and the helper must run. Automatic startup/wake, artifact cleanup, multi-project selection and app discovery are not implemented.
- The free Personal Team limits and provisioning expiry remain. The installer cannot automatically recover itself after its own profile expires.
- Installation briefly disables cellular data. Continuous installation with cellular enabled was not established.
- Native wait cancellation and recovery after process termination remain limited. An interrupted install needs inspection before retry.
- The separate RoamRun/native-Xcode bridge test was deferred; it is not part of the proven path.

## Sources and code map

- [Complete setup](one-tap-installation.md), [flow and recovery](build-install-one-tap.md), [phone experiment log](phone-side-installer-investigation.md), [Mac tunnel log](remote-install-cellular-investigation.md).
- `tools/phone_build_jobs.py`, `tools/build_phone_project.applescript`, `tools/serve_phone_build.py`: Mac job and artifact service.
- `tools/prepare_phone_probe.py`, `tools/prepare_phone_download.py`: private initial preparation.
- `tools/make_phone_shortcuts.py`: credential-free helper generation/signing.
- `experiments/PhoneInstallProbe/App/BuildInstallFlow.swift`: app coordinator and App Intent.
- `experiments/PhoneInstallProbe/Sources/ProbeCore`: pinned downloader, credential vaults, artifact validation, native installation and callback state.
- [Apple Shortcuts completion callbacks](https://support.apple.com/en-nz/guide/shortcuts/apdcd7f20a6f/9.0/ios/26), [Tailscale Shortcut actions](https://tailscale.com/docs/features/mac-ios-shortcuts), [LocalDevVPN App Intents](https://github.com/jkcoxson/LocalDevVPN/blob/main/LocalDevVPN/VPNShortcuts.swift), [idevice release](https://github.com/jkcoxson/idevice/releases/tag/v0.1.68), [pymobiledevice3](https://github.com/doronz88/pymobiledevice3).
