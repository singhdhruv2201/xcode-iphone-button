# First-time setup: build and install from your iPhone

This tutorial takes you from a checkout of this repository to tapping **Build & Install** on your iPhone, selecting a project on your Mac, and installing its new build without USB or Wi-Fi.

The Mac builds and signs the app. The phone downloads it through Tailscale, then briefly goes offline while LocalDevVPN enables access to its local development service. One master Shortcut handles those network changes and calls Phone Install Probe when needed. At the end, it restores cellular data and Tailscale.

**One-time USB preparation is required.** Routine target-app updates use the phone button. This is an experimental development workflow, successfully exercised with a free Personal Team; it does not bypass signing expiry or account limits. The tested phone used iOS 26.5.1. The app's iOS 17 deployment target does not establish compatibility with every OS/device combination. The clean-device RemotePairing bootstrap has a separate qualification in step 5.

## Before starting

You need:

- Your own Mac with Xcode installed, opened once, and its requested components installed. Keep the Mac logged in, awake, powered, and online during builds.
- Your own iPhone, its passcode, and a USB data cable. Connect only this one iPhone for the preparation commands.
- An Apple account configured in Xcode and a target app that you can already build, sign, install, and open on that phone. A free Personal Team can be used, subject to its provisioning limits.
- Python **3.11 or newer**, Git, and the macOS Shortcuts command-line tool.
- Tailscale on both devices, plus LocalDevVPN and Apple's Shortcuts app on the iPhone.

No SSH setup, public server, router port forwarding, or TestFlight setup is required for this flow. Keep your Mac firewall enabled.

Allow time for Xcode's first build and package downloads. Follow the checkpoints in order; a later step cannot repair an earlier missing signing or pairing setup.

### Where everything lives

| Item | Location / purpose |
| --- | --- |
| Repository | A folder you choose, such as `~/Documents/development/remote-xcode-build` |
| Private Python environment | `~/Library/Application Support/RemoteXcodeBuildPython` |
| Private server state | `~/Library/Application Support/PhoneInstallProbeServer`, outside **every** Git checkout |
| Probe signing configuration | Ignored `experiments/PhoneInstallProbe/Signing.local.xcconfig` |
| Built `.app` files | Xcode's build products, normally in DerivedData; not the repository |
| Pairing and download identity | Imported over USB and stored privately in the phone's device-only Keychain |

Examples such as `YOUR_PRIVATE_TEAM_ID`, `YOUR_MAC_TAILSCALE_IPV4`, and `/absolute/path/to/...` must be replaced locally. Keep quotes around paths containing spaces. Do not paste real credentials, pairing records, device identifiers, or private configuration into issues or documentation.

## 1. Verify Xcode and the target app

**On the Mac and iPhone:**

1. Open Xcode and complete its first-launch setup.
2. In **Xcode → Settings → Accounts**, add your Apple account if needed.
3. Connect and unlock the iPhone. Accept the trust prompts on your own devices.
4. Enable **Developer Mode** on the phone when requested, including the restart and confirmation. Apple's [Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) cover this process.
5. Open the project you eventually want to install remotely. Select its iPhone app scheme and your physical phone as the run destination.
6. Resolve signing in that project's **Signing & Capabilities** settings using your team. Build and run it normally. Open it on the phone and verify it works.
7. Ensure its **Current Project Version** (`CURRENT_PROJECT_VERSION`) is numeric, for example `1`. The remote builder supplies subsequent build numbers without rewriting the project file.

The selected scheme must resolve to exactly one iPhone app. Library-only, test-only, and ambiguous multi-app schemes are not supported. Choose a workspace when your app relies on that workspace's dependencies.

**Find the target `.app`:** after the successful device build, locate the app under **Products** in Xcode's project navigator, right-click it, and choose **Show in Finder**. If needed, use **Xcode → Settings → Locations → Derived Data** to open the build folder and look under `Build/Products/Debug-iphoneos`. Keep the full path to `YourApp.app` privately. A `Debug-iphonesimulator` build will not work.

This signed app is needed to initialize the server. Later, the project picker resolves each selected project's output automatically.

**Checkpoint:** the target app opens on the physical phone, and you know the location of its signed device `.app`.

## 2. Get the repository and prepare Python

**On the Mac, in Terminal:**

