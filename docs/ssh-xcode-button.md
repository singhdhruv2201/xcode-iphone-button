# Xcode iPhone Button

**Tap a Shortcut on your iPhone to build and run the project currently open in Xcode.**

Your phone sends a command to your Mac over SSH. The Mac asks Xcode to build the active workspace's selected scheme, install it on your paired iPhone, and launch it using Xcode's existing wireless connection.

```text
iPhone Home Screen → Shortcuts → SSH to your Mac → Xcode → paired iPhone
```

No server, cloud build service, paid companion app, or project-specific build path is required. This is a small shell/AppleScript tool, not an iOS app or an App Store distribution service.

## What it does

- Uses the active Xcode workspace and currently selected scheme.
- Explicitly selects your configured physical iPhone, avoiding the build-only **Any iOS Device** destination.
- Stops a previous scheme action in that workspace before starting a new run, avoiding Xcode's **Replace** prompt.
- Requests a build and debug launch through Xcode's scripting interface.
- Reports build errors and waits up to two minutes for a build result.
- Keeps personal device settings outside the repository. SSH connection details live only in your own Shortcut.

## Requirements

- A Mac with the full Xcode application installed and a project open.
- An iPhone paired with Xcode, with wireless development already working. Enable Developer Mode and trust the Mac if Xcode requires them.
- A scheme that builds and runs successfully on the phone when you click **Run** in Xcode. Signing and provisioning must already work.
- Apple's Shortcuts app on the iPhone, plus Remote Login enabled for your Mac account.
- A reachable network connection between phone and Mac. Start on the same Wi-Fi network, with the Mac awake and logged in and the phone unlocked.

The implementation uses Xcode's installed scripting dictionary. The original workflow was tested with a physical iPhone; compatibility with every Xcode/macOS release is not guaranteed. The automated checks validate installation and script syntax, not wireless deployment.

## Install on the Mac

1. Download this repository using **Code → Download ZIP**, then unzip it. Alternatively clone it using the HTTPS URL shown in **Code**.
2. Open Terminal in the downloaded `xcode-iphone-button` folder. Review the scripts, then run:

   ```sh
   sh install.sh
   ```

3. In **Xcode → Window → Devices and Simulators**, select your iPhone. Enter its exact device name and **Identifier** when the installer asks. Preserve spaces and punctuation in the name. Use Xcode's hardware identifier, not the different CoreDevice UUID printed in some `devicectl` output.

The installer uses no `sudo`, changes no SSH settings, and does not ask for any credentials. It copies the tool to:

```text
~/Library/Application Support/Xcode iPhone Button/
├── run.sh
├── run-xcode.applescript
└── config/
    ├── device-name
    └── device-id
```

Configuration files are readable and writable only by your Mac user. Re-run the installer to update the scripts or configure a renamed/replacement phone. For an advanced custom install location, set `XCODE_IPHONE_BUTTON_HOME` to an absolute path outside the checkout; also adjust your Shortcut's command to that location.

### Test locally first

Open your project in Xcode, select its app scheme, then run:

```sh
/bin/sh "$HOME/Library/Application Support/Xcode iPhone Button/run.sh"
```

This **builds and launches the app**, stopping an existing scheme action in the active workspace. Approve the macOS request to let the invoking application control Xcode. Check that your phone receives the app before setting up SSH.

## Set up the iPhone button

### 1. Enable Remote Login on the Mac

Open **System Settings → General → Sharing → Remote Login**. Allow your intended Mac user. Keep the hostname/address and username shown there private; you will enter them directly in your own Shortcut. This tool does not require enabling full disk access for remote users as a general setup step.

