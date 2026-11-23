import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from phone_build_jobs import BuildJobs, JobConflict

class JobsTests(unittest.TestCase):
    def test_idempotency_busy_and_exact_manifest(self):
        with tempfile.TemporaryDirectory() as root:
            release = threading.Event()
            calls = []
            def build():
                calls.append(1)
                release.wait(3)
                return {'sha256': 'exact-job-artifact'}
            jobs = BuildJobs(root, build)
            identifier = str(uuid.uuid4())
            self.assertEqual(jobs.submit(identifier)['status'], 'building')
            self.assertEqual(jobs.submit(identifier)['status'], 'building')
            with self.assertRaises(JobConflict): jobs.submit(str(uuid.uuid4()))
            release.set()
            deadline = time.monotonic() + 3
            while jobs.get(identifier)['status'] == 'building' and time.monotonic() < deadline: time.sleep(.01)
            self.assertEqual(jobs.submit(identifier)['manifest']['sha256'], 'exact-job-artifact')
            self.assertEqual(len(calls), 1)
    def test_rejects_paths_and_recovers_interrupted_job(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root) / 'jobs'; folder.mkdir()
            identifier = str(uuid.uuid4())
            (folder / (identifier + '.json')).write_text(json.dumps({'id':identifier,'status':'building'}))
            jobs = BuildJobs(root, lambda: {})
            self.assertEqual(jobs.get(identifier)['status'], 'failed')
            for value in ['../../server.key', 'anything', '', None]:
                with self.assertRaises((ValueError, TypeError)): jobs.submit(value)
    def test_failure_never_returns_private_exception(self):
        with tempfile.TemporaryDirectory() as root:
            def build(): raise RuntimeError('/private/path secret')
            jobs = BuildJobs(root, build); identifier = str(uuid.uuid4()); jobs.submit(identifier)
            deadline = time.monotonic() + 3
            while jobs.get(identifier)['status'] == 'building' and time.monotonic() < deadline: time.sleep(.01)
            record = jobs.get(identifier)
            self.assertEqual(record['status'], 'failed')
            self.assertNotIn('secret', json.dumps(record))
if __name__ == '__main__': unittest.main()
