# Reduce Shortcuts interruptions

This records the build 9 improvements. Build 10 introduces the [single master Shortcut](master-shortcut.md), launched from the app button. Its physical testing is tracked in that guide.

Two separate mechanisms affect the current flow: provider completion dialogs and opening Shortcuts to run a helper.

## Completion dialogs

The user confirmed that turning off **Show When Run** on Tailscale’s Connect action removes the “Tailscale is connected” OK prompt. For existing imports:

1. Edit **Probe Connect to Mac** in Shortcuts.
2. Expand its Tailscale Connect action and disable **Show When Run**.
3. Do the same for Tailscale Connect in **Probe Restore Internet**, and Disconnect in **Probe Prepare Installation** if it shows a completion dialog.
4. Run Restore Internet once to verify the result.

The generator now sets `ShowWhenRun: false` on provider App Intent actions. This affects newly generated/imported helpers; installing a new probe does not rewrite helpers already in the Shortcuts library. Required first-use permission and error dialogs may still appear.

## Fewer screen switches in build 9

Before submitting a selected-project build, the app makes a read-only request to the existing manifest endpoint. The request has a eight-second resource deadline, bearer authentication, exact certificate pinning and manifest identity validation. If it succeeds, the coordinator builds/downloads directly without launching **Probe Connect to Mac**. If it fails, the existing connection helper remains the fallback. A failed or unauthenticated check never authorizes a build.

When the existing connection passes, this reduces three helper handoffs to two. This path has been confirmed on the physical phone. Offline preparation and internet restoration still run in Shortcuts. The app persists the checking phase; a terminated operation is not automatically resumed. The check does not change VPN or Cellular Data settings, request a build or install an artifact.

## Why a Live Activity alone does not remove the remaining handoffs

The current coordinator uses Apple’s documented Shortcuts callback URL. Opening that URL transfers control to Shortcuts; hiding a result dialog does not change that behavior. Apple documents URL invocation for integration from another app and recommends Run Shortcut actions when composing shortcuts inside Shortcuts.

A Dynamic Island Live Activity could display build/download/install progress, but the display does not grant access to other apps’ VPN configurations or replace the network-changing actions. Apple restricts an app’s Network Extension configuration access to configurations it created. Live Activities also have their own execution/network limitations.

A possible next experiment is a single orchestrating Shortcut launched from the Action button or a system widget, calling separate app intents for job submission, bounded polling/download and installation. That would avoid the current three callback URL launches. It has not been implemented or validated: long builds, native installation waits, Keychain access and guaranteed internet restoration after cancellation all need physical-device testing. The existing Build & Install App Intent merely opens the current coordinator, so moving that unchanged action to a widget would retain the same handoffs.

The current Apple SDK also exposes `RunSystemShortcutIntent` and `LongRunningIntent` for iOS 27+. The first is restricted to user-configured widget buttons, not arbitrary in-app calls; the latter extends background task time with progress reporting. Neither is a drop-in solution for the tested iOS 26 device. No OS upgrade is required for the build 9 improvements.

## Validation

- User-confirmed: disabling Show When Run removes the Tailscale Connect completion prompt.
- Passed: host Swift tests, including real pinned HTTPS preflight success and rejection with an invalid token or certificate pin; physical-device compilation.
- The first phone test still used the Connect helper, but installation and internet restoration completed. Build 9 adds a sanitized connection-check report and extends the deadline from three to eight seconds. The earlier fallback’s exact cause was not established.
- Confirmed in the build 9 phone report: authenticated preflight accepted in 0.2 seconds, **Connect helper: skipped**, installation service success, and exact bundle/build verification after 1.2 seconds of installation work. That is installation time, not total build/download time. Manual launch was not rechecked for this final run.
- The read-only **Check private Mac connection** control can diagnose future fallback without starting a build or changing network settings.

## Primary references

- [Apple: run a Shortcut using a URL](https://support.apple.com/guide/shortcuts/run-a-shortcut-from-a-url-apd624386f42/ios)
- [Apple: Network Extension configuration ownership](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager)
- [Apple: Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Apple: RunSystemShortcutIntent](https://developer.apple.com/documentation/appintents/runsystemshortcutintent)
- [Apple: LongRunningIntent](https://developer.apple.com/documentation/appintents/longrunningintent)
- [Tailscale: Mac and iOS Shortcut actions](https://tailscale.com/docs/features/mac-ios-shortcuts)
- [LocalDevVPN: non-opening control App Intent](https://github.com/jkcoxson/LocalDevVPN/blob/main/LocalDevVPN/VPNShortcuts.swift)
