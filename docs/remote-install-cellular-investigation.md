> Historical Mac-to-phone tunnel investigation. The later [phone-side one-tap workflow](build-install-one-tap.md) succeeded; the native bridge experiment below remains a separate deferred path. Statements about pending work and Mac-only pairing storage describe this earlier stage.

# Remote installation over Tailscale: findings and next test

Last tested: **2026-11-14** (Pacific time). The instrumented handoff confirmed a development-tunnel reset; returning to Wi-Fi required a fresh tunnel.

## Objective

Use an iPhone Shortcut to build the current Xcode project on a remote Mac, then install and launch the build on that iPhone using a **free Apple Personal Team**. The desired final setup uses the iPhone's cellular connection without requiring nearby Wi-Fi.

**Current result:** a signed development app was installed and launched through an explicitly addressed Tailscale tunnel with USB disconnected and the iPhone on Wi-Fi. The user confirmed the app opened. Cellular installation has **not** succeeded.

The Mac and iPhone were on the same Wi-Fi for that successful test, although the diagnostic explicitly connected to the Tailscale address and had no USB or LAN fallback. This proves the installation protocol works over that tunnel; it does **not** yet prove operation across different networks.

## What was tested

Environment: iOS **26.5.1**, Developer Mode enabled, an existing trusted Mac pairing, Tailscale connected on both devices, and the Mac firewall enabled. The diagnostic used **pymobiledevice3 11.55.0** in an isolated Python **3.11.7** environment outside this repository.

| Test | Observation |
| --- | --- |
| iPhone Shortcut to Mac over cellular and Tailscale | SSH command succeeded. Remote build control works. |
| Current project build on the Mac | Build succeeded. This was checked separately from installation. |
| Ordinary Xcode Run while iPhone was cellular-only | Failed; the phone was not an available physical run destination. |
| Cellular-only device-service probes | TCP 49152 (RemotePairing) and 62078 (lockdown) refused connections over both Tailscale IPv4 and IPv6. |
| One-time USB preparation | Confirmed the actual iOS version and Developer Mode; created/verified a local RemotePairing record. No pairing keys were published. |
| Phone joined Wi-Fi | Both standard ports became reachable. RemotePairing authenticated using the Tailscale address. |
| Explicit TCP development tunnel over Tailscale | RemoteServiceDiscovery connected and exposed AFC, installation proxy, and CoreDevice app services. |
| USB unplugged, phone still on Wi-Fi | Fresh device handshakes and installation-service lookups succeeded. |
| Signed build validation | Code signature verified; embedded provisioning included the test phone and was unexpired. |
| Actual install through the TCP tunnel, with USB unplugged | Installation service reported completion and the target app was present. The existing Xcode signature was preserved. |
| Launch through CoreDevice app service | Launch returned a process token; user confirmed the app opened. |
| Wi-Fi to cellular handoff, existing tunnel left open | Fresh device handshake timed out; new RemotePairing connections were refused. USB device count was zero. |
| QUIC variant | Listener creation returned a port, but tunnel establishment failed with `QuicProtocolNotSupportedError`. A returned listener port did not prove a usable transport. |
| TCP handoff with continuous installation-service lookups | Twenty successful keep-alive lookups were observed before the handoff failure. After Wi-Fi was disabled, the keep-alive timed out and a fresh device handshake also timed out. |

The standard heartbeat service closed its connection during an earlier attempt; the final keep-alive test therefore used real, targeted installation-service lookups every two seconds.

The USB RemotePairing control channel reported `allowsIncomingTunnelConnections=false`. That channel is for pairing/control, not tunnel creation; this field alone is **not evidence of a cellular restriction**. The Wi-Fi/Tailscale RemotePairing endpoint did allow incoming tunnels.

## What these findings mean

