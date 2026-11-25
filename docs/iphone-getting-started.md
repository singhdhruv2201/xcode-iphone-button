# First launch: set up your iPhone and install an app

Use this guide after **Phone Install Probe** has been installed on your iPhone. Once setup is complete, choose a project from your Mac and tap **Build & Install** to get its latest build on your phone.

## Before you open the app

Your Mac must already have working Xcode signing, the build server running, and your project folders configured. One-time USB preparation must also have been completed for this iPhone. **Installing the app alone does not connect it to your Mac.** If these steps are unfinished, follow the [Mac and USB setup tutorial](one-tap-installation.md) first.

On your iPhone, have **Tailscale**, **LocalDevVPN**, and **Shortcuts** installed. Sign Tailscale into the same network as your Mac, approve the VPN setup prompts, and keep LocalDevVPN's default Device IP.

## 1. Load your private setup

1. Open **Phone Install Probe**.
2. Open **Settings → Mac & pairing**, then tap **Load private USB preparation**.
3. Confirm the pairing status says **Ready — stored privately on this iPhone**.
4. On the same screen, confirm **Private Mac connection ready**.

The button updates these labels; it does not open a setup wizard. If either status is missing, complete the corresponding USB preparation in the full tutorial before continuing.

## 2. Add the three helper Shortcuts

Open **Settings → Shortcuts installer**. Under **Connection and recovery helpers**, use each Add button, choose **Shortcuts** in the share sheet, and add:

- **Probe Connect to Mac**
- **Probe Prepare Installation**
- **Probe Restore Internet**

Keep the names unchanged. In Shortcuts, run **Probe Restore Internet** once and approve its first-use prompts. Check that cellular data is on and Tailscale connects. Return to the app and enable **All three helpers are configured**.

## 3. Add the main Shortcut

On that same Shortcuts installer screen, under **Master Shortcut setup**, tap **Add Probe Build & Install**, choose **Shortcuts**, and add it without renaming it. Return to the app and enable **Master Shortcut is configured**.

Start builds from the app's button, **not** the master Shortcut's tile. The app supplies your selected project's run information.

## 4. Choose your project

1. Keep the Mac awake, online, and running its build server.
2. Connect Tailscale on both devices; leave LocalDevVPN disconnected.
3. Open the **Projects** tab and tap **Connect & Refresh**.
4. Choose your project or workspace, then its app **scheme**—the build configuration identifying which app to build. Return to the **Build** tab.

Your selection is remembered. Use **Refresh** when you add projects to the Mac's configured folders.

## 5. Build and install

1. Unplug USB and turn **Wi-Fi off in Settings**.
2. Leave **Cellular Data on** and **Tailscale connected**.
3. Tap **Build & Install** once. Keep the phone unlocked and approve any first-use prompts.
4. Let the process finish without manually changing VPNs or networks.

Shortcuts opens to coordinate the run. Your Mac builds the app, your phone downloads it, and cellular data briefly turns off for installation through LocalDevVPN. Internet access is restored afterward. Some screen switches are expected.

Keep the Mac on its own network: this iPhone's hotspot should not be its only connection.

## 6. Check the result

Wait for the installation-success message. Confirm internet access returns, then open the installed app from your Home Screen and test it.

For future updates, repeat steps 4–6. You do not need USB preparation or Shortcut imports each time. Development signing must remain valid; if it expires, renew the affected app through Xcode.

## If something stops

- **No projects or schemes:** check Tailscale and the Mac server. Use **Check private Mac connection** in Settings → Mac & pairing, then retry Refresh.
- **Build button disabled:** check your project/scheme, both setup toggles, and both Ready statuses. Wait for any active run to finish.
- **Internet stays off:** run **Probe Restore Internet** directly in Shortcuts. If unavailable, turn Cellular Data on, disconnect LocalDevVPN, and reconnect Tailscale manually.
- **Installation interrupted:** check whether the target app was installed before retrying. Do not start another installation while one is still active.

For other errors, use the [full troubleshooting guide](one-tap-installation.md#troubleshooting-by-symptom). Keep pairing records, connection settings, and credentials private.
