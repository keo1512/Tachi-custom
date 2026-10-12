"""Regression for pinned Shadow JAR aliases on older Codemagic Python."""
import io
import struct
import unittest
import warnings
import zipfile

from native_extension_engine.build import upstream_members


def archive_with_alias(*, conflicting_crc=False, conflicting_name=False):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("LICENSE.Apachev2", b"original upstream notice")
        archive.writestr("kotlin/Marker.class", b"class bytes")
    raw = stream.getvalue()
    end = raw.rfind(b"PK\x05\x06")
    count, size, start = struct.unpack_from("<HII", raw, end + 10)
    directory = raw[start:end]
    name_size, extra_size, comment_size = struct.unpack_from("<HHH", directory, 28)
    alias = bytearray(directory[:46 + name_size + extra_size + comment_size])
    if conflicting_crc:
        struct.pack_into("<I", alias, 16, 1)
    if conflicting_name:
        alias[46] = ord("X")
    footer = bytearray(raw[end:])
    struct.pack_into("<HHI", footer, 8, count + 1, count + 1, size + len(alias))
    return io.BytesIO(raw[:start] + directory + alias + footer)


class StrictOlderZipFile(zipfile.ZipFile):
    """Model Python 3.12.7's refusal of duplicate zero-length boundaries."""
    def read(self, name, pwd=None):
        if isinstance(name, zipfile.ZipInfo) and name._end_offset == name.header_offset:
            raise zipfile.BadZipFile("Overlapped entries (Python 3.12.7)")
        return super().read(name, pwd)


class UpstreamArchiveMembersTests(unittest.TestCase):
    def test_exact_physical_alias_reads_on_strict_older_python_without_mutation(self):
        with StrictOlderZipFile(archive_with_alias()) as archive:
            originals = [(info.header_offset, info._end_offset) for info in archive.infolist()]
            with self.assertRaises(zipfile.BadZipFile):
                archive.read(archive.infolist()[0])
            with warnings.catch_warnings():
                warnings.simplefilter("error")
                members = upstream_members(archive)
            self.assertEqual(members["LICENSE.Apachev2"], b"original upstream notice")
            self.assertEqual(members["kotlin/Marker.class"], b"class bytes")
            self.assertEqual(len(members), 2)
            self.assertEqual(originals, [(i.header_offset, i._end_offset) for i in archive.infolist()])

    def test_alias_with_conflicting_crc_is_rejected(self):
        with StrictOlderZipFile(archive_with_alias(conflicting_crc=True)) as archive:
            with self.assertRaisesRegex(zipfile.BadZipFile, "Conflicting"):
                upstream_members(archive)

    def test_alias_with_conflicting_name_is_rejected(self):
        with StrictOlderZipFile(archive_with_alias(conflicting_name=True)) as archive:
            with self.assertRaisesRegex(zipfile.BadZipFile, "Conflicting"):
                upstream_members(archive)

    def test_genuine_physical_overlap_is_still_rejected(self):
        with StrictOlderZipFile(archive_with_alias()) as archive:
            for info in archive.infolist():
                if info.filename == "LICENSE.Apachev2":
                    info.compress_size += 500
            with self.assertRaisesRegex(zipfile.BadZipFile, "Overlapped"):
                upstream_members(archive)

    def test_crc_corruption_is_still_rejected(self):
        stream = archive_with_alias()
        raw = bytearray(stream.getvalue())
        raw[30 + len("LICENSE.Apachev2")] ^= 1
        with StrictOlderZipFile(io.BytesIO(raw)) as archive:
            with self.assertRaisesRegex(zipfile.BadZipFile, "CRC"):
                upstream_members(archive)

    def test_distinct_duplicate_notices_and_last_class_selection_are_preserved(self):
        stream = io.BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(stream, "w") as archive:
                archive.writestr("LICENSE", b"notice one")
                archive.writestr("LICENSE", b"notice two")
                archive.writestr("org/objectweb/asm/Marker.class", b"original")
                archive.writestr("org/objectweb/asm/Marker.class", b"transformed")
        with StrictOlderZipFile(stream) as archive:
            members = upstream_members(archive)
        self.assertEqual(members["LICENSE"], b"notice one")
        self.assertEqual(members["META-INF/licenses/shadow-1-LICENSE"], b"notice two")
        self.assertEqual(members["org/objectweb/asm/Marker.class"], b"transformed")


if __name__ == "__main__":
    unittest.main()