- Signing and installation with the free Personal Team worked. The observed cellular blocker was device connectivity, not a provisioning rejection.
- Successful SSH, a Tailscale ping, a build, an advertised service, and a completed installation are different milestones. Do not treat one as proof of the next.
- The tested custom TCP tunnel reset during the cellular handoff on this phone. The instrumented follow-up below distinguishes this from a slow installation-service reply. This does not prove every native Xcode or on-phone implementation must fail.
- The cited Bonjour/proxy article is not evidence of cold startup on cellular. Its verified installation used a phone joined to another hotspot's Wi-Fi, and its limitations explicitly describe cellular-only refusal.
- Free-account limits remain: seven-day provisioning and up to three development apps per device. A separate installer app would consume a slot too.

## Instrumented handoff result

This follow-up was read-only: no app was installed or launched, and no phone settings were changed by the diagnostic. The user performed the network switches with USB unplugged.

| Stage | Observed result |
| --- | --- |
| Wi-Fi baseline | 28 successful targeted installation-service lookups over the explicitly addressed Tailscale tunnel. |
| Wi-Fi disabled | Both the pairing port and the dynamic tunnel port refused connections while Tailscale still replied. |
| Existing development tunnel | Its reader reported `ConnectionResetError`, its writer closed, and its reader task ended. Received-packet count stopped at 429. This was recorded before the ten-second lookup warning. |
| Longer observation | The outstanding lookup reached its ninety-second deadline without a reply. Subsequent attempts to open the service over the same dead tunnel also timed out. Tailscale continued responding, including over a direct path; device-service probes remained refused, with occasional timeouts. |
| Return to Wi-Fi | The pairing port reopened. The old tunnel remained reset and its old dynamic port continued refusing connections. |
| Fresh tunnel on Wi-Fi | Pairing and device identity verified; five app lookups succeeded, with both service ports reachable. |

**Conclusion:** the immediate cause of the lookup timeout was a reset of the underlying development transport. Waiting longer or sending more app lookups cannot revive a closed TCP connection. A replacement connection worked on Wi-Fi; the ports needed to establish it were unavailable in the tested cellular state.

This does **not** identify which component sent the reset or establish the exact iOS policy responsible. The correlated port failures and network transition point toward development-service availability on the phone's cellular path, but these observations alone cannot distinguish an iOS service-lifetime decision from an interaction in the VPN/forwarding path. Tailscale-level pings are not proof that the phone's development services accept traffic.

The first diagnostic revision exposed the reset but still let an inner lookup wait to its deadline. The updated diagnostic now propagates a confirmed tunnel closure to that request, cancels and joins its pending reader, and stops service retries while continuing network observation. This improves error reporting and cleanup; it is **not a fix for cellular installation**. The final Wi-Fi recovery check used this updated revision.

The next distinct experiment is preserving an already-established **native Xcode** connection through the RoamRun bridge described below. Repeating the same custom-tunnel keep-alive experiment is not justified by these results. If the native connection also closes, an on-phone transport experiment remains a separate option, with installation-service reachability to prove before building an installer UI.

## Reusable read-only diagnostic

The earlier repeated requests were **read-only app lookups**, not repeated app installations. After one lookup waited ten seconds, the diagnostic canceled that request and stopped its lookup loop. The later device-handshake timeout confirms loss of response, but neither timeout proves an installation rejection or permanent loss of connectivity.

The read-only diagnostic in [tools/diagnose_handoff.py](../tools/diagnose_handoff.py) separates:

- Tailscale-level ping response and direct/relay path. This alone does not prove an iOS service is reachable.
- TCP reachability of the known pairing port and the dynamically allocated tunnel port.
- The existing control and tunnel sockets: EOF, error class, writer closure, and whether the tunnel reader task ended.
- Counts and timing of packets received inside the existing tunnel, without recording payloads.
- Replies from the existing installation-service connection. A slow request remains pending after ten seconds, up to a ninety-second observation deadline, unless the transport monitor confirms the tunnel has closed. There is never a second request reading the same stream concurrently. At the hard deadline that service connection is discarded before trying a fresh one over a tunnel that has not been observed closed. A confirmed closure ends lookups; network observation continues.

The diagnostic has no install, launch, pairing, or settings-changing operation and no USB or LAN discovery fallback. It uses the existing trusted pairing. It stops on `quit` or after ten minutes. The operator can type `wifi` or `cellular` to mark the user's reported transition; those markers are not an independent measurement of the phone's radios.

