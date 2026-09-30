import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from audit_campus_ios_ipa import inspect_ipa, macho_header


def binary(cryptid=1, file_type=2):
    command = struct.pack("<6I", 0x2C, 24, 32768, 4096, cryptid, 0)
    return struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, file_type, 1, len(command), 0, 0) + command


class IpaAuditTest(unittest.TestCase):
    def test_encryption_flag_is_reported_without_reading_protected_code(self):
        self.assertTrue(macho_header(binary())["declares_encryption"])
        self.assertEqual(2, macho_header(binary())["file_type"])

    def test_zero_flag_does_not_claim_runtime_success(self):
        self.assertFalse(macho_header(binary(0))["declares_encryption"])

    def test_incomplete_command_is_rejected(self):
        with self.assertRaises(ValueError):
            macho_header(binary()[:-1])

    def test_bad_command_size_is_rejected(self):
        value = bytearray(binary())
        struct.pack_into("<I", value, 36, 4)
        with self.assertRaises(ValueError):
            macho_header(bytes(value))

    def test_non_macho_is_rejected(self):
        with self.assertRaises(ValueError):
            macho_header(b"not a binary")

    def test_archive_lists_sdk_and_resources_but_not_private_plist_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mock.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Mock.app/Info.plist", plistlib.dumps({
                    "CFBundleExecutable": "Mock", "CFBundleIdentifier": "invalid.example.mock",
                    "CFBundleShortVersionString": "0.1", "privateMockValue": "not-for-report"}))
                archive.writestr("Payload/Mock.app/Mock", binary())
                archive.writestr("Payload/Mock.app/yw_mock.jpg", b"mock")
                archive.writestr("Payload/Mock.app/Frameworks/SecurityGuardSDK.framework/SecurityGuardSDK", b"mock")
            report = inspect_ipa(path)
            self.assertEqual(["SecurityGuardSDK.framework"], report["separate_campus_frameworks"])
            self.assertEqual(1, report["security_resource_count"])
            self.assertNotIn("not-for-report", str(report))


if __name__ == "__main__":
    unittest.main()
