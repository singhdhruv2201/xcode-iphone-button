# One-tap installation: complete setup

This guide configures the cellular-download/offline-install workflow. Use only your own trusted Mac and iPhone. All example names and paths are placeholders; enter real values only into the specified private local files.

## 1. Prepare the Mac environment

Clone this repository using GitHub's HTTPS clone URL, optionally naming the checkout `remote-xcode-build`. Run repository commands from its root. Keep the environment and server state outside all Git checkouts:

```sh
python3 -m venv "$HOME/Library/Application Support/RemoteXcodeBuildPython"
source "$HOME/Library/Application Support/RemoteXcodeBuildPython/bin/activate"
python -m pip install 'pymobiledevice3==11.55.0'
```

Install Tailscale on both devices, sign into your own tailnet, and connect. Install LocalDevVPN from its official App Store listing on the phone. Approve the system's VPN configuration prompts. Keep LocalDevVPN disconnected during USB preparation and use its default Device IP for one-tap installation.

Build the target app normally in Xcode with working development signing. Use a numeric `CURRENT_PROJECT_VERSION`. Note an existing signed device `.app` output path privately for the initial server bootstrap. The project picker resolves future selected build outputs automatically and overrides the build number on the command line without editing the project file. The target app must match the phone's provisioned device.

## 2. Generate helpers and build the installer

Before building the probe from a fresh checkout, generate its three required bundle resources:

```sh
python tools/make_phone_shortcuts.py --output experiments/PhoneInstallProbe/App/Shortcuts
```

Apple's `shortcuts sign` validates/signs these credential-free workflows. Generated `.shortcut` files are ignored because signed containers can include identity metadata. Do not force-add them to Git.

Create `experiments/PhoneInstallProbe/Signing.local.xcconfig` locally:

```xcconfig
DEVELOPMENT_TEAM = YOUR_PRIVATE_TEAM_ID
PROBE_BUNDLE_ID = your.unique.PhoneInstallProbe
```

This file is ignored. Do not enter personal signing values directly into the tracked project. Open `experiments/PhoneInstallProbe/PhoneInstallProbe.xcodeproj`, select **PhoneInstallProbe**, choose the trusted physical iPhone, and build/run once over USB. Resolve any Developer Mode, trust, or provisioning prompts. The pinned framework is a large download, so first package resolution may take time.

If the probe installs but waits for the debugger, stop that debug session and open it from the phone's Home Screen. Use a physical phone for transport/install validation; simulator results are not sufficient.

## 3. Prepare the private RemotePairing identity

The transfer helper needs an existing compatible pymobiledevice3 **RemotePairing** record for this phone. An ordinary classic Lockdown pairing plist is not interchangeable.

With exactly one trusted, unlocked iPhone connected by USB, pymobiledevice3 11.55.0 exposes the following bootstrap command:

```sh
python -m pymobiledevice3 lockdown remotepairing --pair
```

This is the upstream USB pairing operation, verified in the pinned CLI's help/source. It was not rerun against a clean device during publication; the successful device experiment used an existing record. Keep any output private because it may identify the device. Do not use TLS-secret export flags or paste pairing output into issues. If the command is unavailable, check the installed dependency version rather than substituting a different plist format.

Transfer the existing record into the signed probe:

```sh
python tools/prepare_phone_probe.py --app /absolute/path/to/PhoneInstallProbe.app --install
```

Use the `.app` produced by Xcode, not the `.xcodeproj`. The helper validates the existing key pair, requires one USB phone, transfers the converted identity directly to the app cache, and verifies the transferred bytes without printing them. The host identity must still match the existing record; a renamed Mac may require renewed pairing.

Open the app and tap **Load private USB preparation**. Wait for **Ready — stored privately on this iPhone**. The app validates the record, stores it in device-only Keychain storage, and deletes its import file. Repeat pairing preparation only when needed; do not overwrite a working updated phone identity casually.

## 4. Configure the Mac build job privately

Create a server state folder outside every Git checkout:

```sh
mkdir -p "$HOME/Library/Application Support/PhoneInstallProbeServer"
chmod 700 "$HOME/Library/Application Support/PhoneInstallProbeServer"
```

Create `catalog-config.json` inside that folder, replacing placeholders privately:

```json
{
  "roots": ["/absolute/path/to/trusted/development"],
  "excludedPaths": []
}
```

Set its mode to 600. Only add folders containing projects you trust to execute build scripts. The Mac scans for Xcode containers; `xcodebuild -list -json` discovers schemes for a selected container. See [picker behavior and limits](project-picker.md).

