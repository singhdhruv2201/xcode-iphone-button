"""Read-only, bounded Wi-Fi/cellular diagnostic; requires pymobiledevice3==11.55.0.

Connects only to the supplied Tailscale address using an existing pairing record.
Does not install, launch, pair, change settings, or fall back to USB/local discovery.
Logs event types, timings, counts, and socket states, never keys or packet contents.
"""
import argparse
import asyncio
from contextlib import AsyncExitStack, suppress
from datetime import datetime, timezone
from importlib.metadata import version
import json
import logging
import os
from pathlib import Path
import plistlib
import sys
import time


class TunnelClosedError(ConnectionError):
    """The underlying transport ended; waiting on an inner reply cannot recover it."""


async def wait_with_grace(awaitable, soft_timeout, hard_timeout, on_slow, transport_closed=None):
    """Keep a single request alive past its warning threshold; never duplicate it."""
    task = asyncio.ensure_future(awaitable)
    closed = asyncio.create_task(transport_closed.wait()) if transport_closed is not None else None
    watched = {task, closed} if closed is not None else {task}
    try:
        done, _ = await asyncio.wait(watched, timeout=soft_timeout, return_when=asyncio.FIRST_COMPLETED)
        if not done:
            on_slow()
            done, _ = await asyncio.wait(watched, timeout=hard_timeout - soft_timeout,
                                         return_when=asyncio.FIRST_COMPLETED)
        if task in done:
            return task.result()
        if closed is not None and closed in done:
            raise TunnelClosedError("underlying tunnel closed")
        if not done:
            raise TimeoutError("request exceeded observation window")
    finally:
        for pending in watched:
            if not pending.done():
                pending.cancel()
        await asyncio.gather(*watched, return_exceptions=True)


def socket_state(reader, writer):
    error = reader.exception() if reader else None
    return {
        "eof": reader.at_eof() if reader else None,
        "exception": type(error).__name__ if error else None,
        "writer_closing": writer.is_closing() if writer else None,
    }


async def probe_port(host, port):
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), 3)
        writer.close()
        with suppress(Exception):
            await asyncio.wait_for(writer.wait_closed(), 1)
        return "open"
    except ConnectionRefusedError:
        return "refused"
    except TimeoutError:
        return "timeout"
    except OSError as error:
        return type(error).__name__


