"""Opt-in rules checks against a loopback-only, demo Firestore emulator.

Start the Firestore emulator using firestore.tachibooks.rules and project
demo-tachibooks-rules, then set FIRESTORE_EMULATOR_HOST=127.0.0.1:<port>.
This test resets only that demo database. It never uses Firebase credentials or
connects to a production endpoint; all identities and documents are synthetic.
"""

import base64
import json
import os
import re
import time
import unittest
import urllib.error
import urllib.request

PROJECT = "demo-tachibooks-rules"
HOST = os.environ.get("FIRESTORE_EMULATOR_HOST", "")
if HOST and (
    not re.fullmatch(r"127\.0\.0\.1:[1-9][0-9]{0,4}", HOST)
    or int(HOST.rsplit(":", 1)[1]) > 65535
):
    raise SystemExit("Set FIRESTORE_EMULATOR_HOST to a loopback demo emulator before running rules checks.")
BASE = f"http://{HOST}"
DATABASE = f"projects/{PROJECT}/databases/(default)"
DOCS = f"{DATABASE}/documents"
ROOT = "tachiBooksUsers/alice"
SCHEMA = "tachi-books-cloud-1"


def value(source):
    if isinstance(source, str):
        return {"stringValue": source}
    if isinstance(source, int):
        return {"integerValue": str(source)}
    if isinstance(source, float):
        return {"doubleValue": source}
    if isinstance(source, list):
        return {"arrayValue": {"values": [value(item) for item in source]}}
    if isinstance(source, dict):
        return {"mapValue": {"fields": {key: value(item) for key, item in source.items()}}}
    raise TypeError("unsupported synthetic fixture")


def token(uid):
    def encoded(source):
        return base64.urlsafe_b64encode(json.dumps(source).encode()).decode().rstrip("=")
    issued = int(time.time())
    payload = {
        "sub": uid, "user_id": uid, "aud": PROJECT,
        "iss": f"https://securetoken.google.com/{PROJECT}",
        "iat": issued, "exp": issued + 3600,
        "firebase": {"sign_in_provider": "google.com", "identities": {}},
    }
    # Unsecured mock JWTs are accepted only by the local emulator.
    return f"{encoded({'alg': 'none', 'typ': 'JWT'})}.{encoded(payload)}."


