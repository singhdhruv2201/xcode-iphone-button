# Select a Mac project from your iPhone

Phone Install Probe build 7 adds a project picker above Build & Install. Existing pairing, private HTTPS settings and the three network Shortcuts are reused.

## Everyday flow

1. Keep the Mac awake with its helper running. Open the probe with cellular on.
2. Tap **Connect & Refresh** if Tailscale is not connected; otherwise use **Refresh**. The app also attempts a refresh when its main view first opens.
3. Choose a project or workspace, then its iPhone app scheme. A single scheme is selected automatically. The relative project path helps distinguish similarly named projects.
4. With USB unplugged and Wi-Fi off, tap **Build & Install**. The existing download, offline installation and internet restoration sequence runs.
5. Open the installed app manually to check its behavior.

Selection is saved privately on the phone and reused by the Build & Install App Intent. Refresh rescans the configured Mac folders; newly created projects appear without restarting the helper. A removed project clears the selection, rather than selecting a replacement. Failed refreshes retain the cached list. A moved project has a new ID and must be selected again.

## Mac configuration

Create `catalog-config.json` in the private server state folder, outside every Git checkout, with mode 600:

```json
{
  "roots": ["/absolute/path/to/trusted/development"],
  "excludedPaths": ["/absolute/path/to/optional/excluded/folder"]
}
```

Restart the helper after changing these folders. The installer checkout and private server state are excluded automatically. Hidden folders, dependency folders, build products, symbolic links and nested project-package internals are skipped. Scans are bounded to 16 roots, 20,000 visited directories, 256 containers and 10 directory levels. Narrow roots if the app reports a scan limit.

This is a filesystem scan, not Xcode’s recent-project list. Xcode has no global project-list command. The helper calls `xcodebuild -list -json` lazily for the selected container, then `-showBuildSettings -json` to resolve the app target. A standalone workspace and its project may both appear; choose the workspace when the app depends on it.

## Build and artifact binding

Authenticated endpoints:

- `GET /projects`: rescan and return opaque IDs, names, relative display paths and container kind.
- `GET /projects/<ID>/schemes`: resolve the registered container’s schemes.
- `POST /jobs`: accept `{ "id": "<UUID>", "projectID": "<catalog ID>", "scheme": "<scheme>" }`.
- `GET /jobs/<UUID>`: return status, bound selection and the exact completed artifact manifest.

Absolute paths remain authoritative on the Mac. The phone snapshots its selection before launching the network helper. Every job reply must match the requested project and scheme; a reused UUID with a different selection is rejected. The signed output must match the resolved bundle identifier and newly reserved build version. The phone checks the exact job artifact’s size and SHA-256 before installation.

Selected builds use Debug, the generic iOS destination, a private per-project DerivedData directory and existing Mac signing credentials. `CURRENT_PROJECT_VERSION` is overridden for the build using a private per-bundle counter. Project files are not rewritten. `-allowProvisioningUpdates` permits Xcode to use the account/signing setup already configured on the Mac.

The older `{ "id": "<UUID>" }` request and manual latest-download route retain their fixed-target behavior when the optional legacy build configuration exists. They do not silently become the newly selected target.

## Limits and privacy

Choose a scheme that resolves exactly one iPhone app. Library/test-only and ambiguous multi-app schemes fail with a clear message. Signing capabilities and free Personal Team limits still apply independently to every selected app. This does not clone repositories, change branches, commit code, refresh the installer’s own provisioning or install the installer itself.

A trusted project can execute build scripts and resolve package dependencies. Only configure trusted scan roots; anyone with the private service credential can request builds of discovered projects. Keep catalog configuration, indexes, logs, version counters and phone selection caches private. Project names and relative paths travel only through the existing authenticated, pinned HTTPS connection.

Verification covers discovery bounds/exclusions, moved or replaced projects, scheme validation, per-bundle versions, HTTP authentication, selection-bound jobs and Swift reply validation. The new picker was also verified on the physical phone: the user selected a project and scheme, ran Build & Install with USB unplugged and Wi-Fi off, and confirmed installation, restored internet and successful target launch. The Mac independently recorded the matching selected-project job and signed artifact. This is evidence for the tested project/device, not every Xcode project or iOS version.
