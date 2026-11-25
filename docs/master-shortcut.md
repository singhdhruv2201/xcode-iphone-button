# One master Shortcut launched from the app

Build 10 adds **Probe Build & Install**. Start it with the existing **Build & Install** button inside Phone Install Probe. No Action button, Control Center control or widget is required.

The app opens the master Shortcut once. The master owns the sequence and calls the app’s actions for build polling, downloading and installation. These actions never open another Shortcut. The original connection/recovery helpers remain available for setup and recovery.

## Update and setup

1. Generate the signed resources with `python3 tools/make_phone_shortcuts.py --output experiments/PhoneInstallProbe/App/Shortcuts` after configuring the probe’s private signing override. The generator reads the locally configured probe bundle ID for its action descriptors. Only generated, ignored resources contain that private identifier. `--probe-bundle-id` can override it locally.
2. Build and install the updated probe. An already paired iPhone can receive this update through Xcode’s Wi-Fi connection; initial pairing/preparation is still required for a new installation. The existing Keychain pairing and Mac connection settings are reused.
3. Open the app and tap **Add Probe Build & Install** in **Master Shortcut setup**. Choose Shortcuts, import it and keep its exact name. Enable **Master Shortcut is configured**.
4. Keep **Probe Restore Internet** in Shortcuts as a standalone recovery action. Existing connection helpers still support project-list refresh.
5. Select a project and scheme. Unplug USB, turn Wi-Fi off in Settings and keep the phone unlocked with Cellular Data on for the cellular test.
6. Tap the app’s **Build & Install** button. Approve legitimate first-use action permissions. Do not start the master directly from its Shortcuts tile: the app supplies a fresh run token bound to its saved selection.

Updating the probe does not replace an already imported Shortcut. Reimport a changed master using the Add button when its generated actions change.

## Sequence

1. Save a fresh job UUID, random run token and selected project/scheme on the phone.
2. Launch **Probe Build & Install** once with that run token as input.
3. Master enables cellular, disables LocalDevVPN and connects Tailscale. Provider completion dialogs use **Show When Run: off**.
4. **Check selected Mac build** submits the idempotent job, then polls it using requests bounded to 12 seconds. Each invocation returns `waiting`, `ready` or `failed`. The Shortcut waits three seconds between pending checks, with at most 300 checks and an app-side build deadline. Once ready or failed, remaining loop iterations perform no requests or waits.
5. **Download selected Mac build** brings the probe forward, revalidates the job’s selected project and exact manifest, then downloads and verifies its artifact.
6. Only a `ready` download result enters offline mode: disconnect Tailscale, enable LocalDevVPN, then disable cellular.
7. **Install selected Mac build** brings the probe forward, checks Wi-Fi availability, validates the exact staged bundle/version/hash, authenticates locally, installs and verifies the installed version.
8. The master restores cellular first, disables LocalDevVPN and reconnects Tailscale. These actions sit outside the success branches, so app actions reporting failure still lead to restoration.
9. **Finish build and install** shows the result in the probe. The master’s final callback returns to the app; it does not launch a second helper.

Polling can execute without foregrounding the probe. Download/install actions explicitly request the app foreground; this is not a claim of fully background execution. The initial app-to-Shortcuts transition remains. In the physical-phone test, the user confirmed fewer screen switches. This is a reduction in interruptions, not a claim that Shortcuts is never visible.

## State and recovery

- All actions require the current run token, selected project and expected phase. Tokens expire after an hour. A token from another run or an installation action repeated after phase advancement is rejected.
- The job UUID stays stable across submission retries. Mac replies must match the selected project and scheme. The manifest is captured before download and rechecked before installation.
- Native work is marked in progress before requesting installation. A duplicate action does not restart it. Late asynchronous results cannot revive a cancelled or manually recovered run.
- App-level failures are returned as status values so the master can reach its restoration actions. **Cancellation, a provider action throwing an error, iOS terminating an action, or an indefinitely stalled native call can still stop the Shortcut before restoration.** Run the standalone Restore Internet helper, or turn Cellular Data on in Settings and disconnect LocalDevVPN. Inspect the installed app before retrying an interrupted install.
- Long downloads and native operations remain subject to system execution behavior. Background build polling is bounded; the download/install phases use the foreground app. This design does not rely on iOS 27-only LongRunningIntent or widget APIs.
- Keep the Mac awake and its private helper running. Provisioning and free Personal Team limits still apply.

## Validation

Passed: physical-device compilation; wireless Xcode update confirmed on the phone; successful import with no missing-action warning; 18 Swift tests including run-token/phase/expiry checks; generated-workflow simulations covering successful builds, pending/failed builds, download failures and reported install failures.

User-confirmed physical test: started from the app button with Wi-Fi off and USB unplugged; installation completed, internet was restored, and there were fewer screen switches. The Mac independently recorded a completed selected-project job and signed artifact. The final full phone diagnostic report was not supplied for this run, and manual launch was not separately rechecked.

The first attempt was delayed while loading schemes. The Mac independently resolved the test scheme in 2.6 seconds; after confirming Tailscale and reopening the probe, the user loaded the scheme and completed the master run.
