# Remote Xcode Build

**Tap Build & Install on your iPhone to build a signed app on your Mac, download it over cellular, and install it without Wi-Fi or USB.**

The one-tap flow has worked on a physical iPhone using a **free Personal Team**. The tester confirmed installation, restored internet, and successful launch of the updated app. This is an experimental development tool; provisioning limits and expiry still apply.

```text
App: Build & Install
  → Opens one master Shortcut
  → Master connects Tailscale and polls the selected Mac build
  → App action downloads and verifies that job's exact artifact
  → Master switches to LocalDevVPN with cellular OFF
  → App action authenticates locally, installs and verifies
  → Master restores cellular/Tailscale and returns the result
```

The installation step is briefly **offline**. This is not continuous installation over a cellular device tunnel: Tailscale carries the build request/download, and LocalDevVPN provides the phone's local development-service connection afterward. One-time USB preparation is required; routine target updates do not need USB or a preceding Wi-Fi session.

## Choose a workflow

| Workflow | Builds | Installs through | Setup |
| --- | --- | --- | --- |
| **One-tap Build & Install** | A project/workspace and scheme selected on the phone | Phone-side RemotePairing, AFC and Installation Proxy | [Complete setup](docs/one-tap-installation.md) |
| Original SSH button | The active Xcode workspace and selected scheme | Xcode's existing paired-device connection | [Original SSH guide](docs/ssh-xcode-button.md) |

The new flow requires no SSH action or SSH credentials. The original shell/AppleScript bridge remains available. The GitHub repository retains its existing `xcode-iphone-button` name; your checkout folder may be named `remote-xcode-build`.

## Requirements

