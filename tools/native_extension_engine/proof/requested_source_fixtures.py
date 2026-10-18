"""Synthetic parser fixtures for pinned, unmodified requested source APKs.

No comic content, accounts, website requests, or automatically posted comments.
The encrypted/packed strings below encode only the same two fixture image URLs.
"""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import struct
import zlib

PINS = {
    'CuuTruyen': ('1.6.1', '7645eba9e97f2e38e5c375a2f749f1fd90c045d80e3a4ad3b28ab38aa2855dee'),
    'LXManga': ('1.6.42', 'e7c565409a956d124bca7e79c6de6a2ab314e68feb94557c8be9f3598256f6f3'),
    'MiMi': ('1.6.7', '7747c02c1b84a0c69f0b05b4e85097803524c9dadc507137670b66c386cd4220'),
    'MiMiHentai': ('1.6.7', '8d210dda9899aa5d18e3b830c9d95b283f2fe88bc151c2347baf22d8e56ddbf5'),
    'MinoTruyen': ('1.6.5', 'f20d6962bb31c31c6a1b3fd6d0537faa499866900234204de2e119e8f97c6ed0'),
    'MoeTruyen': ('1.6.19', '62a0791273cc12ab1c4aad154da398cff6047a320a01b72e120bdd07ea395acf'),
    'ViHentai': ('1.6.5', 'b54a42cb2c48d8bbeaf67b87df96acd7a8c0c8c9e593ec08cceb452289fcc0de'),
    'VinaHentai': ('1.6.19', '78b13ef3ef87df88fa7b6960aea7a177e17d469fa8a7075278f853c3a3c018bf'),
}
URLS = [f'https://fixture.invalid/manga-images/{"fixture-" * 12}{i}.png' for i in (1, 2)]


def striped_png() -> bytes:
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    pixels = b''.join(b'\0' + (b'\xff\x00\x00' if y < 16 else b'\x00\x00\xff') * 16 for y in range(32))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', 16, 32, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


def xor64(plain: str, key='3141592653589793') -> str:
    raw, secret = plain.encode(), key.encode()
    return base64.b64encode(bytes(b ^ secret[i % len(secret)] for i, b in enumerate(raw))).decode()


def lx_script() -> str:
    key3, key2 = '0123456789abcdef', 'abcdef0123456789'
    encoded = json.dumps([xor64(url, key3) for url in URLS], separators=(',', ':'))
    layer3 = f'var _key3 = "{key3}"; var _data3 = "{base64.b64encode(encoded.encode()).decode()}";'
    payload = bytes(b ^ ord(key2[i % len(key2)]) for i, b in enumerate(layer3.encode()))
    half = len(payload) // 2
    layer2 = f'var _key = "{key2}"; var _a = {list(payload[:half])}; var _b = {list(payload[half:])}; var _joined = _a.concat(_b);'
    return f'<script>var _blob = ["{base64.b64encode(layer2.encode()).decode()}"]; var _data = _blob.join(""); /* KGZ */</script>'


def vi_script() -> str:
    script = "KuroReader('#chapter-content', " + json.dumps(URLS) + ',0)'
    encoded = ''.join(format(ord(char), 'b') + 'a' for char in script)
    return '<script>eval(function(h,u,n,t,e,r){}("' + encoded + '",0,"01a",0,2,0))</script>'


def mino_script() -> str:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    raw = json.dumps([{'content': [{'imageUrl': URLS[0], 'drm_data': xor64('#mino-v1|16-16|0-16')}, {'imageUrl': URLS[1]}]}], separators=(',', ':')).encode()
    salt, password, derived, previous = b'fixture1', b'GCERKSmf28E6nWwrnR8Lz4f7TacKpzMy7aK0rxSB', b'', b''
    while len(derived) < 48:
        previous = hashlib.md5(previous + password + salt).digest()
        derived += previous
    padding = 16 - len(raw) % 16
    encryptor = Cipher(algorithms.AES(derived[:32]), modes.CBC(derived[32:48])).encryptor()
    encrypted = encryptor.update(raw + bytes([padding]) * padding) + encryptor.finalize()
    return '<script>var fixture="' + '0' * 32 + ':' + base64.b64encode(b'Salted__' + salt + encrypted).decode() + '";</script>'


