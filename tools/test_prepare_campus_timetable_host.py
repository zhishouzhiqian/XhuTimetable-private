"""检查整合包完整性、路径边界、原 IPA 保留及输出保护。"""
import hashlib
import json
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
import prepare_campus_timetable_host as host
from test_prepare_campus_original_probe import fixture

class TimetableHostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / "build"
        resource = self.build / "resources/compose-resources/course/files/test.json"
        resource.parent.mkdir(parents=True)
        resource.write_bytes(b'{"test":true}')
        (self.build / host.LIBRARY).write_bytes(fixture(6) + host.MARKER)
        self.artifact = self.root / "host.zip"
        host.create_artifact(self.build, self.artifact)

    def test_artifact_round_trip(self):
        files = host.read_artifact(self.artifact)
        self.assertEqual(files[host.LIBRARY], fixture(6) + host.MARKER)
        self.assertEqual(files["resources/compose-resources/course/files/test.json"], b'{"test":true}')
        with self.assertRaises(ValueError):
            host.create_artifact(self.build, self.artifact)

    def test_reject_traversal_absolute_and_non_resource_names(self):
        for name in ("resources/../Info.plist", "resources/compose-resources/../Info.plist",
                     "/resources/compose-resources/x", "resources/compose-resources//x",
                     "resources/compose-resources/./x", "resources\\compose-resources\\x", "Info.plist"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                host.resource_name(name)

    def test_reject_corrupt_checksum_and_extra_entries(self):
        with zipfile.ZipFile(self.artifact) as source:
            files = {name: source.read(name) for name in source.namelist()}
        files[host.LIBRARY] = b"corrupt"
        bad = self.root / "bad.zip"
        with zipfile.ZipFile(bad, "w") as target:
            for name, data in files.items(): target.writestr(name, data)
        with self.assertRaises(ValueError): host.read_artifact(bad)
        files["unexpected"] = b"x"
        with zipfile.ZipFile(bad, "w") as target:
            for name, data in files.items(): target.writestr(name, data)
        with self.assertRaises(ValueError): host.read_artifact(bad)

    def test_prepare_preserves_sdk_identity_and_both_inputs(self):
        source, output = self.root / "source.ipa", self.root / "result.ipa"
        app = "Payload/Campus.app/"
        metadata = {"CFBundleExecutable": "Campus", "CFBundleIdentifier": "com.tmall.campus4iphone", "CFBundleShortVersionString": "5.7.2"}
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr(app + "Info.plist", plistlib.dumps(metadata))
            archive.writestr(app + "Campus", fixture())
            archive.writestr(app + "yw_1222.jpg", b"main")
            archive.writestr(app + "yw_1222_mwua.jpg", b"mwua")
        before = source.read_bytes(), self.artifact.read_bytes()
        with patch.object(host.original, "SOURCE_SHA256", hashlib.sha256(fixture()).hexdigest()):
            host.prepare(source, self.artifact, output)
        self.assertEqual(before, (source.read_bytes(), self.artifact.read_bytes()))
        with zipfile.ZipFile(output) as archive:
            updated = plistlib.loads(archive.read(app + "Info.plist"))
            self.assertEqual(updated["CFBundleIdentifier"], metadata["CFBundleIdentifier"])
            self.assertEqual(updated["CFBundleDisplayName"], "西瓜课表（校园整合测试）")
            self.assertFalse(updated["CampusTimetableHost"]["paymentEnabled"])
            self.assertIn("NSCameraUsageDescription", updated)
            self.assertEqual(archive.read(app + "yw_1222.jpg"), b"main")
            self.assertEqual(archive.read(app + "compose-resources/course/files/test.json"), b'{"test":true}')
            self.assertIsNone(archive.testzip())
        with self.assertRaises(ValueError): host.prepare(source, self.artifact, output)

    def test_reject_old_diagnostic_library(self):
        (self.build / host.LIBRARY).write_bytes(fixture(6))
        with self.assertRaisesRegex(ValueError, "旧诊断库"):
            host.create_artifact(self.build, self.root / "old.zip")

    def test_existing_output_never_removed(self):
        output = self.root / "existing.ipa"
        output.write_bytes(b"keep")
        with self.assertRaises(ValueError): host.prepare(self.root / "absent.ipa", self.artifact, output)
        self.assertEqual(output.read_bytes(), b"keep")

if __name__ == "__main__":
    unittest.main()