Use an isolated Python environment with `pymobiledevice3==11.55.0`. The exact version is required because socket observations use that version's internals. Supply private device values locally:

```sh
python tools/diagnose_handoff.py \
  --host '<phone-tailnet-address>' --device '<paired-device-identifier>' \
  --port '<observed-RemotePairing-port>' --app '<existing-signed-app-directory>' \
  --log handoff.log
```

The app is not installed or launched by this command; only its bundle identifier is read for a targeted lookup. Logs contain event timestamps, outcomes, counts, and error types, with raw third-party logging suppressed. `.log` files and Python cache/environment directories are excluded from Git. Do not copy private CLI values into this document.

Wait for `READY_FOR_HANDOFF` before switching the phone from Wi-Fi to cellular, with USB disconnected. Keep the phone awake and Tailscale on. Observe long enough to distinguish recovery from the ninety-second request deadline. If the test fails, return to Wi-Fi **without restarting the diagnostic first**, to see whether the existing tunnel recovers.

Interpret evidence conservatively:

| Observation | Next investigation |
| --- | --- |
| Tailscale ping and device traffic both stop | Resolve underlying VPN/network handoff before changing installation code. |
| Tailscale ping returns, existing tunnel resumes and the delayed lookup succeeds | Add an appropriate grace period and recovery handling; the old timeout was too short. |
| Pairing port closes but the existing tunnel still replies | Preserve that session; do not tear it down merely because new pairing connections fail. |
| Tailscale replies but tunnel read task ends / socket reports EOF or reset | Investigate teardown of the authenticated device connection; an application-level retry cannot restore a closed tunnel by itself. |
| Tunnel still carries replies but installation lookup alone fails | Investigate service-specific behavior or reopen that service after safely retiring its previous reader. |
| All inner traffic stalls while sockets remain open | Inspect routing, tunnel forwarding, and device-side service lifetime. An apparently open socket does not prove the remote endpoint remains usable. |

Four hardware-independent request-lifetime tests passed: a delayed successful response, hard-deadline cleanup, cancellation on stop, and early cancellation when the tunnel closes:

```sh
python -m unittest discover -s tests -p 'test_handoff_probe.py' -v
```

## Subsequent experiment: preserve Xcode's native connection with RoamRun

After the diagnostic above, a remaining candidate is **RoamRun's native Xcode bridge with “Keep debugging on cellular” enabled**. It differs from the custom pymobiledevice3 tunnel already tested: Apple's own device connection remains in charge while the bridge forwards traffic.

RoamRun documents cellular continuation only after an established bridged session starts on Wi-Fi. It does not promise a new connection can start on cellular. Its claims still need verification on this particular iOS version and setup.

### Preparation status

- RoamRun **v0.12.0** was downloaded from its official GitHub release.
- The DMG matched the release's published SHA-256:

  ```text
  3490f6e7e5e3bd2891f3c2e3f17db967ff17bed2c76c1f480949e88b331770f3
  ```

- The app passed code-signature verification and macOS assessment as **Notarized Developer ID**.
- Only command-line help was run. RoamRun was **not installed or configured**, and no RoamRun bridge was started.
- Temporary diagnostics and the downloaded DMG are outside this repository. Do not assume their paths or private device configuration are portable.

### Required network arrangement

Temporarily put the **Mac on Wi-Fi/network A** and the **iPhone on Wi-Fi/network B**, with both connected to the same private Tailscale network. A second phone's hotspot can provide network B.

This is necessary because RoamRun deliberately stands aside when it detects the phone on the Mac's local network. Its **“On this Wi-Fi”** state is not the bridged state required for its cellular-continuation feature. The iPhone's own hotspot is not equivalent to the iPhone joining another Wi-Fi network.

The user has not yet confirmed access to two networks. **Resolve this before the RoamRun test**; the diagnostic above does not require two Wi-Fi networks.

### Test sequence

