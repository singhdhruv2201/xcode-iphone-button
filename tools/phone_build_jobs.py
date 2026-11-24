"""Bounded, idempotent build jobs for a locally configured Xcode project.

Clients supply a UUID and optional catalog project ID and scheme.
The Mac resolves paths and validates schemes against Xcode.
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
    def __init__(self, state, builder, catalog=None, selected_builder=None):
        self.folder = Path(state) / "jobs"
        self.folder.mkdir(mode=0o700, exist_ok=True)
        self.builder = builder
        self.catalog = catalog
        self.selected_builder = selected_builder
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

    def submit(self, identifier, project=None, scheme=None):
        job_id(identifier)
        selection = None
        if project is not None or scheme is not None:
            from project_catalog import valid_id
            if (not valid_id(project) or not isinstance(scheme, str) or not 0 < len(scheme) <= 200
                    or "\0" in scheme or self.catalog is None or self.selected_builder is None):
                raise ValueError("Invalid project selection")
            selection = {"projectID": project, "scheme": scheme}
        with self.lock:
            previous = self.get(identifier)
            if previous:
                if previous.get("selection") != selection: raise JobConflict()
                return previous
            if selection: self.catalog.resolve(project)
            if self.active: raise JobConflict()
            # Bound disk growth without deleting idempotency records behind a client's back.
            if len(list(self.folder.glob("*.json"))) >= 1000: raise JobConflict()
            self.active = identifier
            record = {"id": identifier, "status": "building", "message": "Building and signing in Xcode…"}
            if selection: record["selection"] = selection
            self._save(record)
            threading.Thread(target=self._work, args=(identifier, selection), daemon=True).start()
            return record

    def _work(self, identifier, selection):
        try:
            manifest = self.selected_builder(selection, identifier) if selection else self.builder()
            record = {"id": identifier, "status": "ready", "manifest": manifest, "message": "Signed build ready"}
        except Exception as error:
            from project_catalog import CatalogError
            record = {"id": identifier, "status": "failed", "message": "Build failed. Check Xcode on the Mac; no new build was published."}
            if isinstance(error, CatalogError): record["message"] = str(error)
        if selection: record["selection"] = selection
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


def reserve_build_version(state, bundle, configured):
    """Reserve a version without editing any selected repository's project file."""
    from project_catalog import CatalogError
    path = state / "build-versions.json"
    versions = json.loads(path.read_text()) if path.exists() else {}
    values = [str(configured), str(versions.get(bundle, "0"))]
    legacy = state / "manifest.json"
    if legacy.exists():
        manifest = json.loads(legacy.read_text())
        if manifest.get("bundleID") == bundle: values.append(str(manifest["buildVersion"]))
    if any(not re.fullmatch(r"\d+(?:\.\d+){0,2}", v) for v in values):
        raise CatalogError("Set a numeric CURRENT_PROJECT_VERSION for this app in Xcode.")
    parts = list(max((tuple(int(n) for n in v.split(".")) for v in values), key=lambda p: p + (0,) * (3-len(p))))
    parts[-1] += 1
    version = ".".join(str(n) for n in parts)
    versions[bundle] = version
    temp = path.with_suffix(".tmp"); temp.write_text(json.dumps(versions)); temp.chmod(0o600); temp.replace(path)
    return version


def build_selected_app(state, catalog, selection, identifier):
    from project_catalog import CatalogError
    from stage_phone_install import signed_app
    from serve_phone_build import package_artifact
    spec = catalog.build_spec(selection["projectID"], selection["scheme"])
    version = reserve_build_version(state, spec["bundleID"], spec["version"])
    # Arguments are an array, never a shell command. Only catalogued paths and schemes are used.
    command = ["/usr/bin/xcodebuild", *spec["arguments"], "CURRENT_PROJECT_VERSION=" + version,
               "-allowProvisioningUpdates", "build"]
    log = state / "jobs" / (identifier + ".log")
    with log.open("wb") as output:
        log.chmod(0o600)
        try:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=900)
        except subprocess.TimeoutExpired:
            raise CatalogError("The build exceeded its time limit. Check the private build log on the Mac.") from None
    if result.returncode:
        raise CatalogError("Xcode build failed. Check signing, packages, and the private job log on the Mac.")
    info, _ = signed_app(spec["app"])
    if info["CFBundleIdentifier"] != spec["bundleID"] or str(info["CFBundleVersion"]) != version:
        raise CatalogError("The app output did not match the selected target and new build number. Check its Info.plist settings.")
    # No change to the legacy default app or its download credential is required.
    return package_artifact(state, spec["app"])
