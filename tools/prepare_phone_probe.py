#!/usr/bin/env python3
"""Install the signed probe and stage an existing RemotePairing identity over USB.

Requires pymobiledevice3 11.55.0. No Apple account login, key generation, network
fallback, or secret export. The app imports the staged file into Keychain and
deletes it. Run only for the owner's trusted, unlocked iPhone.
"""
import argparse
import asyncio
import logging
import plistlib
import subprocess
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.pair_records import generate_host_id, get_remote_pairing_record_filename
from pymobiledevice3.services.house_arrest import HouseArrestService
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.usbmux import list_devices


async def prepare(app: Path, install: bool) -> None:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleName") != "PhoneInstallProbe" or int(info.get("CFBundleVersion", "0")) < 2:
        raise ValueError("Expected the authenticated PhoneInstallProbe build")
    bundle = info["CFBundleIdentifier"]
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    devices = [d for d in await list_devices() if d.connection_type == "USB"]
    if len(devices) != 1:
        raise ValueError("Connect exactly one trusted USB iPhone")
    async with await create_using_usbmux(serial=devices[0].serial, connection_type="USB") as device:
        record = Path.home() / ".pymobiledevice3" / (get_remote_pairing_record_filename(device.udid) + ".plist")
        old = plistlib.loads(record.read_bytes())
        private, public = old["private_key"], old["public_key"]
        if len(private) != 32 or len(public) != 32:
            raise ValueError("Invalid key lengths")
        derived = Ed25519PrivateKey.from_private_bytes(private).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        if derived != public:
            raise ValueError("Key mismatch")
        # pymobiledevice3 derives this identifier from this Mac's current hostname.
        # Preserve its uppercase form; do not make a new identity for existing keys.
        converted = {"private_key": private, "public_key": public, "identifier": generate_host_id()}
        if old.get("peer_alt_irk") is not None:
            if len(old["peer_alt_irk"]) != 16:
                raise ValueError("Invalid peer IRK")
            converted["alt_irk"] = old["peer_alt_irk"]
        payload = plistlib.dumps(converted)
        if install:
            async with InstallationProxyService(device) as proxy:
                await proxy.install_from_local(app, developer=True)
            print("Updated signed probe installed over USB.", flush=True)
        async with InstallationProxyService(device) as proxy:
            found = await proxy.lookup(options={"BundleIDs": [bundle], "ReturnAttributes": ["CFBundleVersion"]})
            if found.get(bundle, {}).get("CFBundleVersion") != info["CFBundleVersion"]:
                raise ValueError("Installed build does not match")
        async with await HouseArrestService.create(device, bundle, documents_only=False) as container:
            await container.makedirs("/Library/Caches")
            await container.set_file_contents("/Library/Caches/PairingImport.plist", payload)
            # Verify bytes privately without printing or writing a Mac-side copy.
            if await container.get_file_contents("/Library/Caches/PairingImport.plist") != payload:
                await container.rm("/Library/Caches/PairingImport.plist", force=True)
                raise ValueError("USB staging verification failed")
        print("Private pairing material staged and verified over USB. Open the probe and load preparation.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Signed PhoneInstallProbe.app from Xcode")
    parser.add_argument("--install", action="store_true", help="Install this signed probe before staging credentials")
    args = parser.parse_args()
    logging.disable(logging.CRITICAL)
    try:
        asyncio.run(asyncio.wait_for(prepare(args.app, args.install), timeout=150))
    except Exception as exc:
        # Do not echo underlying exceptions: they can contain paths or device IDs.
        print(f"USB preparation failed ({type(exc).__name__}); no credential contents logged.")
        raise SystemExit(1) from None
