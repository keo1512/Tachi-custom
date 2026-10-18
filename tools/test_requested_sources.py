"""Opt-in original source APK parser/hook proof, isolated from real websites."""
from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from native_extension_engine.build import build_host, sha256
from native_extension_engine.proof.requested_source_fixtures import options


class RequestedSourcesTests(unittest.TestCase):
    def test_original_requested_sources_read_pages_and_images(self):
        directory = os.environ.get('TACHI_REQUESTED_APK_DIRECTORY')
        dependencies = os.environ.get('TACHI_PROOF_DEPENDENCIES')
        if not directory or not dependencies:
            self.skipTest('Requires reviewed original requested APKs and pinned host dependencies')
        java, javac = os.environ['TACHI_PROOF_JAVA'], os.environ['TACHI_PROOF_JAVAC']
        crypto = Path(os.environ['TACHI_PROOF_CRYPTO_PROVIDER'])
        specification = json.loads((Path(__file__).parent / 'native_extension_engine/upstream.json').read_text())['cryptoProvider']
        self.assertEqual(sha256(crypto), specification['sha256'])
        self.assertEqual(crypto.stat().st_size, specification['bytes'])
        with tempfile.TemporaryDirectory(prefix='tachi-requested-sources-') as temporary:
            root = Path(temporary)
            host, classes = root / 'extension-host.jar', root / 'classes'
            build_host(Path(dependencies), host, root, javac)
            proof = Path(__file__).parent / 'native_extension_engine/proof/RequestedSourcesReadProof.java'
            subprocess.run([javac, '--release', '8', '-encoding', 'UTF-8', '-cp', os.pathsep.join([str(host), dependencies]), '-d', str(classes), str(proof)], check=True, capture_output=True, timeout=45)
            fixtures = root / 'options.json'
            fixtures.write_text(json.dumps(options(Path(directory))), encoding='utf-8')
            report = Path(os.environ.get('TACHI_REQUESTED_SOURCE_REPORT', str(root / 'report.json')))
            result = subprocess.run([java, '-Xint', '-cp', os.pathsep.join(map(str, [classes, host, dependencies, crypto])), 'dev.tachibooks.engine.RequestedSourcesReadProof', str(root / 'data'), str(fixtures), str(report)], capture_output=True, text=True, timeout=180)
            print(result.stdout, end='')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            values = json.loads(report.read_text(encoding='utf-8'))
            self.assertEqual(len(values), 10)  # MinoTruyen's three sources.
            self.assertTrue(all(value.get('pages') == 2 and value.get('image') and value.get('coldCache') for value in values))


if __name__ == '__main__':
    unittest.main()
