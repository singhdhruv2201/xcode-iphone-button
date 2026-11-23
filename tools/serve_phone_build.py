#!/usr/bin/env python3
"""Serve one signed build privately over HTTPS on a Tailscale IPv4 address.

Artifact downloads and optional fixed-project build jobs; bearer authentication,
no directory listing, no request logs.
State (including keys, token and IPA) must live outside the repository.
Requires the same Python environment as stage_phone_install.py.
"""
import argparse
import base64
import datetime
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
import secrets
import ssl
import subprocess
from pathlib import Path

def tailnet_address(value):
    address = ipaddress.IPv4Address(value)
    if address not in ipaddress.IPv4Network("100.64.0.0/10"):
        raise ValueError("Bind address must be a Tailscale IPv4 address")
    return address


def prepare(state: Path, app: Path, host: str, port: int):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
    from pymobiledevice3.services.installation_proxy import create_ipa_contents_from_directory
    from stage_phone_install import signed_app
    address = tailnet_address(host)
    repo = Path(__file__).resolve().parent.parent
    if state.resolve().is_relative_to(repo):
        raise ValueError("Private server state must be outside the repository")
    ancestor = next(p for p in [state, *state.parents] if p.is_dir())
    if subprocess.run(["git", "-C", str(ancestor), "rev-parse", "--show-toplevel"],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        raise ValueError("Private server state must be outside all Git checkouts")
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)
    info, _ = signed_app(app)
    settings_path = state / "download-settings.json"
    if not settings_path.exists():
        key = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Private Build Server")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - datetime.timedelta(minutes=5))
                .not_valid_after(now + datetime.timedelta(days=365))
                .add_extension(x509.SubjectAlternativeName([x509.IPAddress(address)]), critical=False)
                .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                    key_encipherment=False, data_encipherment=False, key_agreement=False,
                    key_cert_sign=True, crl_sign=True, encipher_only=False, decipher_only=False), critical=True)
                .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                .sign(key, hashes.SHA256()))
        (state / "server.key").write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        (state / "server.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        settings = {"endpoint": f"https://{address}:{port}", "token": secrets.token_urlsafe(32),
                    "certificateDER": base64.b64encode(cert.public_bytes(serialization.Encoding.DER)).decode(),
                    "targetBundleID": info["CFBundleIdentifier"]}
        settings_path.write_text(json.dumps(settings))
    else:
        settings = json.loads(settings_path.read_text())
        if settings["endpoint"] != f"https://{address}:{port}" or settings["targetBundleID"] != info["CFBundleIdentifier"]:
            raise ValueError("Existing private configuration belongs to another endpoint or app")
    artifact = create_ipa_contents_from_directory(str(app))
    if not 0 < len(artifact) <= 512 * 1024 * 1024:
        raise ValueError("Artifact exceeds size limit")
    digest = hashlib.sha256(artifact).hexdigest()
    artifact_path = state / (digest + ".ipa")
    artifact_path.write_bytes(artifact)
    manifest = {"schema": 1, "displayName": info.get("CFBundleDisplayName", info["CFBundleName"]),
                "bundleID": info["CFBundleIdentifier"], "buildVersion": info["CFBundleVersion"],
                "byteCount": len(artifact), "sha256": digest}
    temp = state / "manifest.tmp"
    temp.write_text(json.dumps(manifest))
    temp.replace(state / "manifest.json")
    for path in state.iterdir():
        if path.is_file(): path.chmod(0o600)
    return settings


class BuildServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def get_request(self):
        sock, address = super().get_request()
        sock.settimeout(20)
        try:
            return self.tls_context.wrap_socket(sock, server_side=True), address
        except Exception:
            sock.close()
            raise

    def handle_error(self, *_): pass


def handler_for(state: Path, token: str, jobs=None):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "PrivateBuild"
        sys_version = ""

        def log_message(self, *_): pass

        def json_response(self, value):
            data = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            from phone_build_jobs import JobConflict
            if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), ("Bearer " + token).encode()):
                self.send_error(401)
                return
            if self.path != "/jobs" or jobs is None:
                self.send_error(404)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 128 or self.headers.get("Transfer-Encoding"):
                    raise ValueError()
                request = json.loads(self.rfile.read(length))
                if set(request) != {"id"}: raise ValueError()
                record = jobs.submit(request["id"])
            except JobConflict:
                self.send_error(409)
                return
            except (ValueError, TypeError, AttributeError):
                self.send_error(400)
                return
            self.json_response(record)

        def do_GET(self):
            auth = self.headers.get("Authorization", "")
            if not hmac.compare_digest(auth.encode(), ("Bearer " + token).encode()):
                self.send_error(401)
                return
            if self.path.startswith("/jobs/") and jobs is not None:
                try:
                    record = jobs.get(self.path[len("/jobs/"):])
                except (ValueError, TypeError, AttributeError):
                    record = None
                if record is None: self.send_error(404)
                else: self.json_response(record)
                return
            if self.path == "/manifest.json":
                path, mime = state / "manifest.json", "application/json"
            elif self.path.startswith("/artifacts/") and self.path.endswith(".ipa"):
                name = self.path[len("/artifacts/"):]
                digest = name[:-4]
                if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                    self.send_error(404)
                    return
                path, mime = state / name, "application/octet-stream"
            else:
                self.send_error(404)
                return
            if not path.is_file():
                self.send_error(404)
                return
            try:
                with path.open("rb") as source:
                    self.send_response(200)
                    self.send_header("Content-Type", mime)
                    self.send_header("Content-Length", str(os.fstat(source.fileno()).st_size))
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    while chunk := source.read(256 * 1024): self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass
    return Handler


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        config = prepare(args.state_dir, args.app, args.bind, args.port)
        print("Signed build packaged; private download configuration ready.", flush=True)
        if not args.prepare_only:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(args.state_dir / "server.pem", args.state_dir / "server.key")
            from phone_build_jobs import BuildJobs, build_configured_app
            jobs = BuildJobs(args.state_dir, lambda: build_configured_app(args.state_dir)) if (args.state_dir / "build-config.json").exists() else None
            server = BuildServer((args.bind, args.port), handler_for(args.state_dir, config["token"], jobs))
            server.tls_context = context
            print("Authenticated HTTPS server listening only on the selected Tailscale address.", flush=True)
            server.serve_forever()
    except KeyboardInterrupt:
        print("Build server stopped.")
    except Exception as exc:
        print(f"Build server failed ({type(exc).__name__}); private details not logged.")
        raise SystemExit(1) from None