def options(apk_directory: Path) -> list[dict]:
    cover = URLS[0]
    title = '<div class="flex flex-row truncate mb-4"><span class="grow text-lg ml-1 text-ellipsis font-semibold">Fixture</span></div><h1>Fixture</h1><h1 class="manga-detail-title">Fixture</h1><div class="title"><p>Fixture</p></div>'
    chapters = '<ul class="overflow-y-auto"><li><a href="/truyen/fixture/one"><span class="truncate text-ellipsis">Fixture one</span><span class="timeago">1 day</span></a></li></ul>'
    common = title + chapters
    fixtures = {
        'CuuTruyen': {
            'searchBody': {'data': [{'id': 123, 'name': 'Fixture', 'cover_url': cover}], '_metadata': {'current_page': 1, 'total_pages': 1}},
            'detailBody': {'data': {'id': 123, 'name': 'Fixture', 'cover_url': cover, 'tags': []}},
            'chaptersBody': {'data': [{'id': 456, 'number': '1', 'name': 'Fixture'}]},
            'chapterBody': {'data': {'pages': [{'order': 1, 'image_url': URLS[0], 'drm_data': xor64('#v4|16-16|0-16')}, {'order': 2, 'image_url': URLS[1]}]}},
        },
        'MiMi': {
            'searchBody': {'items': [{'id': 123, 'title': 'Fixture', 'cover_url': cover}]},
            'mangaBody': {'id': 123, 'title': 'Fixture', 'cover_url': cover},
            'tocBody': [{'id': 456, 'title': 'Fixture', 'order': 1}],
            'chapterBody': {'pages': [{'image_url': url} for url in URLS]},
        },
        'MinoTruyen': {
            'searchBody': {'meta': {'pageCount': 1}, 'data': {'books': [{'bookId': 123, 'info': {'title': 'Fixture'}, 'cover': {'imageUrl': cover}}]}},
            'detailBody': {'data': {'book': {'bookId': 123, 'info': {'title': 'Fixture'}, 'cover': {'imageUrl': cover}}}},
            'chaptersBody': {'data': {'chapters': [{'chapterId': 456, 'chapterNumber': '1', 'title': 'Fixture'}]}},
            'chapterBody': mino_script(),
        },
        'LXManga': {
            'searchBody': f'<div class="manga-vertical"><a class="text-ellipsis" href="/truyen/fixture">Fixture</a><div class="cover" data-bg="{cover}"></div></div>',
            'detailBody': common, 'chaptersBody': common, 'chapterBody': lx_script(),
        },
        'ViHentai': {
            'searchBody': f'<div class="manga-vertical"><div class="p-2"><a href="/truyen/fixture">Fixture</a></div><div class="cover" style="background-image: url({cover})"></div></div>',
            'detailBody': common, 'chaptersBody': common, 'chapterBody': vi_script(),
        },
        'MiMiHentai': {
            'searchBody': f'<a class="group" href="/truyen/fixture"><h1>Fixture</h1><img src="{cover}"></a>',
            'detailBody': common + '<div class="chapter-list"><a href="/truyen/fixture/one"><h1>Fixture one</h1></a></div>',
            'chapterBody': ''.join(f'<img class="lazy" data-src="{url}">' for url in URLS),
        },
        'VinaHentai': {
            'searchBody': f'<div class="grid"><a href="/truyen-hentai/fixture"><div class="truncate font-semibold" title="Fixture">Fixture</div><img src="{cover}"></a></div>',
            'detailBody': common + '<a class="block" href="/truyen-hentai/fixture/one"><span>Fixture one</span></a>',
            'chapterBody': ''.join(f'<img src="{url}">' for url in URLS),
        },
        'MoeTruyen': {
            'searchBody': f'<article class="manga-card--list"><a href="/manga/fixture"><h3>Fixture</h3><img src="{cover}"></a></article>',
            'detailBody': common + '<ul class="chapter-list"><li class="chapter"><a class="chapter-link" href="/chapters/fixture-one"><span class="chapter-num">Fixture one</span></a></li></ul>',
            'chapterBody': ''.join(f'<img class="page-media" src="{url}">' for url in URLS),
        },
    }
    result = []
    for name, (version, sha) in PINS.items():
        body = fixtures[name]
        if 'chaptersBody' not in body:
            body['chaptersBody'] = body.get('detailBody', '')
        if 'detailBody' not in body:
            body['detailBody'] = body.get('mangaBody', '')
        result.append({'name': name, 'version': version, 'sha256': sha, 'apk': str((apk_directory / (sha + '.apk')).resolve()), 'image': base64.b64encode(striped_png()).decode(), **{key: value if isinstance(value, str) else json.dumps(value) for key, value in body.items()}})
    return result