If you already have this checkout, open Terminal in it and skip cloning. For a new checkout, open this repository on GitHub, choose **Code → HTTPS**, and copy its clone URL. Replace `REPOSITORY_HTTPS_URL` below with that URL:

```sh
mkdir -p "$HOME/Documents/development"
cd "$HOME/Documents/development"
git clone REPOSITORY_HTTPS_URL remote-xcode-build
cd remote-xcode-build
```

Check the tools:

```sh
xcodebuild -version
python3 --version
git --version
command -v shortcuts
```

`xcodebuild -version` must identify the full Xcode installation. If it reports a command-line-tools selection error, select your installed Xcode under **Xcode → Settings → Locations → Command Line Tools**, then retry.

If Python is older than 3.11, install a supported Python from [python.org's macOS downloads](https://www.python.org/downloads/macos/) and use that interpreter to create the environment. Recheck its version; do not assume the system Python is recent enough.

Create an isolated environment outside the checkout:

```sh
python3 -m venv "$HOME/Library/Application Support/RemoteXcodeBuildPython"
source "$HOME/Library/Application Support/RemoteXcodeBuildPython/bin/activate"
python -m pip install 'pymobiledevice3==11.55.0'
python -c 'import importlib.metadata; print(importlib.metadata.version("pymobiledevice3"))'
```

The last command should print `11.55.0`. This dependency also installs `cryptography` used by the helpers. Use `python` from the activated environment for subsequent commands.

**For every new Terminal window**, change into the repository and activate this same environment. The examples below assume that working directory. Installing these dependencies does not start the build server.

## 3. Set up the two VPN apps

**Tailscale:**

1. Install it using the official [Mac instructions](https://tailscale.com/docs/install/mac) and [iPhone instructions](https://tailscale.com/docs/install/ios).
2. Sign both devices into the same intended tailnet and approve their required system/VPN configuration prompts.
3. Connect both devices. In Tailscale, find the **Mac's Tailscale IPv4 address** and keep it privately for step 6. Use the Mac's address, not the phone's address, a normal Wi-Fi address, or a hostname.
4. If your tailnet has access restrictions, permit this iPhone to reach the Mac on **TCP port 8765**.

**LocalDevVPN:**

1. Install [LocalDevVPN from the App Store](https://apps.apple.com/app/id6755608044) on the iPhone.
2. Open it and approve its VPN configuration prompt. If approval requires starting it once, disconnect it afterward.
3. Keep its **Device IP at the default value** for this implementation. That address belongs to the local device connection; it is not the Mac's Tailscale address.
4. Leave LocalDevVPN **disconnected** during USB preparation. Restore Tailscale if it was disconnected during this setup.

The two apps serve different phases. Tailscale reaches the Mac for building and downloading. LocalDevVPN is used during the offline installation phase. You do not need to make both VPNs active together.

**Checkpoint:** both devices can connect to Tailscale, LocalDevVPN is installed and configured but disconnected, and you have the Mac's private Tailscale IPv4 address.

## 4. Configure, build, and install Phone Install Probe

### A. Configure signing privately

Create this plain-text file inside your checkout:

```text
experiments/PhoneInstallProbe/Signing.local.xcconfig
```

Enter your own values locally:

```xcconfig
DEVELOPMENT_TEAM = YOUR_PRIVATE_TEAM_ID
PROBE_BUNDLE_ID = your.unique.PhoneInstallProbe
```

Use the team ID from your working target's resolved `DEVELOPMENT_TEAM` build setting in Xcode; it is not your Apple account email or the team's display name. Choose an available, unique reverse-domain bundle identifier for the probe, different from the target app. Keep the same probe identity for future updates.

This file is ignored by Git. Keep these values out of the tracked Xcode project and `Config.xcconfig`. You can confirm the exclusion from the repository root:

```sh
git check-ignore experiments/PhoneInstallProbe/Signing.local.xcconfig
```

It should print that file's relative path.

### B. Generate the four Shortcuts

**Configure signing first.** The generator reads your local probe bundle ID so the master Shortcut's app actions point to the app you actually install.

```sh
python tools/make_phone_shortcuts.py --output experiments/PhoneInstallProbe/App/Shortcuts
```

The command generates and signs:

- `Probe Build & Install`
- `Probe Connect to Mac`
- `Probe Prepare Installation`
- `Probe Restore Internet`

Apple's `shortcuts sign` service must be available. Generated `.shortcut` files are ignored because their signed containers can contain identity metadata. Do not force-add them to Git or share your local signed exports as project source.

### C. Install the probe once

1. Open `experiments/PhoneInstallProbe/PhoneInstallProbe.xcodeproj` in Xcode.
2. Select the **PhoneInstallProbe** scheme and your connected physical iPhone.
3. Wait for package resolution. The pinned framework download can take time.
4. Build and run. Resolve any signing, device trust, or Developer Mode prompts.
5. Stop the Xcode debug session after installation, then open **Phone Install Probe** from the iPhone's Home Screen.
6. Find this app's own signed `PhoneInstallProbe.app` product using the same **Products → Show in Finder** method as step 1. Save that path privately too.

You now have **two different `.app` paths**: the probe for USB setup commands and the target for the server's initial signed artifact. Neither is an `.xcodeproj` path.

**Checkpoint:** the probe's test screen opens, and it has **Master Shortcut setup** and **Connection and recovery helpers** sections. If Add buttons are missing, verify generation succeeded before the build, then rebuild the probe.

## 5. Load the private pairing identity over USB

Keep exactly one trusted, unlocked iPhone connected by USB. Leave LocalDevVPN disconnected and cellular data on.

The helper needs a compatible pymobiledevice3 **RemotePairing** record. A classic Lockdown pairing plist is a different format and cannot substitute for it.

For a device without an existing compatible record, the pinned CLI exposes:

```sh
python -m pymobiledevice3 lockdown remotepairing --pair
```

**Verification boundary:** this bootstrap command was checked against pymobiledevice3 11.55.0's help/source. It was not rerun as a complete clean-device setup during publication. The successful installation experiments used an existing compatible record. Treat successful private import and later authenticated installation as the checkpoints; the presence of a plist alone is insufficient.

Keep command output private because it can identify the device. Do not use TLS-secret export flags or post pairing output. If the command is unavailable, verify the pinned dependency version. If you already have a working compatible identity, avoid overwriting it unnecessarily.

Transfer the record with the probe's signed device `.app` path:

```sh
python tools/prepare_phone_probe.py \
  --app "/absolute/path/to/PhoneInstallProbe.app" \
  --install
```

This installs the supplied probe if necessary, validates the existing key pair, transfers the converted identity directly over USB, and checks the transferred bytes without printing the secrets. It expects the existing record under pymobiledevice3's private home-directory storage. A renamed Mac may require renewed pairing because the host identity must still match.

On the phone:

1. Open **Phone Install Probe**.
2. Tap **Load private USB preparation**.
3. Check the pairing status for **Ready — stored privately on this iPhone**.

The app stores the imported identity in device-only Keychain storage and deletes the temporary import. The button does not display a separate wizard; inspect the status text after tapping it.

**Checkpoint:** pairing is Ready. If preparation fails, stop here and inspect the local setup; do not copy keys into source files or substitute another phone's record.

## 6. Configure project discovery and start the Mac server

### A. Create the private state folder

In your activated Terminal at the repository root:

```sh
mkdir -p "$HOME/Library/Application Support/PhoneInstallProbeServer"
chmod 700 "$HOME/Library/Application Support/PhoneInstallProbeServer"
```

Inside that folder, create a plain-text file named **`catalog-config.json`** with your actual trusted development folder path:

```json
{
  "roots": ["/absolute/path/to/trusted/development"],
  "excludedPaths": []
}
```

Use an absolute path. JSON does not expand `~` or `$HOME`. You may add more trusted roots or exclusions as additional strings. Save valid JSON, not rich text, and restrict the file:

```sh
chmod 600 "$HOME/Library/Application Support/PhoneInstallProbeServer/catalog-config.json"
python -c 'import json,pathlib; p=pathlib.Path.home()/"Library/Application Support/PhoneInstallProbeServer/catalog-config.json"; json.loads(p.read_text()); print("Catalog JSON is valid")'
```

Only include projects you trust to execute code on the Mac: Xcode builds can run scripts and resolve dependencies. Discovery scans the configured folders; it is not Xcode's recent-project menu. The installer checkout, hidden/dependency folders, and build outputs are excluded. See [project discovery and limits](project-picker.md).

The current picker does **not** need the optional legacy `build-config.json` used by older fixed-target clients.

### B. Start the server

Use the **target app** from step 1 and the **Mac's Tailscale IPv4 address** from step 3:

```sh
python tools/serve_phone_build.py \
  --state-dir "$HOME/Library/Application Support/PhoneInstallProbeServer" \
  --app "/absolute/path/to/Debug-iphoneos/YourApp.app" \
  --bind YOUR_MAC_TAILSCALE_IPV4
```

Leave this Terminal running. A command that stays active waiting for requests is expected. Do not close it or press Control-C while using the phone workflow.

Startup validates and packages the signed app, then creates private HTTPS credentials and connection settings in the state folder. Port **8765** is the default. The server binds to the chosen Tailscale address; do not substitute `0.0.0.0` or expose it through your router. If macOS asks about incoming connections for the server, allow the intended process while keeping the firewall enabled.

The startup artifact initializes the older manual-download target. The project picker can later build other eligible projects without another USB connection or credential import. Selected builds use Debug and a generic iOS destination, so those projects need not be open in Xcode and the Mac needs no live connection to the phone during the build.

**Checkpoint:** the server remains running without a startup error. Its private state directory contains `download-settings.json`; never print or share that file. Keep the same state folder, bind address, and bootstrap target identity when restarting.

## 7. Import the private Mac connection over USB

Keep the phone unlocked and connected by USB. Turn **Wi-Fi off in Settings**, leave **Cellular Data on**, and leave **LocalDevVPN disconnected**. Tailscale may remain connected.

Open a **second Terminal**. Change to your actual repository folder and activate the environment, leaving the server running in the first Terminal:

```sh
cd "$HOME/Documents/development/remote-xcode-build"
source "$HOME/Library/Application Support/RemoteXcodeBuildPython/bin/activate"
python tools/prepare_phone_download.py \
  --probe-app "/absolute/path/to/PhoneInstallProbe.app" \
  --state-dir "$HOME/Library/Application Support/PhoneInstallProbeServer"
```

Adjust the `cd` path if your checkout is elsewhere. This command updates the probe, preserves its pairing Keychain entry, clears old staged target artifacts, and imports the private endpoint, bearer token, and certificate pin. It does **not** transfer or install the target app over USB.

Open the probe, tap **Load private USB preparation**, and look under **Download from Mac** for **Private Mac connection ready**. The pairing status should remain Ready as well.

With Tailscale connected on both devices, tap **Check private Mac connection**. A successful report includes:

```text
Pinned HTTPS, authentication and Mac identity: accepted.
```

This check does not build, install, or change networks. The server uses a private certificate pinned by the probe; a Safari certificate warning is not a reason to disable verification or install a system-wide certificate profile.

**Checkpoint:** both pairing and Mac connection are Ready, and the connection check succeeds. Project selection later does not require repeating this step. Changes to the endpoint, certificate, or legacy allowed target require matching private configuration and renewed USB preparation.

## 8. Import the helpers and the master Shortcut

### A. Import the connection and recovery helpers

In **Phone Install Probe → Connection and recovery helpers**:

1. Tap **Add Probe Connect to Mac**, choose **Shortcuts** from the share sheet, and add it.
2. Repeat for **Probe Prepare Installation**.
3. Repeat for **Probe Restore Internet**.
4. Keep all names exactly as generated. If replacing an earlier import, replace it rather than leaving a numbered duplicate that the app will not call.

| Helper | Network actions |
| --- | --- |
| Probe Connect to Mac | Cellular ON → LocalDevVPN disable → Tailscale connect |
| Probe Prepare Installation | Tailscale disconnect → LocalDevVPN enable → cellular OFF |
| Probe Restore Internet | Cellular ON → LocalDevVPN disable → Tailscale connect |

In Shortcuts, run **Probe Restore Internet** once. Approve the initial permissions for the intended apps/actions. Verify cellular is on and Tailscale is connected. Return to the probe and enable **All three helpers are configured**.

Generated provider actions have **Show When Run** off. If an older imported Tailscale action displays “Tailscale is connected” and an OK button, edit that action in Shortcuts, expand its options, and turn **Show When Run** off. Do this for relevant Connect/Disconnect actions in old imports, or reimport the regenerated versions. This suppresses completion dialogs, not required first-use system permission prompts.

### B. Import the master

1. In the probe's **Master Shortcut setup**, tap **Add Probe Build & Install**.
2. Choose **Shortcuts** and add it under that exact name.
3. Confirm it imports without missing-action warnings.
4. Return to the probe and enable **Master Shortcut is configured**.

**Start builds with Build & Install inside Phone Install Probe.** Do not launch the master directly from its Shortcuts tile: the app supplies a fresh run token tied to the selected project.

The master handles the sequence itself; the three helpers remain available for connection/recovery and the older manual controls. Keep **Probe Restore Internet** accessible separately in Shortcuts if a run gets interrupted.

**Checkpoint:** all four Shortcuts are imported, Restore Internet works, and both setup toggles are enabled. No Action button or Control Center configuration is needed.

## 9. Choose a project and run the first cellular test

### Select the app

1. Keep the Mac server running and the Mac awake.
2. In **Projects on your Mac**, tap **Connect & Refresh**. This setup action may open Shortcuts to establish connectivity.
3. Choose your project or workspace, then its iPhone app scheme. A single scheme may be selected automatically.
4. Wait until the scheme has loaded and **Build & Install** is available.

A cached project list does not prove the Mac is currently reachable. If schemes stall, verify Tailscale and the connection check before retrying. New projects under the configured roots appear after **Refresh**; you do not have to open them in Xcode first.

### Start the remote test

1. **Unplug USB.**
2. Turn **Wi-Fi fully OFF in the iPhone's Settings app**, not merely disconnected in Control Center.
3. Keep **Cellular Data ON**, **Tailscale connected**, and **LocalDevVPN disconnected**.
4. Keep the iPhone unlocked. Leave the Mac on its own working network; do not use this iPhone's hotspot as the Mac's only internet connection because cellular will briefly be disabled.
5. Tap **Build & Install** once inside the probe.
6. Approve any first-use permissions for the new master actions. Let it run and bring the probe forward when needed; do not manually switch VPNs during the run.

The normal sequence is:

```text
One tap in Phone Install Probe
  → One master Shortcut opens
  → Mac builds and signs the selected project
  → Probe downloads and verifies that build over Tailscale
  → Master disconnects Tailscale, enables LocalDevVPN, disables cellular
  → Probe authenticates locally, uploads and installs the signed app
  → Master enables cellular, disables LocalDevVPN, reconnects Tailscale
  → Probe shows the result
```

Some app/system transitions remain. The master reduces repeated Shortcuts launches; it is not an invisible background installation API. The initial build may be slow while Xcode resolves dependencies.

### Verify all three outcomes

- **Installation:** the final result reports success and the expected app/build. The installer checks the installed bundle identifier and build number.
- **Connectivity:** Cellular Data is back on, LocalDevVPN is disconnected, and Tailscale reconnects. Check that internet access works.
- **Launch:** open the target app yourself from the Home Screen and verify the new behavior. Installation success alone does not prove the app launches correctly.

You have completed setup when all three succeed with USB unplugged and Wi-Fi off. For an unmistakable update check, use a small visible change in the target app before the next build.

## Everyday use and maintenance

For each update, leave the Mac awake with Tailscale and the server running. Open the probe with cellular on, select the saved project/scheme (or choose another), and tap **Build & Install**. Keep Wi-Fi off and USB unplugged for this workflow. The Mac builds the local source currently on disk; the tool does not clone repositories, pull commits, or change branches.

- **New project:** place it under a trusted scan root and tap Refresh. Configure its signing on the Mac first.
- **New scan folder:** edit the private `catalog-config.json`, restart the server, then Refresh.
- **Mac restart:** activate the Python environment in the checkout and rerun the server command from step 6. No automatic startup service is installed. Use the same private state, endpoint, and bootstrap target identity; rebuild an expired bootstrap app before restarting.
- **Probe update:** retain your private signing file and bundle ID, regenerate the Shortcuts, rebuild/install the probe, and reimport a changed master. An already paired phone may receive an Xcode update over Wi-Fi. Installing the app does not replace existing Shortcuts in your library.
- **Expired signing:** renew/rebuild using Xcode and valid development profiles. Both the probe and target need valid provisioning. Automatic self-renewal of the probe is not implemented; plan access to the Mac/device setup before expiry.
- **Private storage:** artifacts and job logs accumulate in the state folder. The current implementation limits artifact size to 512 MiB and jobs to 1,000 records. Review storage when no operation is active; do not remove state needed by an active job.

See [master Shortcut behavior](master-shortcut.md) for its phase checks and recovery limitations.

## Troubleshooting by symptom

| Symptom | What to check / do |
| --- | --- |
| Python import or missing-command error | Activate the private environment in this Terminal and confirm pymobiledevice3 is `11.55.0`. Use Python 3.11+. |
| Probe signing fails | Verify the ignored signing file, unique bundle ID, Xcode account, valid team/profile, and physical-device destination. Fix ordinary Xcode signing before retrying helper scripts. |
| Probe installed but will not open | Stop the Xcode debug session and open it from Home Screen. Check Developer Mode and signing validity. An expired profile needs a newly signed build. |
| Add Shortcut buttons are missing | Generate all four resources after setting the private bundle ID, then rebuild/install the probe. |
| Missing or unknown Shortcut action | Open/update the provider app, confirm the probe is installed, regenerate using its actual bundle ID, and reimport. Do not substitute Toggle for explicit connect/disconnect operations. |
| Pairing import fails | Connect exactly one unlocked, trusted USB phone; verify a compatible RemotePairing record exists and the probe path is a signed device build. A classic Lockdown record will not work. |
| Load private USB preparation seems to do nothing | Read both status labels. Already-loaded preparation can remain Ready without a modal. If Mac connection is not Ready, rerun step 7 and load again. |
| Server exits immediately | Check the target `.app` path/profile, private state location, Mac Tailscale address, and port availability. Existing state must match the endpoint and bootstrap app identity. Do not delete credentials casually to bypass a mismatch. |
| HTTPS/network error, including `-1200` | Check both Tailscale connections, running server, tailnet access to port 8765, and imported endpoint/pin. If credentials or the certificate changed, reprepare over USB. Do not turn off TLS verification. |
| Project is missing | Check absolute scan roots and exclusions, restart after config edits, and Refresh. Hidden/dependency directories and the installer checkout are excluded. Narrow the roots if scan limits are reached. |
| Scheme keeps loading | Verify the private Mac connection, then reopen the probe and retry selection. Package resolution may take time. Confirm the same container/scheme works in Xcode. |
| Build & Install is disabled | Wait for scheme loading; check the selected scheme, both setup toggles, pairing Ready, and Mac connection Ready. An unfinished active flow also blocks a new run. |
| Remote build fails | Inspect `jobs/<UUID>.log` inside the private state folder locally. Check signing, dependencies, numeric build version, and one-app scheme support. Do not publish raw logs containing personal paths or identifiers. |
| Offline installation cannot connect | Check Wi-Fi is fully off, USB is unplugged, LocalDevVPN uses its default Device IP, and cellular is off only during the install phase. Do not change networks while an installation request remains active. |
| Run stops with internet off | Run Probe Restore Internet directly in Shortcuts. If unavailable, manually turn Cellular Data on, disconnect LocalDevVPN, then reconnect Tailscale. |
| Installation was interrupted or appears stuck | Some native calls have no overall deadline. Do not launch a second installation while one is active. If the process was interrupted, restore internet and inspect the target before retrying; the previous install outcome may be unknown. |
| Master works but switches screens | An initial Shortcuts launch and foreground app actions are expected. Turn off Show When Run for provider completion dialogs; first-use permission prompts still need approval. |

## Keep private setup out of Git

Only generic source, tests, and sanitized documentation belong in this repository. Keep server state and the Python environment outside every checkout. The local signing file and generated signed Shortcuts are ignored, as are pairing imports, keys, profiles, built apps, and IPAs. Never use `git add -f` to include these files.

Before sharing changes, inspect `git status` and the staged diff. Share sanitized failure summaries rather than private configuration, Terminal transcripts, or device screenshots containing identifiers. See [SECURITY.md](../SECURITY.md) for the full boundary.

For the development history and what was actually verified, read [methodology](methodology.md) and [master Shortcut validation](master-shortcut.md). The [original SSH guide](ssh-xcode-button.md) documents a separate workflow and is not a prerequisite for this tutorial.
