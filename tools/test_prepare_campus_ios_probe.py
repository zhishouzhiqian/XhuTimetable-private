import base64
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import prepare_campus_ios_probe as probe


class ComponentPreparationTest(unittest.TestCase):
    def test_only_two_resources_are_exported(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "mock.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                for name in probe.RESOURCE_NAMES:
                    archive.writestr("Payload/Mock.app/" + name, b"mock-resource")
                archive.writestr("Payload/Mock.app/session.json", b"private-session")
                archive.writestr("Payload/Mock.app/Mock", b"encrypted-main-not-needed")
            document = probe.resource_document(ipa)
            self.assertEqual(set(probe.RESOURCE_NAMES), set(document["resources"]))
            self.assertEqual(b"mock-resource", base64.b64decode(document["resources"][probe.RESOURCE_NAMES[0]]))
            self.assertNotIn("private-session", str(document))

    def test_missing_duplicate_or_oversized_resources_are_rejected(self):
        for mode in ("missing", "duplicate", "oversized"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                ipa = Path(directory) / "mock.ipa"
                with zipfile.ZipFile(ipa, "w") as archive:
                    archive.writestr("Payload/Mock.app/yw_1222.jpg", b"mock")
                    if mode != "missing":
                        archive.writestr("Payload/Mock.app/yw_1222_mwua.jpg", b"x" * (65537 if mode == "oversized" else 1))
                    if mode == "duplicate":
                        archive.writestr("Payload/Other.app/yw_1222.jpg", b"mock")
                with self.assertRaises(ValueError):
                    probe.resource_document(ipa)

    def fixture_sdk(self, root, extra=None):
        sdk = root / "sdk.zip"
        prefix = "AlibcTradeUltimateSDK_all_package_50018/Source/framework/securityGuard/"
        with zipfile.ZipFile(sdk, "w") as archive:
            for framework in probe.FRAMEWORKS:
                archive.writestr(prefix + framework + ".framework/" + framework, b"mock-static-lib")
            archive.writestr("Other.framework/Other", b"excluded")
            if extra:
                archive.writestr(prefix + "SGMain.framework/" + extra, b"unsafe")
        return sdk

    def test_hash_mismatch_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = self.fixture_sdk(root)
            with self.assertRaises(ValueError):
                probe.extract_sdk(sdk, root / "out")
            self.assertFalse((root / "out").exists())

    def test_only_selected_frameworks_are_extracted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = self.fixture_sdk(root)
            with patch.object(probe, "SDK_SHA256", hashlib.sha256(sdk.read_bytes()).hexdigest()):
                probe.extract_sdk(sdk, root / "out")
            self.assertEqual({name + ".framework" for name in probe.FRAMEWORKS},
                             {path.name for path in (root / "out").iterdir()})

    def test_parent_path_and_symlink_are_rejected(self):
        for mode in ("../escape", "symlink"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                sdk = self.fixture_sdk(root, None if mode == "symlink" else mode)
                if mode == "symlink":
                    info = zipfile.ZipInfo("AlibcTradeUltimateSDK_all_package_50018/Source/framework/securityGuard/SGMain.framework/link")
                    info.create_system = 3
                    info.external_attr = 0o120777 << 16
                    with zipfile.ZipFile(sdk, "a") as archive:
                        archive.writestr(info, "outside")
                with patch.object(probe, "SDK_SHA256", hashlib.sha256(sdk.read_bytes()).hexdigest()):
                    with self.assertRaises(ValueError):
                        probe.extract_sdk(sdk, root / "out")
                self.assertFalse((root / "out/escape").exists())


if __name__ == "__main__":
    unittest.main()
