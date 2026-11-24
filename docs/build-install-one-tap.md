# Build & Install from the iPhone

The phone app now coordinates a Mac build, a private cellular download, an offline installation, and restoration of connectivity. It uses the existing free Personal Team signature and the phone's private pairing record.

## Current validation

The earlier manual flow downloaded, installed, and launched the target app successfully without Wi-Fi or USB. The new coordinator builds on those same download and installation components.

The complete one-tap flow is now **user-confirmed on the physical phone**, starting with USB unplugged, Wi-Fi off, Cellular Data on, and Tailscale connected:

- All three bundled helpers were imported; standalone Restore Internet worked.
- The phone initiated a new authenticated Mac job. The server recorded a successful fresh build and exact artifact manifest.
- The user reported successful installation and restored internet after tapping Build & Install.
- The user then opened the updated target app and confirmed it works.

The phone's full final diagnostic report was not pasted for this run, so the install/launch outcome is user-confirmed; the Mac job completion is independently recorded. Earlier manual tests supplied exact bundle/build verification reports.

The updated phone app compiles and is installed. Seventeen Swift tests and fourteen Python build/server/catalog tests pass, including real pinned HTTPS download, invalid token/pin rejection, job idempotency, and stale callback rejection. Existing shell/AppleScript installation checks also pass. This verifies the tested device and setup, not every iOS/VPN version. Build 7 adds the project picker. The user selected a project and scheme on the physical phone, unplugged USB with Wi-Fi off, and ran Build & Install. The Mac independently recorded the matching selected-project job and fresh signed artifact. The user confirmed successful installation, restored internet, and a working launch. Authenticated discovery, refresh and a separate selected-project Mac build also passed.

## One-time setup

1. Keep the Mac's Tailscale connection and private build server running. The Mac must remain awake, with Xcode installed and trusted project folders configured. Selected projects need not be open.
2. Install the updated Phone Install Probe using the existing USB preparation tool. This retains the private Keychain pairing record and imports the Mac connection settings. It does not transfer the target app over USB.
3. In Phone Install Probe, use the three **Add** buttons under **One-time Shortcut setup**. Open each file in Shortcuts and add it under its exact name.
4. Run **Probe Restore Internet** once in Shortcuts and handle initial permission prompts. Confirm Cellular Data is on, LocalDevVPN is disconnected, and Tailscale connects.
5. Enable **All three helpers are configured** in the phone app.

The generated helpers contain no SSH credentials, Mac addresses, API tokens, or pairing records. They use Tailscale and LocalDevVPN's app actions. Signed exports may contain signing identity metadata, so they are ignored by Git and are generated locally.

## Every build

Unplug USB and turn Wi-Fi off in Settings for the cellular test. Keep the phone unlocked and Phone Install Probe open, select a project and iPhone app scheme using **Connect & Refresh**, then tap **Build & Install**.

| Stage | What happens |
| --- | --- |
| Connect | Shortcut turns Cellular Data on, disables LocalDevVPN, and connects Tailscale. |
| Build | The app requests one job on the Mac. Xcode builds and signs the selected catalog project/scheme using a generic iOS destination. No remote phone connection is required. |
| Download | The app polls that job, downloads its exact artifact over pinned HTTPS, and verifies bundle identity, size, and SHA-256. |
| Prepare | Shortcut disconnects Tailscale, enables LocalDevVPN, then turns Cellular Data off. |
| Install | The app checks the local device service, authenticates with the private pairing record, installs the verified artifact, and checks the installed bundle/build. |
| Restore | Shortcut turns Cellular Data on first, disables LocalDevVPN, and reconnects Tailscale. The app reports the installation result. |

Shortcuts may appear briefly. Apple's completion callback returns to the app after the helper finishes; launching Shortcuts alone is never treated as completion. Callbacks must match the stored job, phase, and random nonce, and are consumed once. The app also checks actual Mac/device connectivity before proceeding.

The app's **Build & Install** App Intent is available in Shortcuts and Siri. After setup, an optional Home Screen Shortcut can run that action. The in-app button follows the same flow.

## Recovery

- If a helper fails or is cancelled, use **Restore Internet** in the app or run **Probe Restore Internet** directly in Shortcuts.
- If Shortcuts cannot run, turn **Cellular Data on** in Settings and disconnect LocalDevVPN manually. Reconnect Tailscale when needed.
- If the app is killed during a build or installation, it marks the flow interrupted on relaunch. It will not automatically replay an installation. Restore connectivity and check the installed app before starting again.
- Some native installation-library calls have no overall cancellation deadline. A waiting message appears after 45 seconds; do not start another install while the first is active. The standalone recovery Shortcut remains accessible outside the app.
- If the helper action is unavailable, update the provider app and inspect the imported Shortcut. The expected actions are listed in the table above. Do not substitute Toggle for explicit Connect/Disconnect or Enable/Disable.
- Free Personal Team provisioning still expires. Rebuild/sign while the profile and signing access are valid. This tool does not remove provisioning limits or implement automatic renewal of its own installer app.

## Mac configuration

Keep all server state **outside every Git checkout**. Existing `download-settings.json`, TLS key/certificate, signed artifacts, and pairing material remain private.

Add a private `catalog-config.json` alongside the server settings:

```json
{
  "roots": ["/absolute/path/to/trusted/development"],
  "excludedPaths": []
}
```

See the [complete setup](one-tap-installation.md) and [project picker guide](project-picker.md) for discovery limits, schemes, workspace support and backward compatibility. Selected builds use Xcode’s CLI, resolve the signed output automatically, and pass a private reserved build number without rewriting the project.

Run `tools/serve_phone_build.py` with the existing private state, initial signed app path, Tailscale IPv4 bind address and port. Keep the helper running; no launch-at-login service is installed automatically.

Authenticated jobs bind a canonical UUID to a catalog project ID and validated scheme. Clients cannot submit absolute project paths, shell commands, output paths or signing identities. Jobs are serialized, duplicate UUIDs must retain their selection, interrupted jobs fail closed on restart, and job count is capped at 1,000. Compiler logs stay in the private state folder and are not served to the phone.

Generate the three locally signed resources before building the app:

```sh
python3 tools/make_phone_shortcuts.py --output experiments/PhoneInstallProbe/App/Shortcuts
```

Apple's signing service receives the credential-free helper workflows. Generated `.shortcut` files are intentionally excluded from Git.

## References

- [Apple: Shortcuts completion callbacks](https://support.apple.com/en-nz/guide/shortcuts/apdcd7f20a6f/9.0/ios/26)
- [Tailscale's iOS and Mac Shortcut actions](https://tailscale.com/docs/features/mac-ios-shortcuts)
- [LocalDevVPN's App Intents implementation](https://github.com/jkcoxson/LocalDevVPN/blob/main/LocalDevVPN/VPNShortcuts.swift)