See [Apple's Remote Login instructions](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac).

### 2. Create a Shortcut on your iPhone

In **Shortcuts**, create a shortcut named **Build on iPhone** and add **Run Script Over SSH**.

| Field | What to enter privately on your phone |
| --- | --- |
| Host | Your Mac's local hostname or reachable network address |
| Port | `22`, unless you deliberately configured a different SSH port |
| User | Your Mac account's short username |
| Authentication | Your own Mac login password or an SSH key you have authorized on the Mac |
| Script | The command below |

```sh
/bin/sh "$HOME/Library/Application Support/Xcode iPhone Button/run.sh"
```

`$HOME` is expanded on the Mac by the SSH session. Use the same Mac account that is logged into the graphical session running Xcode.

For key authentication, generate a key in Shortcuts and install **only its public key** in your Mac user's SSH authorized keys using your normal SSH setup. Keep private keys on their originating device. If using a password, enter it directly into Shortcuts; do not put it in a script, issue, screenshot, or this repository.

If Shortcuts blocks scripting, enable **Allow Running Scripts** in its Advanced settings. On iPhone this is generally under **Settings → Apps → Shortcuts → Advanced**; on Mac, **Shortcuts → Settings → Advanced**. Paths can vary by OS version.

### 3. Run it once while at the Mac

The SSH process may need separate permission to control Xcode even if the local test worked. Approve the legitimate macOS prompt while at your Mac. If access is denied, inspect **System Settings → Privacy & Security → Automation** for the requesting process. No UI keystroke automation or Accessibility permission is used by this tool.

Optionally add **Show Result** after the SSH action to display its returned status. Add the shortcut to your Home Screen from its menu. You now have a one-tap build button.

## Everyday use and status messages

Select the intended project window and scheme in Xcode, then tap the phone shortcut. With multiple open projects, the **active workspace** determines what gets built. The configured phone is selected automatically. Save external-editor changes to disk before triggering a build.

| Result | Meaning |
| --- | --- |
| `Build succeeded… Xcode is launching/debugging…` | Compilation succeeded. Xcode is continuing the launch/debug session; this is not an independent confirmation of installation. |
| `Xcode reports success…` | Xcode marked the action successful. |
| `Xcode failed…` or another error | Check the reported error and Xcode's Report navigator. |
| `Xcode is still…` | Two minutes elapsed without a final result. Xcode continues working; the script does not cancel the build. |

The success-log check currently recognizes the English `Build succeeded` text. Other localizations may return the progress message instead. Shortcuts or SSH may impose their own timeout. Device unlock prompts, signing prompts, crashes after launch, and installation errors after the early build-success message still need attention in Xcode.

Avoid simultaneous taps: a new request stops the previous workspace action, and Xcode may invalidate its old result object. This includes an in-progress build or test in that workspace.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| SSH connection refused/times out | Remote Login, correct private Host/User, Mac awake, network reachability, and firewall restrictions. |
| Authentication fails | Verify your SSH password or authorized public key privately. Do not share credentials in an issue. |
| Configured phone is not a destination | Exact device name, pairing, wireless connection, platform support, and project compatibility. Re-run the installer after renaming the phone. |
| Builds but nothing appears on phone | Verify the device Identifier, unlock the phone, and inspect Xcode's launch report. First establish that manual Run works. |
| Automation not authorized | Check macOS Automation permission for the process actually invoking Xcode through SSH. |
| Missing configuration | Use the installed `run.sh`, not the copy in the Git checkout. |
| Xcode result unavailable | Another run may have replaced it. Wait, inspect Xcode, then try once more. |
| Mac asleep, locked, or logged out | Use an awake, logged-in development session. macOS permissions and device prompts may need an unlocked desktop. |

This tool does not fix compiler errors, handle code signing, wake a sleeping Mac, configure networking, or bypass device security prompts. It is intended for a trusted local development network. Do not forward your Mac's SSH port to the public internet just to use this shortcut.

## Privacy

The repository contains generic code and instructions only. The installer stores the device name and identifier outside the checkout and never collects SSH hostnames, usernames, passwords, or keys. The tool has no telemetry or cloud API calls; the only remote transport in this workflow is the SSH connection you configure in Shortcuts and Xcode's device connection.

The `.gitignore` excludes common configuration, key, log, provisioning, and exported-shortcut files as a secondary safeguard. It cannot protect files added with force or credentials pasted into source. Never publish your configured Shortcut, local config folder, screenshots with connection details, or unredacted Xcode logs. See [SECURITY.md](../SECURITY.md).

## Development and checks

On a Mac with Xcode installed:

```sh
sh tests/check.sh
```

Checks compile the AppleScript, validate shell syntax, and test installation in a temporary directory with synthetic device data, including missing/invalid configuration. They do not SSH to a Mac or build an app on a phone. GitHub Actions runs the same checks on macOS.

To verify a real deployment, test local Run, the SSH Shortcut, and a second tap while the app is already running. Keep all resulting device data and build logs private.

## Update or uninstall

To update, download/pull the latest version and re-run `sh install.sh` with your device details. Your Shortcut command stays the same for the default install path.

To uninstall, delete the **Xcode iPhone Button** folder inside your user Library's **Application Support** folder, then delete the phone Shortcut. If you enabled Remote Login or added an SSH key only for this tool, turn it off or remove that specific authorized key using your normal system settings. Do not remove unrelated SSH keys.

## References and license

- [Apple: Build and run your app](https://help.apple.com/xcode/mac/current/en.lproj/devdc0193470.html)
- [Apple: Run an app on a wireless device](https://help.apple.com/xcode/mac/current/en.lproj/dev3e2f4ee6d.html)
- [Apple: Shortcuts scripting security settings](https://support.apple.com/en-gb/guide/shortcuts-mac/apdfeb05586f/mac)
- Xcode's local scripting dictionary: open Xcode in Script Editor's **Open Dictionary** browser.

[MIT license](../LICENSE). Independent community tool; not affiliated with Apple.
