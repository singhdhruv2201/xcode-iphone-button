"""Discover trusted local Xcode containers; resolve schemes with Xcode's CLI.

Absolute paths and build settings stay on the Mac. Network clients receive stable
opaque IDs and display paths relative to explicitly configured scan roots.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import threading


class CatalogError(Exception): pass


def project_id(path):
    return hashlib.sha256(str(path.resolve()).encode()).hexdigest()


def valid_id(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def xcode_json(arguments):
    try:
        result = subprocess.run(['/usr/bin/xcodebuild', *arguments, '-json'],
                                capture_output=True, timeout=70)
        if result.returncode or len(result.stdout) > 8 * 1024 * 1024:
            raise CatalogError('Xcode could not inspect this project. Check its packages and schemes on the Mac.')
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, ValueError, OSError):
        raise CatalogError('Xcode project inspection did not finish. Try refreshing after packages resolve.') from None


class ProjectCatalog:
    SKIP = {'.git', '.build', '.swiftpm', 'node_modules', 'Pods', 'Carthage',
            'DerivedData', 'build', '.venv', 'vendor', '.cache'}

    def __init__(self, state, roots, excluded=(), inspect=xcode_json):
        self.state = Path(state)
        self.roots = [Path(p).expanduser().resolve() for p in roots]
        if not self.roots or len(self.roots) > 16: raise ValueError('Configure 1–16 trusted scan roots')
        self.excluded = [Path(p).resolve() for p in excluded] + [self.state.resolve()]
        self.inspect = inspect
        self.lock = threading.RLock()
        self.entries = {}
        self.schemes_cache = {}
        self.refresh()

    def allowed(self, path):
        resolved = path.resolve()
        return (not path.is_symlink() and any(resolved.is_relative_to(r) for r in self.roots)
                and not any(resolved.is_relative_to(p) for p in self.excluded))

    def refresh(self):
        with self.lock:
            found = {}; visited = 0; limited = False
            for root in self.roots:
                if not root.is_dir(): continue
                for folder, directories, _ in os.walk(root, followlinks=False):
                    visited += 1
                    if visited > 20000 or len(found) >= 256:
                        limited = True; break
                    here = Path(folder)
                    if len(here.relative_to(root).parts) > 10 or not self.allowed(here):
                        directories[:] = []; continue
                    keep = []
                    for name in sorted(directories):
                        path = here / name
                        if name.startswith('.') or name in self.SKIP or not self.allowed(path): continue
                        if path.suffix in ('.xcodeproj', '.xcworkspace'):
                            # Do not descend into project packages (including their internal workspace).
                            if len(found) >= 256:
                                limited = True; continue
                            identifier = project_id(path)
                            found[identifier] = {'path': path, 'public': {
                                'id': identifier, 'name': path.stem,
                                'displayPath': str(Path(root.name) / path.relative_to(root)),
                                'kind': 'workspace' if path.suffix == '.xcworkspace' else 'project'}}
                        elif path.suffix not in ('.app', '.xcarchive', '.framework', '.xcframework'):
                            keep.append(name)
                    directories[:] = keep
                if limited: break
            self.entries = found
            self.schemes_cache.clear()
            # Private disk index aids inspection; never serves absolute paths.
            data = {key: str(value['path']) for key, value in found.items()}
            temp = self.state / 'project-catalog.tmp'
            temp.write_text(json.dumps(data)); temp.chmod(0o600)
            temp.replace(self.state / 'project-catalog.json')
            return {'projects': sorted([v['public'] for v in found.values()],
                                      key=lambda p: (p['name'].casefold(), p['displayPath'])),
                    'limited': limited}

    def resolve(self, identifier):
        with self.lock:
            if not valid_id(identifier) or identifier not in self.entries:
                raise CatalogError('Project is no longer available. Refresh the project list.')
            path = self.entries[identifier]['path']
            if not path.is_dir() or not self.allowed(path):
                raise CatalogError('Project moved or is outside the configured folders. Refresh the list.')
            return path

    @staticmethod
    def container_arguments(path):
        return ['-workspace' if path.suffix == '.xcworkspace' else '-project', str(path)]

    def schemes(self, identifier):
        with self.lock:
            path = self.resolve(identifier)
            if identifier not in self.schemes_cache:
                info = self.inspect([*self.container_arguments(path), '-list'])
                container = info.get('workspace', info.get('project', {}))
                names = container.get('schemes', [])
                if not isinstance(names, list): raise CatalogError('Xcode returned invalid schemes.')
                self.schemes_cache[identifier] = sorted({s for s in names if isinstance(s, str) and 0 < len(s) <= 200 and '\0' not in s})[:64]
            return {'projectID': identifier, 'schemes': self.schemes_cache[identifier]}

    def build_spec(self, identifier, scheme):
        path = self.resolve(identifier)
        if scheme not in self.schemes(identifier)['schemes']:
            raise CatalogError('The selected scheme is no longer available. Refresh and select it again.')
        derived = self.state / 'DerivedData' / identifier
        arguments = [*self.container_arguments(path), '-scheme', scheme, '-configuration', 'Debug',
                     '-destination', 'generic/platform=iOS', '-derivedDataPath', str(derived)]
        rows = self.inspect([*arguments, '-showBuildSettings'])
        candidates = []
        for row in rows if isinstance(rows, list) else []:
            settings = row.get('buildSettings', {})
            if (settings.get('PRODUCT_TYPE') == 'com.apple.product-type.application'
                    and settings.get('PLATFORM_NAME') == 'iphoneos'
                    and settings.get('FULL_PRODUCT_NAME', '').endswith('.app')):
                candidates.append(settings)
        if len(candidates) != 1:
            raise CatalogError('Choose a scheme that builds exactly one iPhone app, rather than tests or a library.')
        settings = candidates[0]
        bundle = settings.get('PRODUCT_BUNDLE_IDENTIFIER', '')
        if not re.fullmatch(r'[A-Za-z0-9.-]+', bundle): raise CatalogError('Set a valid app bundle identifier in Xcode.')
        app = Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME']
        if not app.is_absolute(): raise CatalogError('Xcode did not resolve an absolute app output path.')
        return {'arguments': arguments, 'app': app, 'bundleID': bundle,
                'version': settings.get('CURRENT_PROJECT_VERSION', '1')}


def configured_catalog(state):
    path = Path(state) / 'catalog-config.json'
    if not path.exists(): return None
    config = json.loads(path.read_text())
    repo = Path(__file__).resolve().parent.parent
    return ProjectCatalog(state, config['roots'], [repo, *config.get('excludedPaths', [])])
