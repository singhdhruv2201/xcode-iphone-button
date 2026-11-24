import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from project_catalog import ProjectCatalog, CatalogError, project_id
from phone_build_jobs import BuildJobs, JobConflict, reserve_build_version

class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.state = self.root / 'private'; self.state.mkdir()
        self.code = self.root / 'code'; self.code.mkdir()
    def tearDown(self): self.temp.cleanup()
    def project(self, relative):
        p = self.code / relative; p.mkdir(parents=True); return p
    def test_scan_refresh_exclusions_and_stable_distinct_ids(self):
        a = self.project('one/App.xcodeproj'); self.project('one/App.xcodeproj/project.xcworkspace')
        b = self.project('two/App.xcodeproj'); self.project('one/Client.xcworkspace')
        self.project('node_modules/Hidden.xcodeproj'); self.project('.hidden/Hidden.xcodeproj')
        excluded = self.project('excluded/Secret.xcodeproj')
        outside = self.root / 'Outside.xcodeproj'; outside.mkdir()
        (self.code / 'Escape.xcodeproj').symlink_to(outside)
        catalog = ProjectCatalog(self.state, [self.code], [excluded.parent])
        initial = catalog.refresh()['projects']
        self.assertEqual(len(initial), 3)
        self.assertEqual(len({p['id'] for p in initial}), 3)
        self.assertNotIn(str(self.root), json.dumps(initial))
        added = self.project('New.xcodeproj')
        self.assertEqual(len(catalog.refresh()['projects']), 4)
        self.assertEqual(catalog.resolve(project_id(a)), a)
        b.rmdir()
        with self.assertRaises(CatalogError): catalog.resolve(project_id(b))
        self.assertEqual(len(catalog.refresh()['projects']), 3)
        for bad in ['../../private', 'a' * 64, str(added)]:
            with self.assertRaises(CatalogError): catalog.resolve(bad)
    def test_rejects_project_replaced_by_external_symlink(self):
        app = self.project('App.xcodeproj')
        catalog = ProjectCatalog(self.state, [self.code])
        identifier = project_id(app)
        app.rmdir(); app.symlink_to(self.state)
        with self.assertRaises(CatalogError): catalog.resolve(identifier)
    def test_scan_limit_even_in_single_directory(self):
        for i in range(260): self.project(f'App{i}.xcodeproj')
        result = ProjectCatalog(self.state, [self.code]).refresh()
        self.assertEqual(len(result['projects']), 256)
        self.assertTrue(result['limited'])
    def test_schemes_and_exact_app_output(self):
        app = self.project('App.xcodeproj'); calls = []
        settings = {'PRODUCT_TYPE':'com.apple.product-type.application','PLATFORM_NAME':'iphoneos',
                    'FULL_PRODUCT_NAME':'Sample.app','TARGET_BUILD_DIR':str(self.state / 'output'),
                    'PRODUCT_BUNDLE_IDENTIFIER':'org.example.sample','CURRENT_PROJECT_VERSION':'2'}
        def inspect(args):
            calls.append(args)
            if '-list' in args: return {'project':{'schemes':['Sample','Tests']}}
            return [{'buildSettings':settings}]
        catalog = ProjectCatalog(self.state, [self.code], inspect=inspect)
        identifier = project_id(app)
        self.assertEqual(catalog.schemes(identifier)['schemes'], ['Sample','Tests'])
        spec = catalog.build_spec(identifier, 'Sample')
        self.assertEqual(spec['bundleID'], 'org.example.sample')
        self.assertIn(str(app), spec['arguments'])
        with self.assertRaises(CatalogError): catalog.build_spec(identifier, 'Sample; echo unexpected')
        settings['PRODUCT_TYPE'] = 'com.apple.product-type.library.static'
        with self.assertRaises(CatalogError): catalog.build_spec(identifier, 'Sample')
    def test_jobs_bind_selection_and_do_not_fall_back(self):
        app = self.project('App.xcodeproj'); catalog = ProjectCatalog(self.state, [self.code])
        release = threading.Event(); calls = []
        def builder(selection, identifier):
            calls.append(selection); release.wait(3); return {'sha256':'selected-artifact'}
        jobs = BuildJobs(self.state, lambda: self.fail('Legacy builder must not run'), catalog, builder)
        identifier = str(uuid.uuid4()); project = project_id(app)
        try:
            record = jobs.submit(identifier, project, 'Sample')
            self.assertEqual(record['selection'], {'projectID':project, 'scheme':'Sample'})
            with self.assertRaises(JobConflict): jobs.submit(identifier, project, 'Other')
            with self.assertRaises(JobConflict): jobs.submit(identifier)
            with self.assertRaises(CatalogError): jobs.submit(str(uuid.uuid4()), 'a'*64, 'Sample')
        finally: release.set()
        deadline = time.monotonic()+3
        while jobs.get(identifier)['status']=='building' and time.monotonic()<deadline: time.sleep(.01)
        result = jobs.get(identifier)
        self.assertEqual(result['selection'], record['selection'])
        self.assertEqual(result['manifest']['sha256'], 'selected-artifact')
        self.assertEqual(len(calls), 1)
    def test_version_reservation_is_per_bundle_and_survives_failure(self):
        self.assertEqual(reserve_build_version(self.state, 'org.example.one', '4'), '5')
        self.assertEqual(reserve_build_version(self.state, 'org.example.one', '4'), '6')
        self.assertEqual(reserve_build_version(self.state, 'org.example.two', '1.2'), '1.3')
        self.assertEqual(reserve_build_version(self.state, 'org.example.one', '20'), '21')

if __name__ == '__main__': unittest.main()