async def ping_tailnet(binary, host):
    process = await asyncio.create_subprocess_exec(
        binary, "ping", "--c=1", "--timeout=3s", "--until-direct=false", host,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, _ = await asyncio.wait_for(process.communicate(), 5)
        text = out.decode(errors="replace").lower()
        return {"reply": process.returncode == 0 and "pong" in text,
                "route": "relay" if "derp" in text else ("direct" if "pong" in text else "unknown")}
    except TimeoutError:
        return {"reply": False, "route": "unknown"}
    finally:
        if process.returncode is None:
            process.kill()
            await process.communicate()


async def run(args, emit):
    from pymobiledevice3.remote import tunnel_service
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    from pymobiledevice3.remote.tunnel_service import RemotePairingTunnelService
    from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    if version("pymobiledevice3") != "11.55.0":
        raise RuntimeError("This diagnostic's socket instrumentation requires pymobiledevice3 11.55.0")
    bundle = plistlib.loads((Path(args.app) / "Info.plist").read_bytes())["CFBundleIdentifier"]
    provider = RemotePairingTunnelService(args.device, args.host, args.port)
    tasks = []
    tunnel_service.USE_USERSPACE_TUNNEL = True
    try:
        async with AsyncExitStack() as stack:
            stack.push_async_callback(provider.close)
            await asyncio.wait_for(provider.connect(autopair=False), 15)
            emit("pairing_verified")
            transport = provider.start_tcp_tunnel()
            tunnel = await asyncio.wait_for(stack.enter_async_context(transport), 20)
            client = tunnel.client
            outer_port = client._writer.get_extra_info("peername")[1]
            counts = {"rx_packets": 0, "tx_packets": 0, "last_rx": None}
            original_write = client.tun.write
            original_send = client.send_packet_to_device

            def count_rx(packet):
                counts["rx_packets"] += 1
                counts["last_rx"] = time.monotonic()
                return original_write(packet)

            async def count_tx(packet):
                await original_send(packet)
                counts["tx_packets"] += 1

            # Per-instance counters forward bytes unchanged and do not retain payloads.
            client.tun.write = count_rx
            client.send_packet_to_device = count_tx
            client.tun.set_peer(tunnel.address)
            plane = await stack.enter_async_context(UserspaceDialPlane(client.tun, tunnel.address))
            rsd = RemoteServiceDiscoveryService(
                (tunnel.address, tunnel.port), open_connection=plane.dial,
                auxiliary_metadata=tunnel.auxiliary_metadata,
            )
            stack.push_async_callback(rsd.close)
            await asyncio.wait_for(rsd.connect(), 15)
            if rsd.udid != args.device:
                raise RuntimeError("Unexpected device identity")
            emit("device_identity_verified", dynamic_tunnel_port=outer_port)
            transport_closed = asyncio.Event()

            async def monitor_network():
                while True:
                    ping, pairing, dynamic = await asyncio.gather(
                        ping_tailnet(args.tailscale, args.host),
                        probe_port(args.host, args.port), probe_port(args.host, outer_port),
                    )
                    emit("network", tailscale=ping, pairing_port=pairing, tunnel_port=dynamic)
                    await asyncio.sleep(5)

            async def monitor_transport():
                while True:
                    read_task = client._sock_read_task
                    state = socket_state(client._reader, client._writer)
                    if (read_task is not None and read_task.done()) or state["eof"] or state["exception"]:
                        if not transport_closed.is_set():
                            emit("TUNNEL_CLOSED", error_type=state["exception"])
                        transport_closed.set()
                    emit("transport", control=socket_state(provider._reader, provider._writer),
                         tunnel=state,
                         tunnel_read_task_done=read_task.done() if read_task else None,
                         rx_packets=counts["rx_packets"], tx_packets=counts["tx_packets"],
                         seconds_since_rx=None if counts["last_rx"] is None else round(time.monotonic() - counts["last_rx"], 2))
                    await asyncio.sleep(5)

            async def lookups():
                successes = 0
                while not transport_closed.is_set():
                    stage = "open_installation_service"
                    installer = InstallationProxyService(rsd)
                    try:
                        await asyncio.wait_for(installer.connect(), 20)
                        while True:
                            stage = "installation_lookup"
                            start = time.monotonic()
                            result = await wait_with_grace(
                                installer.lookup(options={"BundleIDs": [bundle], "ReturnAttributes": ["CFBundleVersion"]}),
                                10, 90, lambda: emit("lookup_slow", request_kept_alive=True), transport_closed,
                            )
                            successes += 1
                            emit("lookup_reply", request_seconds=round(time.monotonic() - start, 3),
                                 successes=successes, target_present=bundle in (result or {}))
                            if successes == 3:
                                emit("READY_FOR_HANDOFF")
                            await asyncio.sleep(3)
                    except Exception as error:
                        emit("service_error", stage=stage, error_type=type(error).__name__)
                    finally:
                        with suppress(Exception):
                            await asyncio.wait_for(installer.close(), 3)
                    if transport_closed.is_set():
                        emit("lookups_stopped", reason="tunnel_closed_network_observation_continues")
                        return
                    # A timed-out reader is discarded before opening another, so a late
                    # response can never be misattributed to the following request.
                    await asyncio.sleep(5)

            async def commands():
                reader = asyncio.StreamReader()
                transport, _ = await asyncio.get_running_loop().connect_read_pipe(
                    lambda: asyncio.StreamReaderProtocol(reader), sys.stdin,
                )
                try:
                    while line := await reader.readline():
                        command = line.decode().strip()
                        if command == "quit":
                            return
                        if command in ("wifi", "cellular"):
                            emit("user_reported_network", state=command)
                finally:
                    transport.close()

            async def watch(name, operation):
                try:
                    await operation
                except Exception as error:
                    emit("observer_failed", observer=name, error_type=type(error).__name__)

            tasks = [asyncio.create_task(watch(name, operation)) for name, operation in (
                ("network", monitor_network()), ("transport", monitor_transport()), ("lookups", lookups()),
            )]
            try:
                await asyncio.wait_for(commands(), args.duration)
            except TimeoutError:
                emit("session_time_limit")
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        tunnel_service.USE_USERSPACE_TUNNEL = False
        emit("session_stopped")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--app", required=True, help="Existing .app; only its bundle ID is read")
    parser.add_argument("--tailscale", default="/Applications/Tailscale.app/Contents/MacOS/Tailscale")
    parser.add_argument("--duration", type=int, default=600)
    parser.add_argument("--log", required=True, help="New local .log file, excluded from Git")
    args = parser.parse_args()
    os.umask(0o077)
    logging.disable(logging.CRITICAL)  # third-party logs may include identifiers/payloads
    with open(args.log, "x", encoding="utf-8") as log:
        start = time.monotonic()
        def emit(event, **fields):
            record = {"utc": datetime.now(timezone.utc).isoformat(),
                      "elapsed": round(time.monotonic() - start, 3), "event": event, **fields}
            text = json.dumps(record)
            print(text, flush=True)
            log.write(text + "\n")
            log.flush()
        try:
            asyncio.run(run(args, emit))
        except KeyboardInterrupt:
            pass
        except Exception as error:
            emit("setup_failed", error_type=type(error).__name__)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