def request(method, path, payload=None, uid="alice"):
    headers = {"Content-Type": "application/json"}
    if uid is not None:
        headers["Authorization"] = f"Bearer {token(uid)}"
    source = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(BASE + path, data=source, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            data = response.read()
            return response.status, json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        data = error.read()
        return error.code, json.loads(data) if data else {}


def update(path, fields, timestamp=None):
    result = {
        "update": {"name": f"{DOCS}/{path}", "fields": {key: value(item) for key, item in fields.items()}},
    }
    if timestamp:
        result["updateTransforms"] = [{"fieldPath": timestamp, "setToServerValue": "REQUEST_TIME"}]
    return result


def head(identifier="a" * 32, *, parts=1, size=100):
    return {"id": identifier, "digest": "b" * 64, "parts": parts, "bytes": size}


@unittest.skipUnless(HOST, "Opt-in local Firestore emulator checks")
class FirestoreRulesTest(unittest.TestCase):
    def setUp(self):
        status, _ = request("DELETE", f"/emulator/v1/{DOCS}", uid=None)
        self.assertEqual(status, 200, "Demo emulator reset failed")

    def commit(self, writes, uid="alice"):
        return request("POST", f"/v1/{DOCS}:commit", {"writes": writes}, uid=uid)

    def manifest(self, item):
        return update(f"{ROOT}/snapshots/{item['id']}", {**item, "schema": SCHEMA}, "createdAt")

    def publish_head(self, current, retained=None):
        return update(f"{ROOT}/sync/head", {
            **current, "schema": SCHEMA, "retained": retained or [current],
        }, "updatedAt")

    def seed(self, item=None):
        item = item or head()
        part = update(f"{ROOT}/snapshots/{item['id']}/parts/0", {"data": "eA=="})
        status, _ = self.commit([self.manifest(item), part])
        self.assertEqual(status, 200, "Owner's first manifest+part batch was denied")
        status, _ = self.commit([self.publish_head(item)])
        self.assertEqual(status, 200, "Valid matching head was denied")
        return item

    def test_owner_staging_and_head_accept_server_timestamps(self):
        self.seed()
        status, _ = request("GET", f"/v1/{DOCS}/{ROOT}/sync/head")
        self.assertEqual(status, 200)

    def test_anonymous_and_other_account_cannot_read_or_write_owner_data(self):
        self.seed()
        for uid in [None, "bob"]:
            status, _ = request("GET", f"/v1/{DOCS}/{ROOT}/sync/head", uid=uid)
            self.assertEqual(status, 403)
            status, _ = self.commit([self.manifest(head("c" * 32))], uid=uid)
            self.assertEqual(status, 403)

    def test_owner_cannot_rewrite_immutable_parts_or_manifests(self):
        item = self.seed()
        for write in [
            self.manifest(item),
            update(f"{ROOT}/snapshots/{item['id']}/parts/0", {"data": "changed"}),
        ]:
            status, _ = self.commit([write])
            self.assertEqual(status, 403)

    def test_part_without_staged_manifest_is_denied(self):
        status, _ = self.commit([
            update(f"{ROOT}/snapshots/{'a' * 32}/parts/0", {"data": "eA=="}),
        ])
        self.assertEqual(status, 403)

    def test_full_128_mib_manifest_and_part_255_are_accepted(self):
        item = head(parts=256, size=128 * 1024 * 1024)
        status, _ = self.commit([
            self.manifest(item),
            update(f"{ROOT}/snapshots/{item['id']}/parts/255", {"data": "eA=="}),
        ])
        self.assertEqual(status, 200)
        status, _ = self.commit([self.publish_head(item)])
        self.assertEqual(status, 200)
        status, _ = self.commit([
            update(f"{ROOT}/snapshots/{item['id']}/parts/256", {"data": "eA=="}),
        ])
        self.assertEqual(status, 403)

    def test_oversize_manifest_is_denied(self):
        for item in [head(parts=257), head(size=128 * 1024 * 1024 + 1)]:
            status, _ = self.commit([self.manifest(item)])
            self.assertEqual(status, 403)

    def test_actual_eight_part_upload_batch_stays_under_document_and_rule_limits(self):
        item = head(parts=8, size=4200000)
        writes = [self.manifest(item)] + [
            update(f"{ROOT}/snapshots/{item['id']}/parts/{index}", {"data": "A" * 700000})
            for index in range(8)
        ]
        status, _ = self.commit(writes)
        self.assertEqual(status, 200, "The app's bounded first upload batch was denied")
        status, _ = self.commit([self.publish_head(item)])
        self.assertEqual(status, 200)
        next_item = head("c" * 32)
        status, _ = self.commit([
            self.manifest(next_item),
            update(f"{ROOT}/snapshots/{next_item['id']}/parts/0", {"data": "A" * 700001}),
        ])
        self.assertEqual(status, 403)

    def test_head_cannot_reference_missing_or_mismatched_manifest(self):
        status, _ = self.commit([self.publish_head(head())])
        self.assertEqual(status, 403)
        self.seed()
        wrong = {**head(), "digest": "c" * 64}
        status, _ = self.commit([self.publish_head(wrong)])
        self.assertEqual(status, 403)

    def test_retained_snapshots_cannot_be_deleted_but_dropped_ones_can(self):
        old = self.seed()
        deletion = {"delete": f"{DOCS}/{ROOT}/snapshots/{old['id']}/parts/0"}
        status, _ = self.commit([deletion])
        self.assertEqual(status, 403)
        status, _ = self.commit([{"delete": f"{DOCS}/{ROOT}/sync/head"}])
        self.assertEqual(status, 403)
        new = head("c" * 32)
        status, _ = self.commit([self.manifest(new)])
        self.assertEqual(status, 200)
        status, _ = self.commit([self.publish_head(new, [new, old])])
        self.assertEqual(status, 200)
        status, _ = self.commit([deletion])
        self.assertEqual(status, 403)
        status, _ = self.commit([self.publish_head(new)])
        self.assertEqual(status, 200)
        status, _ = self.commit([deletion])
        self.assertEqual(status, 200)

    def test_incremental_manifest_retains_legacy_snapshot_and_format_is_bound(self):
        old = self.seed()
        new = {**head('d' * 32), 'format': 2}
        status, _ = self.commit([
            update(f"{ROOT}/snapshots/{new['id']}", {**new, 'schema': 'tachi-books-cloud-2'}, 'createdAt'),
            update(f"{ROOT}/snapshots/{new['id']}/parts/0", {'data': 'eA=='}),
        ])
        self.assertEqual(status, 200)
        fields = {**new, 'schema': 'tachi-books-cloud-2', 'retained': [new, old]}
        status, _ = self.commit([update(f'{ROOT}/sync/head', fields, 'updatedAt')])
        self.assertEqual(status, 200)
        fields['retained'] = [{**new, 'format': 1}, old]
        status, _ = self.commit([update(f'{ROOT}/sync/head', fields, 'updatedAt')])
        self.assertEqual(status, 403)

    def test_immutable_blobs_are_owner_only_and_cannot_be_overwritten_or_deleted(self):
        path = f"{ROOT}/blobs/{'a' * 64}"
        status, _ = self.commit([update(path, {'bytes': 1, 'data': 'eA=='})])
        self.assertEqual(status, 200)
        status, _ = request('GET', f'/v1/{DOCS}/{path}')
        self.assertEqual(status, 200)
        for uid in [None, 'bob']:
            status, _ = request('GET', f'/v1/{DOCS}/{path}', uid=uid)
            self.assertEqual(status, 403)
        for write in [update(path, {'bytes': 1, 'data': 'eQ=='}), {'delete': f'{DOCS}/{path}'}]:
            status, _ = self.commit([write])
            self.assertEqual(status, 403)

    def test_format_requires_an_integer_for_manifests_and_current_or_retained_heads(self):
        for index, number in enumerate([1.0, 2.0]):
            item = {**head(('e', 'f')[index] * 32), 'format': number}
            schema = SCHEMA if number == 1.0 else 'tachi-books-cloud-2'
            status, _ = self.commit([
                update(f"{ROOT}/snapshots/{item['id']}", {**item, 'schema': schema}, 'createdAt'),
            ])
            self.assertEqual(status, 403)
        current = self.seed()
        for fields in [
            {**current, 'format': 1.0, 'schema': SCHEMA, 'retained': [current]},
            {**current, 'schema': SCHEMA, 'retained': [{**current, 'format': 1.0}]},
        ]:
            status, _ = self.commit([update(f'{ROOT}/sync/head', fields, 'updatedAt')])
            self.assertEqual(status, 403)
    def test_blob_limits_and_paths_are_denied(self):
        for digest, fields in [
            ('bad-hash', {'bytes': 1, 'data': 'eA=='}),
            ('b' * 64, {'bytes': 393217, 'data': 'eA=='}),
            ('c' * 64, {'bytes': 1, 'data': 'A' * 524289}),
            ('d' * 64, {'bytes': 1, 'data': 'eA==', 'extra': 1}),
        ]:
            status, _ = self.commit([update(f'{ROOT}/blobs/{digest}', fields)])
            self.assertEqual(status, 403)


if __name__ == "__main__":
    unittest.main()
