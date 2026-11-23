# Phone Install Probe

An experimental iPhone app that checks access to the phone's own development services through a local VPN with Wi-Fi off. It supports connection checks, an installation-service lookup, installation of a staged signed app (build 3), and private HTTPS downloading from a Mac (build 4). **Build 6 adds the verified one-tap Build & Install flow.** Start with the [complete setup guide](../../docs/one-tap-installation.md) and [current flow/recovery guide](../../docs/build-install-one-tap.md). The sections below retain the individual diagnostic stages.

On 2026-11-22, the physical-device report confirmed installation of a USB-staged signed build and an exact installed bundle/build match in 1.0 second, with the Wi-Fi path unavailable and the operator reporting Cellular Data off and LocalDevVPN connected. A repeat installation succeeded and the user confirmed the app opened. Build 5 then downloaded and verified a build in 0.9 seconds in the reported cellular/Tailscale setup, with no Wi-Fi path available. The user then confirmed that the downloaded copy installed, opened, and worked. See the [investigation results](../../docs/phone-side-installer-investigation.md).

## Build and initial installation

First generate the required bundled helpers with `python tools/make_phone_shortcuts.py --output experiments/PhoneInstallProbe/App/Shortcuts` from the repository root. Then open `PhoneInstallProbe.xcodeproj` in Xcode. Use the `PhoneInstallProbe` scheme and select your physical iPhone. For a private signing configuration, create `Signing.local.xcconfig` beside `Config.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
PROBE_BUNDLE_ID = your.unique.PhoneInstallProbe
```

