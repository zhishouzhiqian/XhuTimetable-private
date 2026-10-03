import hashlib
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

import slim_campus_timetable_host as slim

APP = "Payload/TmallCampus.app/"


def macho(dependency=None):
    command = b""
    if dependency:
        name = dependency.encode() + b"\0"
        size = (24 + len(name) + 7) // 8 * 8
        command = struct.pack("<6I", 0xC, size, 24, 0, 0, 0) + name
        command += b"\0" * (size - len(command))
    return struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 2, bool(command), len(command), 0, 0) + command


def files(dependency="@rpath/Test.framework/Test"):
    library = macho() + b"xhu-campus-timetable-host:2\0"
    resources = {"yw_1222.jpg": b"main-security", "yw_1222_mwua.jpg": b"wua-security"}
    metadata = {"CFBundleIdentifier": "com.tmall.campus4iphone", "CFBundleExecutable": "TmallCampus",
                "CampusTimetableHost": {"version": 2, "paymentEnabled": True},
                "CampusOriginalProbe": {"librarySHA256": hashlib.sha256(library).hexdigest(),
                    "resources": {n: {"sha256": hashlib.sha256(v).hexdigest()} for n, v in resources.items()}}}
    entries = {"Info.plist": plistlib.dumps(metadata), "TmallCampus": macho(dependency),
               "CampusOriginalProbe.dylib": library, "Frameworks/Test.framework/Test": macho(),
               "Frameworks/Test.framework/Info.plist": b"framework-metadata",
               "Assets.car": b"app-icons", "compose-resources/shared/resource": b"shared-ui",
               "MtopCore.bundle/config": b"sdk-config", "unknown-resource": b"keep-unknown",
               "TCAINote.bundle/assets": b"unused-ai", "PlugIns/Original.appex/code": b"unused-extension",
               "AMap.bundle/map": b"unused-map", "tabbar/home.png": b"unused-navigation"}
    entries.update(resources)
    return {APP + n: data for n, data in entries.items()}


def write(path, entries):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in entries.items():
            z.writestr(name, data)


class SlimTests(unittest.TestCase):
    def test_protected_and_unknown_resources(self):
        for path in ["Assets.car", "compose-resources/a.pag", "Frameworks/AMap.bundle/map", "yw_1222.jpg",
                     "MtopCore.bundle/config", "ALBBAccountLogin.bundle/login", "unclassified.bundle/item"]:
            self.assertIsNone(slim.removal_reason(path))

    def test_only_explicit_resources_removed_and_bytes_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.ipa", Path(directory) / "slim.ipa"
            entries = files(); write(source, entries)
            before = source.read_bytes()
            result = slim.prepare(source, output)
            self.assertEqual(source.read_bytes(), before)
            self.assertTrue(result["retainedFilesVerified"])
            self.assertEqual(result["linkedImages"], 3)
            self.assertEqual(result["removedEntries"], 4)
            with zipfile.ZipFile(output) as z:
                for name in z.namelist():
                    self.assertEqual(z.read(name), entries[name])
                self.assertIn(APP + "unknown-resource", z.namelist())
                self.assertNotIn(APP + "PlugIns/Original.appex/code", z.namelist())

    def test_cannot_remove_a_real_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.ipa", Path(directory) / "slim.ipa"
            entries = files("@executable_path/TCAINote.bundle/code")
            entries[APP + "TCAINote.bundle/code"] = macho()
            write(source, entries)
            with self.assertRaisesRegex(ValueError, "真实加载依赖"):
                slim.prepare(source, output)
            self.assertFalse(output.exists())

    def test_existing_output_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.ipa", Path(directory) / "slim.ipa"
            write(source, files()); output.write_bytes(b"existing")
            with self.assertRaises(ValueError): slim.prepare(source, output)
            self.assertEqual(output.read_bytes(), b"existing")

    def test_library_integrity_required(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.ipa", Path(directory) / "slim.ipa"
            entries = files(); entries[APP + "CampusOriginalProbe.dylib"] += b"changed"
            write(source, entries)
            with self.assertRaisesRegex(ValueError, "整合库"):
                slim.prepare(source, output)
            self.assertFalse(output.exists())

    def test_missing_dependency_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.ipa", Path(directory) / "slim.ipa"
            entries = files(); del entries[APP + "Frameworks/Test.framework/Test"]
            write(source, entries)
            with self.assertRaisesRegex(ValueError, "真实加载依赖"):
                slim.prepare(source, output)

    def test_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.ipa", Path(directory) / "slim.ipa"
            entries = files(); entries[APP + "../outside"] = b"outside"
            write(source, entries)
            with self.assertRaisesRegex(ValueError, "路径"):
                slim.prepare(source, output)


if __name__ == "__main__":
    unittest.main()
