import hashlib
import http.client
import http.server
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from serve_phone_build import handler_for, tailnet_address
from project_catalog import ProjectCatalog
from phone_build_jobs import BuildJobs
import uuid


class BuildServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.artifact = b"synthetic artifact"
        self.digest = hashlib.sha256(self.artifact).hexdigest()
        (self.root / (self.digest + ".ipa")).write_bytes(self.artifact)
        (self.root / "manifest.json").write_text(json.dumps({"sha256": self.digest}))
        (self.root / "server.key").write_text("synthetic secret must not be served")
        code = self.root / 'code'; code.mkdir()
        (code / 'Example.xcodeproj').mkdir()
        catalog_state = self.root / 'catalog-state'; catalog_state.mkdir()
        self.catalog = ProjectCatalog(catalog_state, [code], inspect=lambda args: {'project': {'schemes': ['Example']}})
        self.project = self.catalog.refresh()['projects'][0]['id']
        jobs = BuildJobs(self.root, lambda: {"sha256": self.digest}, self.catalog,
                         lambda selection, identifier: {"sha256": self.digest})
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler_for(self.root, "test-token", jobs, self.catalog))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def get(self, path, token=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        headers = {} if token is None else {"Authorization": "Bearer " + token}
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def post(self, body, token="test-token"):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        connection.request("POST", "/jobs", body=json.dumps(body), headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def test_job_requests_are_authenticated_and_cannot_supply_commands(self):
        identifier = str(uuid.uuid4())
        self.assertEqual(self.post({"id":identifier}, token="bad")[0], 401)
        self.assertEqual(self.post({"id":identifier, "command":"anything"})[0], 400)
        self.assertEqual(self.post({"id":"../../private"})[0], 400)
        self.assertEqual(self.post({"id":identifier})[0], 200)
        self.assertEqual(self.get("/jobs/" + identifier)[0], 401)
        status, payload = self.get("/jobs/" + identifier, "test-token")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(payload)["id"], identifier)

    def test_requires_correct_token_for_manifest_and_artifact(self):
        for path in ["/manifest.json", "/artifacts/" + self.digest + ".ipa"]:
            self.assertEqual(self.get(path)[0], 401)
            self.assertEqual(self.get(path, "incorrect")[0], 401)
        self.assertEqual(self.get("/artifacts/" + self.digest + ".ipa", "test-token"), (200, self.artifact))

    def test_never_serves_private_state_or_traversal(self):
        for path in ["/", "/server.key", "/download-settings.json", "/artifacts/../server.key.ipa", "/artifacts/%2e%2e/server.key.ipa"]:
            self.assertEqual(self.get(path, "test-token")[0], 404)

    def test_catalog_requires_auth_and_hides_absolute_paths(self):
        for route in ['/projects', '/projects/' + self.project + '/schemes']:
            self.assertEqual(self.get(route)[0], 401)
            status, payload = self.get(route, 'test-token')
            self.assertEqual(status, 200)
            self.assertNotIn(str(self.root).encode(), payload)
        self.assertEqual(self.get('/projects/../../private/schemes', 'test-token')[0], 422)
        self.assertEqual(self.post({'id':str(uuid.uuid4()), 'projectID':'a'*64, 'scheme':'Example'})[0], 404)
        status, data = self.post({'id':str(uuid.uuid4()), 'projectID':self.project, 'scheme':'Example'})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)['selection']['projectID'], self.project)

    def test_refuses_non_tailnet_bind_addresses(self):
        for address in ["0.0.0.0", "127.0.0.1", "192.168.1.2", "8.8.8.8", "100.128.0.1"]:
            with self.assertRaises(ValueError): tailnet_address(address)
        self.assertEqual(str(tailnet_address("100.64.0.1")), "100.64.0.1")


if __name__ == "__main__": unittest.main()