That file is excluded from Git. Keep signing identities and device details out of the project file. Run once over USB using your existing Xcode Personal Team and trusted device. A free-account installation consumes an app slot and must remain provisioned to launch. No special VPN entitlement is requested by this probe; the local VPN is supplied by the separately installed [LocalDevVPN](https://apps.apple.com/app/id6755608044).

`ProbeCore` is a local Swift package. Its iOS authentication code links the official [idevice v0.1.68 XCFramework](https://github.com/jkcoxson/idevice/releases/tag/v0.1.68), pinned by SHA-256 in `Package.swift`. The download is about 214 MB and includes multiple platforms; host tests do not link the native library. The framework's MIT license is included in the app's resource bundle as `IDevice-LICENSE.txt`. For host-side protocol and credential-validation tests:

```sh
swift test --package-path experiments/PhoneInstallProbe
```

## Controlled experiment

Do not change LocalDevVPN's network addresses for this initial test. Copy **Device IP** from its settings into the probe, omitting any `/32` suffix. The default field is a public example from LocalDevVPN's configuration, not a user's address. Do not use its **Tunnel IP**, the Mac's Tailscale address, or an arbitrary LAN device.

After the initial cable install, unplug USB, stop any Mac development tunnel, and turn Wi-Fi fully off in iPhone Settings. The test must begin in that state, without first establishing a development connection on Wi-Fi.

1. Optional control: with cellular and Tailscale connected, select `Cellular + Tailscale` and run the check against the same local VPN peer address. A missing LocalDevVPN route can make this fail; it does not diagnose Tailscale's connection to the Mac.
2. Disconnect Tailscale and connect LocalDevVPN. Keep cellular data on and Wi-Fi off. Select `Cellular + LocalDevVPN` and run the check.
3. If necessary, keep LocalDevVPN connected but temporarily turn **Cellular Data** off in Settings, with Wi-Fi still off. Select `Data off + LocalDevVPN` and run the check again. Do not assume the VPN remains active after the change; inspect it. Restore cellular data afterward.
4. Only after recording the no-Wi-Fi results, a `Wi-Fi control` run can distinguish a generally broken local setup from state-dependent service availability. Such a result is not cellular success.

Record the selected setup and results separately. The app reports a Wi-Fi-specific Network framework path before and after the checks; the operator must still verify the radio, cable and selected VPN. The selected stage is a label, not a measured fact. Authenticated/installation reports are saved locally and can be shared explicitly; basic port-only results remain in memory. Exported results omit addresses, account names, device identifiers and pairing material. A saved unfinished status is not proof that installation failed or succeeded.

## What it actually does

- Connects to the entered private IPv4 address on TCP **49152**, closes the connection, and reports whether TCP accepted it. It sends no RemotePairing authentication. The actual pairing port may vary; failure at this one port is not proof all RemotePairing endpoints are unavailable.
- Connects to TCP **62078** and sends the unauthenticated, read-only Lockdown `QueryType` request. It recognizes only a complete plist reply with the expected service type. An open socket, truncated reply or error plist is never reported as a successful protocol reply.
- Limits each connection to six seconds and each reply to 64 KiB, then closes the socket. Tests run sequentially.
- These initial port checks do not use keys or authenticate. The separate authenticated service test below uses private pairing credentials and performs only an app lookup. Neither check installs an app. The build 3 installation button is a separate action; these manual diagnostic modes do not change network settings. Build & Install delegates network switching to the three helpers.

On recent iOS, a rejected Lockdown query can coexist with a usable newer RemotePairing route. Do not stop at the old-port result. A simulator cannot establish physical-device feasibility; its reports explicitly say so.

## Authenticated test (build 2)

Prepare only your own trusted iPhone, connected by USB and unlocked. An existing pymobiledevice3 RemotePairing record must already exist on the Mac; this helper does not create one or ask for Apple credentials. In a private Python environment with `pymobiledevice3==11.55.0`, run:

```sh
python tools/prepare_phone_probe.py --app /path/to/PhoneInstallProbe.app --install
```

This verifies the signed probe, requires exactly one USB device, installs the probe, validates its recorded version, converts the existing matching RemotePairing record in memory, and transfers it directly to the app's cache over USB. It preserves pymobiledevice3's host identifier. If the Mac was renamed since pairing, recreate a compatible trusted record before testing; do not invent a replacement identifier for old keys.

Open the probe and tap **Load private USB preparation**. It validates the Ed25519 key pair and moves the record to a non-synchronizing Keychain item accessible only while unlocked on this device, then deletes the staging file. Do not export, commit, share, or bundle that credential. No converted record is saved on the Mac by the helper.

Once the status says **Ready**, unplug USB, keep Wi-Fi off, connect LocalDevVPN, and turn Cellular Data off. Select **Data off + LocalDevVPN**, confirm the cable/radio toggle, and tap **Test authenticated service**. Restore Cellular Data after the result.

The test creates a RemotePairing tunnel and performs RSD discovery, connects to Installation Proxy, and looks up only this probe's own bundle. It closes its handles afterward. The native tunnel call combines pairing, tunnel negotiation, and RSD, so an error at that stage does not identify which internal exchange failed. Exported failures include numeric library codes, never raw error strings or keys. The library may fall back to pair setup if verification fails; this test's **app operations** are read-only, but pairing state may change. Successful updated credentials are retained only in the phone's Keychain.

The native library's eight-second timeout applies to some individual operations, **not an overall deadline**. The UI remains responsive and shows a reminder after 60 seconds. There is no unsafe timer that frees native handles while they are in use. Do not start overlapping tests. If you close the probe after an installation request, its outcome is unknown: inspect the installed version before retrying. Completed authenticated reports and the last unfinished milestone are retained locally.

## Staged installation test (build 3)

After the authenticated lookup succeeds, build a target app in Xcode with a valid profile for the phone and a distinct build number. Build the probe as version 3 or newer. While USB is connected, prepare it using the same isolated Python environment:

```sh
python tools/stage_phone_install.py \
  --probe-app /path/to/PhoneInstallProbe.app \
  --target-app /path/to/Target.app \
  --install-probe
```

The helper verifies both signatures, profile expiry and connected-device inclusion. It installs only the probe, retaining its existing Keychain pairing. It packages the target without re-signing, stages its IPA and a private manifest in the probe cache, and compares the uploaded artifact's SHA-256. It refuses a target whose build is already installed and never sends a target install request. Artifacts and manifests are not written into the repository. The implementation currently limits artifacts to 512 MiB and holds the USB packaging/transfer bytes in Mac memory.

In the probe, verify the displayed target name/build before proceeding. Unplug USB, leave Wi-Fi off, connect LocalDevVPN, turn Cellular Data off, select the matching stage, and tap **Install staged build**. The app validates manifest fields, artifact size and SHA-256, authenticates locally, checks the old target build, uploads via AFC into its own uniquely named staging directory, and requests a Developer-package installation. It then requires an exact bundle ID and build-number match from Installation Proxy. Its own staging directory is removed on return, including error paths. A matching build already installed causes a skip, not a new success claim. Self-update of the probe is excluded from this experiment.

Afterward restore Cellular Data, save the report, and separately open the target app. An install-service success alone is insufficient without the version check; neither proves launch. App limits and provisioning expiry still apply. This experiment stages the target over USB; build 4 adds the alternative download path below. No on-phone Apple account login or re-signing is used.

## Download from the Mac (build 4)

Prerequisites: the phone's existing private pairing setup, both devices signed into Tailscale, a running Mac with a signed target build, and a private Python environment with `pymobiledevice3==11.55.0` (including its cryptography dependency). Use an artifact whose build number differs from the installed version. This server publishes an already-built artifact; **Download latest build does not trigger Xcode to build**.

Start the private server on the Mac, replacing the placeholders. Keep it running for downloads:

```sh
python tools/serve_phone_build.py \
  --state-dir "$HOME/Library/Application Support/PhoneInstallProbeServer" \
  --app /path/to/Target.app \
  --bind YOUR_MAC_TAILSCALE_IPV4
```

It binds only to the specified address in `100.64.0.0/10`, on port 8765 by default, and uses HTTPS plus bearer authentication. It never enables Tailscale Funnel, opens a router port, disables the firewall, or listens on all interfaces. The private state directory is mode 0700 and files mode 0600; it contains the server key, certificate, token, manifest, and signed artifacts. Keep it outside the repository and do not share it. Requests are not logged. Only authenticated manifest and content-addressed artifact paths are served, with no directory listing or access to keys/settings.

Build the probe as version 4. For its initial download setup, connect the trusted, unlocked iPhone by USB and run:

```sh
python tools/prepare_phone_download.py \
  --probe-app /path/to/PhoneInstallProbe.app \
  --state-dir "$HOME/Library/Application Support/PhoneInstallProbeServer"
```

This installs the updated probe, preserves its pairing Keychain item, removes old staged target artifacts, and transfers **only** the private endpoint/token/certificate/allowed-app settings. It does not send the target artifact or request target installation. Open the app and tap **Load private USB preparation**. The import is moved into device-only Keychain storage and its temporary cache file is deleted. Confirm **Private Mac connection ready**.

1. Unplug USB. Leave Wi-Fi fully off and Cellular Data **on**.
2. Disconnect LocalDevVPN and connect Tailscale on the phone. The Mac must also remain connected to Tailscale and awake.
3. Select **Cellular + Tailscale**, confirm the Wi-Fi/USB toggle, then tap **Download latest build**. Keep the app in the foreground until it finishes.
4. Confirm the intended name/build and **Downloaded from Mac over private HTTPS**. A failed download must not be treated as a new ready build; inspect the report rather than installing an older cached candidate by mistake.
5. Disconnect Tailscale, connect LocalDevVPN, and turn Cellular Data **off**. Keep Wi-Fi off and USB unplugged.
6. Select **Data off + LocalDevVPN** and tap **Install staged build**. Wait for service success and the exact build match.
7. Restore Cellular Data, disconnect LocalDevVPN, open the target app, and save both reports. Reconnect Tailscale when needed for another download.

The client permits only canonical Tailscale IPv4 HTTPS endpoints, pins the exact configured certificate, checks certificate validity and IP identity, rejects redirects, uses an ephemeral session, and verifies the permitted app identity, byte count and SHA-256 before publishing the staged manifest. It streams the download to disk with a 512 MiB artifact limit, 30-second request timeout and five-minute resource timeout. `NSAllowsLocalNetworking` supports the IP-address connection; there is no global arbitrary-load exception. Download reports omit endpoint, token, certificate, bundle ID and pairing material.

For another build of the same app, build/sign it on the Mac with a new build number, then run the server command again with **`--prepare-only`** while the existing server stays running. This atomically replaces its latest manifest and retains the existing token/certificate. An in-progress download continues to request its original artifact by hash. The phone's next download requires no USB staging. Old content-addressed artifacts accumulate in the private state directory; clean them only when no download needs them. The server currently requires manual start after quitting/rebooting and does not keep the Mac awake.

The first cellular attempt with build 4 failed with secure-connection error -1200. **Use build 5 or newer for the retry.** It adds a narrowly scoped ATS exception for the Tailscale IPv4 range so the private certificate can undergo manual trust evaluation, with TLS 1.2 and forward secrecy retained. The client still accepts only HTTPS and the exact pinned certificate. There is no global arbitrary-load exception. Build 5 reports sanitized TLS milestones and numeric underlying errors to distinguish policy, pinning and handshake failures. The physical phone subsequently downloaded and verified the artifact successfully; the user subsequently confirmed installation and successful launch of that downloaded copy.

The generated certificate lasts one year. Changing the server address, port, allowed app, certificate or token requires securely importing updated settings; do not bypass certificate checks. Phone provisioning expiry and the initial trusted pairing remain separate limitations.

Validation commands:

```sh
python3 -m unittest discover -s tests -p test_build_server.py -v
swift test --package-path experiments/PhoneInstallProbe
```

An optional real-server Swift integration test runs when `PHONE_PROBE_DOWNLOAD_TEST_CONFIG` points to the private `download-settings.json`. It tests download/integrity plus wrong-token and wrong-certificate rejection. Ordinary CI skips this private integration case. Keep its configuration outside source control.

See [the phone-side investigation](../../docs/phone-side-installer-investigation.md) for architecture, evidence and limitations.
