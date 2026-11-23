# Security and privacy

## What stays private

Never commit device names/identifiers, account names, personal paths, tailnet/LAN addresses, Mac hostnames, SSH configuration or keys, signing identities/team IDs, provisioning profiles, pairing records, bearer tokens, certificates/private keys, app artifacts, or signed Shortcut exports.

For the one-tap flow, server state belongs outside **every Git checkout**, with directory mode 0700 and file mode 0600. The state includes `build-config.json`, `download-settings.json`, certificates, tokens, manifests, jobs and artifacts. Keep `Signing.local.xcconfig` ignored, or enter signing details through a private configuration. For the legacy SSH flow, device settings belong in the installed private configuration and SSH credentials belong in Shortcuts/SSH settings.

Generated helper workflows contain no personal endpoint or credential, but their signed containers may include signing identity metadata. Generate them locally; never force-add them. Build output, caches, logs and user-specific Xcode files can contain machine paths and signing/device details even when the source is clean.

## One-tap trust boundary

- The Mac HTTPS server binds only to a canonical address within Tailscale's IPv4 range. It does not enable public forwarding or change firewall settings.
- Every artifact/job request requires the private bearer token. Requests are not logged. No directory listing or key/settings download route exists.
- The token grants the ability to build the **configured local project** and retrieve its artifacts. Treat it as a credential even inside a tailnet. Revoke/replace compromised settings and re-import them over trusted USB.
- Job requests accept only a UUID, not a project path, command, scheme, or signing identity. Jobs are serialized and repeated UUIDs are idempotent. Build scripts in the configured Xcode project run with the Mac user's privileges; configure only projects you trust.
- The phone requires the exact pinned TLS leaf certificate plus validity/IP checks, rejects redirects and non-approved endpoints, and verifies bundle identity, size and artifact hash before installation.
- A scoped ATS exception permits private certificate evaluation within the tailnet address range. Application code still rejects HTTP and mismatched certificates; there is no global arbitrary-load exception.
- Pairing and download settings use non-synchronizing Keychain items accessible only while the phone is unlocked on that device. Temporary USB imports are removed after loading. Pairing keys are not embedded in the app or exported reports.
- The native library can repair pairing during authentication. Updated credentials remain private on the phone. The installation probe is not a signing service and never asks for an Apple password.
- Callback job/phase/nonces prevent stale or duplicate Shortcut completion from advancing another flow. A callback alone does not prove network readiness; the Mac connection and local service are checked separately.
- This is not a sandbox for untrusted apps or source projects. Development signing and iOS provisioning checks still apply.

## Connectivity recovery

The installation phase deliberately disables Cellular Data while LocalDevVPN is active. Restore Internet turns data on first, then disables the local VPN and reconnects Tailscale. If a helper fails or the app is killed, restoration may need to be started manually. A native call can outlive its nominal timeout; avoid overlapping installation requests and inspect the installed app after uncertain outcomes.

## Original SSH workflow

The legacy bridge can stop a running Xcode scheme action and build/run the active workspace. Only grant SSH access to trusted clients, keep host verification enabled, and authenticate as the intended logged-in development user. Its installer does not configure SSH, change the firewall, or grant Automation permission. Do not expose the Mac's SSH port publicly for this tool.

## Before publishing changes

Review the exact staged diff and filenames, not only `.gitignore`. Scan for real private values and common credential/device/path patterns. Check commit author and committer metadata and all reachable history. Generic fixture keys, public service port numbers, and public dependency checksums are not personal credentials; actual local records and configured exports must never be included.

Ignored files can still be force-added, and deleting a leaked file from the latest revision does not remove it from history. Rotate exposed credentials first, then arrange appropriate history cleanup if necessary.

## Reporting problems

Use sanitized reproduction steps and software versions in issues. Replace paths/device details with placeholders and inspect screenshots before sharing. Never paste raw pairing output, server settings, SSH details, or full unredacted Xcode logs.

Use GitHub's private vulnerability reporting if enabled. Otherwise request a private contact method without posting exploit details or secrets. Automated tests exercise protocol validation, callback state, server access controls, and isolated scripts; they do not certify every device, tailnet, project build script, VPN version, or provisioning setup.