Optionally retain `build-config.json` for older clients using the fixed-target API:


```json
{
  "project": "/absolute/path/to/Example.xcodeproj",
  "scheme": "Example",
  "app": "/absolute/path/to/Debug-iphoneos/Example.app"
}
```

Set this optional file’s mode to 600 too. Do not put either configuration in the checkout. New clients use the catalog and do not need this fixed-target file.

Start the server using the same Python environment:

```sh
python tools/serve_phone_build.py \
  --state-dir "$HOME/Library/Application Support/PhoneInstallProbeServer" \
  --app /absolute/path/to/Debug-iphoneos/Example.app \
  --bind YOUR_MAC_TAILSCALE_IPV4
```

Replace the bind placeholder with the Mac's own Tailscale IPv4 address. The default port is 8765. Leave this process running. Approve legitimate macOS Automation access to Xcode for the process invoking the build, if prompted. Do not grant unrelated permissions or disable the firewall. Tailnet policy must allow the phone to reach this endpoint; no public port forwarding is needed.

Startup verifies/packages the existing signed app and creates a private TLS certificate, key, bearer token, and allowed target identity. The existing settings are reused on restart. With `catalog-config.json` present, authenticated project discovery and selected-project build jobs are enabled. The startup app remains the legacy manual-download target; choosing another project does not require new credentials or USB preparation.

A selected job builds Debug for **generic/platform=iOS** using `xcodebuild`, so the project need not be open in Xcode and the Mac does not need a live device connection. The helper validates signing, bundle identity and the expected new build number before publishing. If it fails, inspect the private `jobs/<UUID>.log` inside the state folder. Build output is kept in a private per-project DerivedData folder.

## 5. Import the private download connection

Keep USB connected, Cellular Data on, Wi-Fi off, and LocalDevVPN disconnected. In a second Terminal with the Python environment activated:

```sh
python tools/prepare_phone_download.py \
  --probe-app /absolute/path/to/PhoneInstallProbe.app \
  --state-dir "$HOME/Library/Application Support/PhoneInstallProbeServer"
```

This updates the probe, retains the pairing Keychain item, clears old staged target artifacts, and transfers only private connection settings. It does not install or transfer the target app. Open the probe and load private preparation; confirm **Private Mac connection ready**.

If endpoint, certificate or allowed target changes later, prepare the connection again over trusted USB. Do not send these settings through GitHub, Notion, or chat.

## 6. Add the network helpers

In **One-time Shortcut setup**, use the three Add buttons and choose Shortcuts to import each signed file. Preserve these exact names:

| Shortcut | Actions, in order |
| --- | --- |
| Probe Connect to Mac | Cellular Data ON → LocalDevVPN Disable → Tailscale Connect |
| Probe Prepare Installation | Tailscale Disconnect → LocalDevVPN Enable → Cellular Data OFF |
| Probe Restore Internet | Cellular Data ON → LocalDevVPN Disable → Tailscale Connect |

Run **Probe Restore Internet** once to handle first-run prompts and verify cellular/Tailscale connectivity. If an action is unavailable, inspect its provider app and imported action; the generated helpers target the provider App Intents, not a personal VPN configuration UUID. Do not replace explicit operations with Toggle. Then enable **All three helpers are configured** in the probe.

## 7. Run and verify

1. Unplug USB. Turn Wi-Fi fully off in Settings. Keep the phone unlocked with Cellular Data and Tailscale on.
2. Tap **Connect & Refresh**, choose the project and its iPhone app scheme. Later, **Refresh** discovers newly created projects. Tap **Build & Install** once. Keep the app in the foreground and let Shortcuts return to it between phases.
3. Observe the final installation result and restored internet.
4. Open the target app manually and verify the updated behavior.

For a Home Screen entry, create a Shortcut containing the probe's **Build & Install** App Intent and use Shortcuts' Add to Home Screen option. The in-app button already runs the full flow; this optional launcher uses the saved project selection and adds no SSH configuration.

## Recovery, renewal and restart

Run **Probe Restore Internet** independently if interrupted. If Shortcuts cannot run, manually turn Cellular Data on and disconnect LocalDevVPN. Do not repeat a native installation while it is still active; a process interrupted after the install request has an unknown outcome until checked.

Keep the Mac awake. Restart the server command after stopping it or rebooting; no startup service is installed by these instructions. Both installer and target need valid provisioning. This implementation does not renew its own expired installer or bypass free-account limits.

See [flow details and evidence](build-install-one-tap.md), [security boundaries](../SECURITY.md), and [historical experiments](phone-side-installer-investigation.md).
