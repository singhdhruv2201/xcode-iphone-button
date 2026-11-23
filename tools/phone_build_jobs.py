"""Bounded, idempotent build jobs for a locally configured Xcode project.

HTTP clients supply only a UUID. Paths/scheme never come from the network.
Job records contain no machine paths or compiler logs. Interrupted jobs fail closed.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import uuid


class JobConflict(Exception): pass


def job_id(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("Canonical UUID required")
    return value


class BuildJobs:
    def __init__(self, state, builder):
        self.folder = Path(state) / "jobs"
        self.folder.mkdir(mode=0o700, exist_ok=True)
        self.builder = builder
        self.lock = threading.Lock()
        self.active = None
        for path in self.folder.glob("*.json"):
            record = json.loads(path.read_text())
            if record["status"] == "building":
                record.update(status="failed", message="Mac helper restarted; start a new build.")
                self._save(record)

    def _save(self, record):
        path = self.folder / (record["id"] + ".json")
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(record))
        temporary.chmod(0o600)
        temporary.replace(path)

    def get(self, identifier):
        path = self.folder / (job_id(identifier) + ".json")
        return json.loads(path.read_text()) if path.exists() else None

    def submit(self, identifier):
        job_id(identifier)
        with self.lock:
            previous = self.get(identifier)
            if previous: return previous
            if self.active: raise JobConflict()
            # Bound disk growth without deleting idempotency records behind a client's back.
            if len(list(self.folder.glob("*.json"))) >= 1000: raise JobConflict()
            self.active = identifier
            record = {"id": identifier, "status": "building", "message": "Building and signing in Xcode…"}
            self._save(record)
            threading.Thread(target=self._work, args=(identifier,), daemon=True).start()
            return record

    def _work(self, identifier):
        try:
            manifest = self.builder()
            record = {"id": identifier, "status": "ready", "manifest": manifest, "message": "Signed build ready"}
        except Exception:
            record = {"id": identifier, "status": "failed", "message": "Build failed. Check Xcode on the Mac; no new build was published."}
        with self.lock:
            self._save(record)
            self.active = None


def build_configured_app(state):
    from stage_phone_install import signed_app
    from serve_phone_build import prepare
    from urllib.parse import urlsplit
    config = json.loads((state / "build-config.json").read_text())
    project = Path(config["project"])
    app = Path(config["app"])
    if not project.is_absolute() or project.suffix != ".xcodeproj" or not app.is_absolute():
        raise ValueError("Invalid local build configuration")
    pbx = project / "project.pbxproj"
    before = pbx.read_text()
    versions = re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", before)
    if not versions or len(set(versions)) != 1:
        raise ValueError("Configure one integer build number in all target configurations")
    version = str(int(versions[0]) + 1)
    updated = re.sub(r"CURRENT_PROJECT_VERSION = \d+;", "CURRENT_PROJECT_VERSION = " + version + ";", before)
    # Keep unrelated user edits. Check again immediately before replacing.
    if pbx.read_text() != before: raise JobConflict()
    temporary = pbx.with_suffix(".build-job.tmp")
    temporary.write_text(updated)
    temporary.chmod(pbx.stat().st_mode & 0o777)
    temporary.replace(pbx)
    script = Path(__file__).with_name("build_phone_project.applescript")
    result = subprocess.run(["/usr/bin/osascript", str(script), str(project), config["scheme"]],
                            capture_output=True, text=True, timeout=960)
    if result.returncode or result.stdout.strip() != "succeeded":
        raise RuntimeError("Xcode build failed")
    info, _ = signed_app(app)
    if str(info["CFBundleVersion"]) != version: raise ValueError("Build output is stale")
    settings = json.loads((state / "download-settings.json").read_text())
    endpoint = urlsplit(settings["endpoint"])
    prepare(state, app, endpoint.hostname, endpoint.port)
    return json.loads((state / "manifest.json").read_text())
