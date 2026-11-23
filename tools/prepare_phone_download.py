#!/usr/bin/env python3
"""Install the download-capable probe and transfer only private connection settings.

No target artifact is sent over USB. Existing staged target files are cleared so
the next target must arrive through the network download path.
"""
import argparse
import asyncio
import json
import logging
from pathlib import Path

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.usbmux import list_devices
from stage_phone_install import signed_app


async def prepare(probe: Path, state: Path):
    info, profile = signed_app(probe)
    if info.get("CFBundleName") != "PhoneInstallProbe" or int(info.get("CFBundleVersion", "0")) < 4:
        raise ValueError("Expected download-capable probe")
    payload = (state / "download-settings.json").read_bytes()
    settings = json.loads(payload)
    manifest = json.loads((state / "manifest.json").read_bytes())
    if settings["targetBundleID"] != manifest["bundleID"]:
        raise ValueError("Target mismatch")
    devices = [d for d in await list_devices() if d.connection_type == "USB"]
    if len(devices) != 1:
        raise ValueError("Connect exactly one USB iPhone")
    async with await create_using_usbmux(serial=devices[0].serial, connection_type="USB") as device:
        if device.udid not in profile.get("ProvisionedDevices", []):
            raise ValueError("Profile does not include this phone")
        async with InstallationProxyService(device) as proxy:
            await proxy.install_from_local(probe, developer=True)
            found = await proxy.lookup(options={"BundleIDs": [info["CFBundleIdentifier"]], "ReturnAttributes": ["CFBundleVersion"]})
            if found.get(info["CFBundleIdentifier"], {}).get("CFBundleVersion") != info["CFBundleVersion"]:
                raise ValueError("Installed probe version mismatch")
        async with await HouseArrestService.create(device, info["CFBundleIdentifier"], documents_only=False) as container:
            await container.rm("/Library/Caches/InstallCandidate", force=True)
            await container.set_file_contents("/Library/Caches/DownloadImport.json", payload)
            if await container.get_file_contents("/Library/Caches/DownloadImport.json") != payload:
                await container.rm("/Library/Caches/DownloadImport.json", force=True)
                raise ValueError("Configuration transfer mismatch")
        print("Download probe installed; private settings transferred; old staged target removed.", flush=True)
        print("No target artifact transferred over USB and no target install requested.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe-app", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    args = parser.parse_args()
    logging.disable(logging.CRITICAL)
    try:
        asyncio.run(asyncio.wait_for(prepare(args.probe_app, args.state_dir), timeout=150))
    except Exception as exc:
        print(f"Download preparation failed ({type(exc).__name__}); private details not logged.")
        raise SystemExit(1) from None