1. Recheck RoamRun's current release notes and requirements. Install the verified official release or re-verify a newer release before using it.
2. With the phone temporarily on USB or the Mac's Wi-Fi, add the existing paired phone in RoamRun and match it to its Tailscale device. Keep device identifiers and addresses in local app configuration.
3. In **RoamRun on the Mac**, enable **Settings → Network → Keep debugging on cellular**. This is a RoamRun setting, not an iPhone Settings option.
4. Disconnect USB, move the phone onto network B, and keep it unlocked with Tailscale connected. Leave the Mac on network A.
5. Start the bridge. Require **“Ready for Xcode”**, not merely **“On this Wi-Fi”**, and verify the actual phone appears as a usable destination in Xcode.
6. Build, install, and launch through Xcode. Verify the result on the physical phone. This establishes the missing cross-network Wi-Fi baseline.
7. Leave the native bridge/session running. On the iPhone, turn Wi-Fi fully off in **Settings**, while keeping cellular data and Tailscale on. Keep USB disconnected and the screen awake.
8. Check whether the existing native connection remains responsive. If so, install a distinguishable new test build and launch it. Confirm the phone is running that build rather than an older installed copy.
9. Record connection survival, installation completion, launch result, approximate duration, and any errors separately. Verify there was no USB or local-Wi-Fi fallback.
10. Only after a successful handoff, separately test opening a fresh session on cellular by closing and reopening the bridge. Expect this may fail even if the existing session survives. Do not describe a Wi-Fi-bootstrapped session as an “anywhere, anytime” cellular solution.

Do not reboot the phone just to test recovery during the first pass. Reboot recovery and any need to prepare developer services again are separate follow-up tests.

## If the native bridge also fails

Investigate an on-phone, two-stage installer:

1. Request the build and download the signed artifact over cellular/Tailscale.
2. Perform installation locally using a private pairing record and a local VPN, potentially with cellular data temporarily disabled.

This remains **unverified on iOS 26.5.1**. SideStore's public prerequisites require Wi-Fi, but its development source and issue discussions also contain an experimental cellular-refresh flow using Shortcuts to turn data off and on. Reports differ by version; refresh support is not automatically proof of fresh installation support.

A custom installer could potentially preserve Xcode's signature by using existing installation libraries instead of re-signing. Before building a full app, prove that the on-phone installation service is reachable in the intended no-Wi-Fi state. A custom UI cannot by itself remove iOS's network restrictions.

Tailscale and the local installer VPN normally need separate stages on iOS: download the artifact first, then switch VPNs for local installation. This alternative must also account for the installer's own seven-day provisioning and the three-app limit.

## Local state and privacy

- Both temporary diagnostic sessions were stopped after the handoff and Wi-Fi recovery checks. No background bridge was installed.
- The user's existing firewall and SSH configuration were not changed by this investigation.
- Pairing material remains local to the Mac. Treat pairing files as credentials; do not include them in repository files, issues, logs, or screenshots intended for sharing.
- Do not commit real network addresses, tailnet names, account names, device names/identifiers, provisioning profiles, signing keys, or app artifacts.
- This document intentionally omits the personal test project's name and all device/network identifiers.
- No changes were pushed to GitHub as part of this investigation.

## Sources for resuming

- [RoamRun: requirements and working away from the Mac](https://github.com/mh-mobile/RoamRun#working-away-from-the-mac)
- [RoamRun v0.12.0 release](https://github.com/mh-mobile/RoamRun/releases/tag/v0.12.0)
- [Original Bonjour/proxy bridge implementation and its test limitations](https://dev.to/kvnpt/how-to-remotely-iterate-deploy-your-sideloaded-ios-apps-over-tailnet-jak)
- [pymobiledevice3 development tunnels](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md)
- [Apple Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)
- [SideStore cellular-refresh discussion](https://github.com/SideStore/SideStore/issues/1505)
- [SideStore cellular-refresh implementation](https://github.com/SideStore/SideStore/blob/develop/SideStore/Core/Shortcuts/CellularRefreshManager.swift)
- [Tailscale and other VPNs](https://tailscale.com/docs/reference/faq/other-vpns)