- An awake, logged-in Mac with Xcode, working app signing, and a target app that already builds for your iPhone.
- A trusted iPhone with Developer Mode enabled and an initial USB connection for preparation. The tested phone used iOS 26.5.1; the app's deployment target is iOS 17, which is not a promise that this route works on every supported OS.
- [Tailscale](https://tailscale.com/download) connected on both devices, with permission for the phone to reach the Mac's private HTTPS port.
- [LocalDevVPN](https://apps.apple.com/app/id6755608044) and Apple's Shortcuts app on the iPhone. Keep LocalDevVPN's default Device IP for the current one-tap implementation.
- Python 3.11+ and `pymobiledevice3==11.55.0` for the Mac helpers; the dependency includes `cryptography`.
- A valid free Personal Team or other appropriate development signature for both installer and target. This does not add TestFlight/Ad Hoc distribution privileges or bypass app/profile limits.

## Setup overview

Follow the [complete installation guide](docs/one-tap-installation.md) for exact commands and private configuration. The main steps are:

1. Clone/download the repository. Create a private Python environment outside the checkout.
2. Create the private, ignored `experiments/PhoneInstallProbe/Signing.local.xcconfig` with your signing team and probe bundle ID, as shown in the complete guide. Then run `python3 tools/make_phone_shortcuts.py --output experiments/PhoneInstallProbe/App/Shortcuts` to generate four signed Shortcuts: the master plus three connection/recovery helpers. They are generated locally and excluded from Git. Configure signing first so the master actions target your actual installed probe.
3. Build **PhoneInstallProbe** in Xcode using your private, ignored signing configuration, then install it once over USB.
4. Establish a compatible RemotePairing record and use `tools/prepare_phone_probe.py` to transfer it privately to the app's device-only Keychain.
5. Configure trusted project scan folders and the private HTTPS server outside every Git checkout. Start the Mac helper; see the [project picker guide](docs/project-picker.md).
6. Use `tools/prepare_phone_download.py` once to import the endpoint, bearer token and certificate pin over USB. No target artifact is sent over USB by this step.
7. In the app, add **Probe Connect to Mac**, **Probe Prepare Installation**, and **Probe Restore Internet** using the three setup buttons. Keep their exact names. Run Restore Internet once, approve initial prompts, and enable **All three helpers are configured**.
8. Add **Probe Build & Install** from **Master Shortcut setup** and enable its configured toggle. Keep the recovery helpers. Tap **Connect & Refresh**, choose a project and its iPhone app scheme. Unplug USB, turn Wi-Fi off in Settings, and tap **Build & Install**. The app remembers your selection; **Refresh** discovers new projects.

Keep the phone unlocked and let the master run; it brings the app forward for download and installation. The latest app uses one master Shortcut launched from its button; no Action button or Control Center setup is required. Provider actions have **Show When Run** off. See [master Shortcut setup and validation](docs/master-shortcut.md). The earlier coordinator’s [connection preflight](docs/quieter-shortcuts.md) remains documented as a previous improvement. After installation, open the target app manually to verify its behavior. The app also exposes a **Build & Install** App Intent for an optional Home Screen Shortcut.

## Upgrade an existing installation to the master Shortcut

Your existing pairing and Mac connection settings are reused.

1. Keep your private `Signing.local.xcconfig`, then regenerate the four local Shortcut resources with the command above. Regenerate them again if you change the probe bundle ID.
2. Build/install the updated probe. Xcode can update an already paired iPhone over Wi-Fi; a cable is not required for that update.
3. In the app, open **Master Shortcut setup**, tap **Add Probe Build & Install**, choose Shortcuts, and add or replace it without renaming it. Enable **Master Shortcut is configured**.
4. Keep **Probe Restore Internet** available independently. Installing an app update does not replace previously imported Shortcuts; reimport the master when its generated actions change.
5. Select a project and scheme, then start with **Build & Install inside the app**. Do not run the master directly from its Shortcuts tile: the app supplies a fresh run token for the selected project.

The app opens Shortcuts once to start the master. The master calls the app when needed and performs the network changes itself. The tested flow installs successfully, restores internet and reduces screen switches; it does not eliminate every system screen or first-use permission prompt. Provider actions have **Show When Run** off to suppress completion dialogs.

If the master is cancelled or stops before restoration, run **Probe Restore Internet** or turn Cellular Data on and disconnect LocalDevVPN manually. See the [master guide](docs/master-shortcut.md) for the sequence and failure behavior.

## How the one-tap flow works

The Mac discovers Xcode projects/workspaces in privately configured folders. Xcode’s CLI resolves schemes, bundle identity and app output. An authenticated job binds a UUID to a catalog project ID and scheme. The Mac reserves a build number and passes it to Xcode without editing the project file, then publishes a signed, content-addressed IPA. Duplicate requests reuse the same selection and job; overlapping jobs are rejected. The phone cannot supply a shell command, absolute project path, output path or signing identity.

The phone verifies the private HTTPS certificate, allowed bundle ID, file size and SHA-256 before entering offline mode. It then uses its stored RemotePairing identity to reach the phone's local installation service, upload through AFC, request installation, and verify the installed bundle/build.

The app saves its phase, job ID and selected project. The master’s app actions require a fresh run token and the expected phase. Callback URLs remain bound to their original run. Opening Shortcuts alone is not success. A local service check precedes authenticated installation; interrupted native work is not silently replayed.

See [development methodology and experiment results](docs/methodology.md), [architecture, setup behavior, and recovery](docs/build-install-one-tap.md), [the phone-side investigation](docs/phone-side-installer-investigation.md), and [the earlier Mac-to-phone tunnel experiments](docs/remote-install-cellular-investigation.md).

## Recovery and current limits

- **Offline or interrupted:** run **Probe Restore Internet** directly in Shortcuts. If unavailable, turn Cellular Data on in Settings and disconnect LocalDevVPN manually.
- **Mac unavailable:** keep it awake and its helper running. The helper is manually started; there is no automatic wake or launch-at-login service.
- **Build error:** check the private `jobs/<UUID>.log` in the server state folder. Compiler logs are not returned to the phone.
- **Provisioning expired:** rebuild/sign the installer and target with valid profiles. Automatic self-renewal of the installer is not implemented.
- **Installation still waiting:** some native calls lack an overall cancellation deadline. Do not start a second installation. After an interruption, restore connectivity and inspect the target app before retrying.
- **Project support:** select an `.xcodeproj` or standalone `.xcworkspace` with a scheme that builds exactly one iPhone app. Debug signing must already work on the Mac, and `CURRENT_PROJECT_VERSION` must be numeric. Library/test-only or ambiguous schemes are rejected. Installer self-update is not implemented. Scan roots must contain only trusted projects because builds may execute their scripts.
- **Resource limits:** artifacts are limited to 512 MiB; the Mac packages them in memory. Jobs are capped at 1,000 records and old artifacts accumulate. Clean private state only when no operation depends on it.

## Privacy

The published repository contains generic source, synthetic tests, and sanitized documentation. It excludes personal paths/device identifiers, SSH configuration/keys, signing team IDs, provisioning profiles, pairing records, certificates/private keys, bearer tokens, built apps/IPAs, and signed Shortcut exports.

The server binds only to the chosen Tailscale IPv4 address, requires bearer authentication, serves no directory listing or private settings/key routes, and does not log requests. The phone pins the exact TLS certificate and rejects redirects, unapproved endpoints, and corrupted artifacts. Pairing and download credentials are stored in non-synchronizing, device-only Keychain items; temporary USB imports are deleted after loading.

Neither workflow changes your firewall or enables public internet forwarding. Shortcut signing uses Apple's service; Tailscale and the separately installed VPN retain their own behavior and policies. See [SECURITY.md](SECURITY.md) for the trust boundary and publication checks.

## Development and verification

```sh
sh tests/check.sh
python3 -m unittest discover -s tests -p 'test_*.py'
swift test --package-path experiments/PhoneInstallProbe
```

The Swift suite includes an optional live HTTPS test, skipped unless `PHONE_PROBE_DOWNLOAD_TEST_CONFIG` points to a private configuration file outside Git. Never configure public CI with personal pairing/signing/server credentials.

The master update passed a physical-device build, 18 Swift tests (including live HTTPS), and three generated-workflow simulations covering success and failure paths. The user confirmed the wireless app update and a master run with successful installation, restored internet and fewer screen switches. CI tests protocol/state validation and synthetic server/installer behavior; it cannot prove hardware installation or VPN switching. Detailed results distinguish captured reports, independently observed Mac jobs, and user-confirmed phone outcomes.

## License and dependencies

[MIT license](LICENSE). The iOS app uses the official [idevice v0.1.68 XCFramework](https://github.com/jkcoxson/idevice/releases/tag/v0.1.68), pinned by URL and SHA-256; its [MIT notice](experiments/PhoneInstallProbe/Sources/ProbeCore/IDevice-LICENSE.txt) is bundled. Tailscale, LocalDevVPN, pymobiledevice3, and their dependencies retain their own licenses. Independent community project; not affiliated with Apple.
