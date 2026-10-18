"""Opt-in execution of the unchanged Komga APK shipped inside the reference IPA.

The original extension parses a local HTTP fixture through the current Java8
host. No website, account, or user library is used; the image is a 1px fixture.
TACHI_ORIGINAL_KOMGA_APK and the three TACHI_PROOF_* inputs are required.
TACHI_CURRENT_KOMGA_APK optionally checks the observed API1.6 package against
the same local service, without replacing the original-IPA legacy proof.
"""
from __future__ import annotations

import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import urlsplit

from native_extension_engine.build import build_host

APK_SHA256 = "6f38dd36eebe00beb1b5bc074435855c13e3e214961e109eae7726540b2bb11d"
CURRENT_APK_SHA256 = "8e2c4a4e7bbcb62ed611cf0a70119f780b361879c27f1e2f4d0a61b6308b67ed"
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")


def fixture_objects():
    date = "2026-10-17T00:00:00"
    common = dict(created=date, lastModified=date, fileLastModified=date)
    authors = [dict(name="Fixture Author", role="writer")]
    series_metadata = dict(
        created=date, lastModified=date, title="Fixture Story", titleSort="Fixture Story",
        status="ONGOING", summary="Controlled fixture", language="vi", publisher="Fixture",
        readingDirection="LEFT_TO_RIGHT", ageRating=0, totalBookCount=1,
        genres=["Fixture"], tags=[],
    )
    for name in ("ageRating", "genres", "language", "publisher", "readingDirection", "summary", "tags", "title", "titleSort", "status", "totalBookCount"):
        series_metadata[name + "Lock"] = False
    series = dict(common, id="series-fixture", name="Fixture Story", libraryId="fixture-library",
                  booksCount=1, metadata=series_metadata,
                  booksMetadata=dict(created=date, lastModified=date, authors=authors,
                                     releaseDate="2026-10-17", summary="Controlled fixture",
                                     summaryNumber="1", tags=[]))
    book_metadata = dict(title="Chapter One", number="1", numberSort=1.0,
                         summary="Fixture chapter", releaseDate="2026-10-17", authors=authors, tags=[])
    for name in ("title", "number", "numberSort", "summary", "releaseDate", "authors", "tags"):
        book_metadata[name + "Lock"] = False
    book = dict(common, id="book-fixture", name="Chapter One", number=1.0,
                seriesId=series["id"], seriesTitle=series["name"], size="68 B", sizeBytes=68,
                metadata=book_metadata, media=dict(mediaType="application/zip", pagesCount=1, status="READY",
                                                  mediaProfile="DIVINA", epubDivinaCompatible=False))
    return series, book


def page(items):
    return dict(content=items, empty=not items, first=True, last=True, number=0,
                numberOfElements=len(items), size=20, totalElements=len(items), totalPages=1)


class OriginalExtensionDataTest(unittest.TestCase):
    def test_original_apk_reads_catalogue_detail_chapters_pages_and_real_image_bytes(self):
        self.run_fixture("TACHI_ORIGINAL_KOMGA_APK", APK_SHA256, "original-ipa-api1.4")

    def test_current_api16_apk_reads_catalogue_detail_chapters_pages_and_real_image_bytes(self):
        self.run_fixture("TACHI_CURRENT_KOMGA_APK", CURRENT_APK_SHA256, "observed-api1.6")

    def run_fixture(self, apk_variable, expected_hash, case):
        apk = os.environ.get(apk_variable)
        dependencies = os.environ.get("TACHI_PROOF_DEPENDENCIES")
        if not apk or not dependencies:
            self.skipTest("Requires verified " + apk_variable + " and host dependency inputs")
        self.assertEqual(hashlib.sha256(Path(apk).read_bytes()).hexdigest(), expected_hash)
        java, javac = os.environ["TACHI_PROOF_JAVA"], os.environ["TACHI_PROOF_JAVAC"]
        with tempfile.TemporaryDirectory(prefix="tachi-original-data-") as temporary:
            root = Path(temporary)
            host = root / "extension-host.jar"
            build_host(Path(dependencies), host, root, javac)
            proof = Path(__file__).parent / "native_extension_engine/proof/OriginalApkReadProof.java"
            classes = root / "classes"
            subprocess.run([javac, "--release", "8", "-encoding", "UTF-8", "-cp",
                            os.pathsep.join([str(host), dependencies]), "-d", str(classes), str(proof)],
                           capture_output=True, check=True, timeout=45)
            series, book = fixture_objects()
            requests = []

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_GET(self):
                    path = urlsplit(self.path).path
                    requests.append(path)
                    content_type = "application/json"
                    if path.endswith("/pages/1") or path.endswith("/thumbnail"):
                        body, content_type = PNG, "image/png"
                    elif path.endswith("/pages"):
                        body = [dict(number=1, fileName="001.png", mediaType="image/png")]
                    elif path.endswith("/books"):
                        body = page([book])
                    elif path.endswith("/series/series-fixture"):
                        body = series
                    elif path.startswith("/api/v1/series"):
                        body = page([series])
                    else:
                        body = []
                    if not isinstance(body, bytes):
                        body = json.dumps(body).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", content_type)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                options = root / "options.json"
                options.write_text(json.dumps(dict(sourceId="4508733312114627536", query="Fixture",
                                                   preferences={"Address": "http://127.0.0.1:" + str(server.server_port)}, maximumImages=1)), encoding="utf-8")
                report_file = root / "proof.json"
                result = subprocess.run([java, "-Xint", "-cp", os.pathsep.join(map(str, [classes, host, dependencies])),
                                         "dev.tachibooks.engine.OriginalApkReadProof", str(root / "data"),
                                         str(Path(apk).resolve()), str(options), str(report_file)],
                                        timeout=60, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                report = json.loads(report_file.read_bytes())
                self.assertGreater(report["searchCount"], 0)
                self.assertEqual(report["chapters"], 1)
                self.assertEqual(report["pages"], 1)
                self.assertEqual(report["downloadedImages"][0]["sha256"], hashlib.sha256(PNG).hexdigest())
                self.assertTrue(any(path.endswith("/pages/1") for path in requests))
                report["case"] = case
                report["fixtureRequestPaths"] = requests
                print("ORIGINAL_EXTENSION_DATA_FIXTURE_OK " + json.dumps(report, sort_keys=True))
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
