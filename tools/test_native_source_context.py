"""Original CBHentai APK parses synthetic pages through the current Java8 host.

No comic website or account is used. The optional original APK must match the
pinned SHA. This proof covers the real source parser, not iOS device behavior.
"""
from __future__ import annotations

import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit

from native_extension_engine.build import build_host

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=')


class OriginalSourceContextTests(unittest.TestCase):
    def test_original_cbhentai_context_and_token_pages_survive_cold_cache(self):
        apk = os.environ.get('TACHI_CBHENTAI_APK')
        dependencies = os.environ.get('TACHI_PROOF_DEPENDENCIES')
        if not apk or not dependencies:
            self.skipTest('Requires original CBHentai1.6.96 APK and reviewed Java dependencies')
        java, javac = os.environ['TACHI_PROOF_JAVA'], os.environ['TACHI_PROOF_JAVAC']
        with tempfile.TemporaryDirectory(prefix='tachi-source-context-') as temporary:
            root = Path(temporary)
            host = root / 'extension-host.jar'
            build_host(Path(dependencies), host, root, javac)
            proof = Path(__file__).parent / 'native_extension_engine/proof/OriginalCbhentaiContextProof.java'
            classes = root / 'classes'
            subprocess.run([javac, '--release', '8', '-encoding', 'UTF-8', '-cp', os.pathsep.join([str(host), dependencies]), '-d', str(classes), str(proof)], check=True, capture_output=True, timeout=45)
            requests, failures = [], []

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_GET(self):
                    url = urlsplit(self.path)
                    requests.append(url.path)
                    mime, cookie = 'application/json', False
                    base = 'http://127.0.0.1:' + str(self.server.server_port)
                    if url.path == '/read/fixture/oneshot/':
                        body = b'<html><body><div class="masr2-reader" data-masr2-token="fixture-first"></div></body></html>'
                        mime, cookie = 'text/html', True
                    elif url.path == '/wp-json/manga-reader/v2/pages':
                        if 'fixture_reader=ready' not in self.headers.get('Cookie', ''):
                            failures.append('Missing source client cookie')
                        if self.headers.get('Referer') != base + '/read/fixture/oneshot/':
                            failures.append('Missing chapter referer')
                        token = parse_qs(url.query).get('token', [''])[0]
                        if token == 'fixture-first':
                            body = dict(items=[base + '/image/1.png'], done=False, next_token='fixture-second')
                        elif token == 'fixture-second':
                            body = dict(items=[base + '/image/2.png'], done=True, next_token=None)
                        else:
                            failures.append('Unexpected token')
                            body = dict(items=[], done=True)
                    elif url.path.startswith('/image/'):
                        body, mime = PNG, 'image/png'
                    else:
                        failures.append('Unexpected fixture URL')
                        body = dict(error='unexpected-request')
                    if not isinstance(body, bytes):
                        body = json.dumps(body).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', mime)
                    self.send_header('Content-Length', str(len(body)))
                    if cookie:
                        self.send_header('Set-Cookie', 'fixture_reader=ready; Path=/; HttpOnly')
                    self.end_headers()
                    self.wfile.write(body)

            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                result = subprocess.run([java, '-Xint', '-cp', os.pathsep.join(map(str, [classes, host, dependencies])), 'dev.tachibooks.engine.OriginalCbhentaiContextProof', str(root / 'data'), str(Path(apk).resolve()), 'http://127.0.0.1:' + str(server.server_port)], capture_output=True, text=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr + '\nFixture paths: ' + repr(requests) + '\nFailures: ' + repr(failures))
                self.assertIn('ORIGINAL_CBHENTAI_CONTEXT_OK', result.stdout)
                self.assertFalse(failures, failures)
                self.assertEqual(requests.count('/wp-json/manga-reader/v2/pages'), 6)
                print(result.stdout, end='')
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)


if __name__ == '__main__':
    unittest.main()
