#!/usr/bin/env python3
"""Stage a signed target app for an unplugged, on-phone installation experiment.

Requires pymobiledevice3 11.55.0. Only the probe is installed over USB; the target
is packaged and copied into the probe's cache, never installed by this script.
Private manifest/artifact bytes are not saved in the repository or printed.
"""
import argparse
import asyncio
import datetime
import hashlib
import json
import logging
import plistlib
import subprocess
from pathlib import Path

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService
from pymobiledevice3.services.installation_proxy import InstallationProxyService, create_ipa_contents_from_directory
from pymobiledevice3.usbmux import list_devices


def signed_app(path: Path):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    info = plistlib.loads((path / "Info.plist").read_bytes())
    profile = plistlib.loads(subprocess.check_output(
        ["/usr/bin/security", "cms", "-D", "-i", str(path / "embedded.mobileprovision")],
        stderr=subprocess.DEVNULL))
    if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise ValueError("Expired provisioning profile")
    if not profile["Entitlements"]["application-identifier"].endswith("." + info["CFBundleIdentifier"]):
        raise ValueError("Profile does not match app")
    return info, profile


async def stage(probe: Path, target: Path, install_probe: bool):
    probe_info, probe_profile = signed_app(probe)
    target_info, target_profile = signed_app(target)
    if probe_info.get("CFBundleName") != "PhoneInstallProbe" or int(probe_info.get("CFBundleVersion", "0")) < 3:
        raise ValueError("Expected probe build 3 or newer")
    probe_id, target_id = probe_info["CFBundleIdentifier"], target_info["CFBundleIdentifier"]
    if probe_id == target_id:
        raise ValueError("Self-update is not part of this experiment")
    devices = [d for d in await list_devices() if d.connection_type == "USB"]
    if len(devices) != 1:
        raise ValueError("Connect exactly one USB iPhone")
    async with await create_using_usbmux(serial=devices[0].serial, connection_type="USB") as device:
        if any(device.udid not in p.get("ProvisionedDevices", []) for p in [probe_profile, target_profile]):
            raise ValueError("Signing profile does not include connected phone")
        async with InstallationProxyService(device) as proxy:
            apps = await proxy.lookup(options={"BundleIDs": [target_id], "ReturnAttributes": ["CFBundleVersion"]})
            if apps.get(target_id, {}).get("CFBundleVersion") == target_info["CFBundleVersion"]:
                raise ValueError("Target build already installed; choose a distinct build number")
            print("Target build differs from installed build; target installation has NOT been requested.", flush=True)
            if install_probe:
                await proxy.install_from_local(probe, developer=True)
                print("Updated probe installed over USB; existing Keychain pairing retained.", flush=True)
            apps = await proxy.lookup(options={"BundleIDs": [probe_id], "ReturnAttributes": ["CFBundleVersion"]})
            if apps.get(probe_id, {}).get("CFBundleVersion") != probe_info["CFBundleVersion"]:
                raise ValueError("Probe version mismatch")
        artifact = create_ipa_contents_from_directory(str(target))
        if len(artifact) > 512 * 1024 * 1024:
            raise ValueError("Artifact exceeds experimental size limit")
        digest = hashlib.sha256(artifact).hexdigest()
        manifest = json.dumps({"schema": 1, "displayName": target_info.get("CFBundleDisplayName", target_info["CFBundleName"]),
                               "bundleID": target_id, "buildVersion": target_info["CFBundleVersion"],
                               "byteCount": len(artifact), "sha256": digest}).encode()
        async with await HouseArrestService.create(device, probe_id, documents_only=False) as container:
            folder = "/Library/Caches/InstallCandidate"
            await container.makedirs(folder)
            # Invalidate any previous manifest before replacing its associated artifact.
            await container.rm(folder + "/manifest.json", force=True)
            await container.set_file_contents(folder + "/application.ipa", artifact)
            uploaded = await container.get_file_contents(folder + "/application.ipa")
            if hashlib.sha256(uploaded).hexdigest() != digest:
                raise ValueError("Staged artifact hash mismatch")
            await container.set_file_contents(folder + "/manifest.json", manifest)
        print("Signed target artifact staged and verified over USB. No target install request sent.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe-app", type=Path, required=True)
    parser.add_argument("--target-app", type=Path, required=True)
    parser.add_argument("--install-probe", action="store_true")
    args = parser.parse_args()
    logging.disable(logging.CRITICAL)
    try:
        asyncio.run(asyncio.wait_for(stage(args.probe_app, args.target_app, args.install_probe), timeout=180))
    except Exception as exc:
        print(f"Artifact preparation failed ({type(exc).__name__}); private details were not logged.")
        raise SystemExit(1) from None
