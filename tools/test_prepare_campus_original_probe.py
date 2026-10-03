"""验证启动补丁边界、失败退出分支及 IPA 副本保护；不执行原程序。"""
import hashlib
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import prepare_campus_original_probe as probe


def fixture(file_type=2):
    data = bytearray(1536)
    segment = bytearray(232)
    struct.pack_into("<II16sQQQQIIII", segment, 0, 0x19, 232, b"__TEXT", 0x100000000, 2048, 0, 1536, 7, 5, 2, 0)
    struct.pack_into("<16s16sQQIIIIIIII", segment, 72, b"__text", b"__TEXT", 0x100000200, 128, 512, 2, 0, 0, 0, 0, 0, 0)
    struct.pack_into("<16s16sQQIIIIIIII", segment, 152, b"__stubs", b"__TEXT", 0x100000320, 24, 800, 2, 0, 0, 8, 0, 12, 0)
    symbols = b"\0_dlopen\0_dlsym\0"
    if file_type == 6: symbols += b"_CampusOriginalProbeMain\0"
    symtab = struct.pack("<6I", 2, 24, 1024, 3 if file_type == 6 else 2, 1088, len(symbols))
    dysymtab = bytearray(80)
    struct.pack_into("<II", dysymtab, 0, 11, 80)
    struct.pack_into("<II", dysymtab, 56, 1200, 2)
    commands = bytes(segment) + symtab + bytes(dysymtab) + struct.pack("<IIQQ", 0x80000028, 24, 512, 0) + struct.pack("<4I", 0x26, 16, 1240, 5)
    struct.pack_into("<8I", data, 0, 0xFEEDFACF, 0x100000C, 0, file_type, 5, len(commands), 0, 0)
    data[32:32 + len(commands)] = commands
    struct.pack_into("<IBBHQ", data, 1024, 1, 1, 0, 0, 0)
    struct.pack_into("<IBBHQ", data, 1040, 9, 1, 0, 0, 0)
    if file_type == 6: struct.pack_into("<IBBHQ", data, 1056, 16, 15, 1, 0, 0x100000200)
    data[1088:1088 + len(symbols)] = symbols
    struct.pack_into("<II", data, 1200, 0, 1)
    data[1240:1245] = b"\x80\x04\x80\x01\0"  # 函数 512 与 640。
    return bytes(data)


class OriginalProbeTests(unittest.TestCase):
    def patch_fixture(self, data):
        with patch.object(probe, "SOURCE_SHA256", hashlib.sha256(data).hexdigest()):
            return probe.patch_main(data)

    def test_exact_change_boundaries(self):
        original = fixture()
        patched = self.patch_fixture(original)
        info = probe.layout(original)
        allowed = set(range(info["header_end"], info["header_end"] + len(probe.LIBRARY_PATH) + len(probe.ENTRY_SYMBOL) + 2)) | set(range(512, 604))
        changes = {i for i, (a, b) in enumerate(zip(original, patched)) if a != b}
        self.assertTrue(changes and changes <= allowed)
        self.assertEqual(len(original), len(patched))
        self.assertEqual(probe.macho_header(original), probe.macho_header(patched))

    def test_pinned_source_and_no_repatch(self):
        with self.assertRaises(ValueError):
            probe.patch_main(fixture())
        patched = self.patch_fixture(fixture())
        with self.assertRaises(ValueError):
            self.patch_fixture(patched)

    def test_dirty_padding(self):
        data = bytearray(fixture())
        data[probe.layout(data)["header_end"]] = 1
        with self.assertRaises(ValueError):
            self.patch_fixture(bytes(data))

    def test_short_function_and_bad_symbol_table(self):
        data = bytearray(fixture())
        data[1242:1245] = b"\x10\0\0"
        with self.assertRaises(ValueError):
            self.patch_fixture(bytes(data))
        data = bytearray(fixture())
        struct.pack_into("<I", data, 1200, 99)
        with self.assertRaises(ValueError):
            self.patch_fixture(bytes(data))

    def test_arm64_branch_targets(self):
        entry = 0x100000200
        words = struct.unpack("<23I", probe.trampoline(entry, 0x100000198, 0x1000001C0, 0x100000320, 0x10000032C))
        for index, expected in [(8, 0x100000320), (12, 0x10000032C), (18, entry + 80)]:
            value = words[index] & 0x3FFFFFF
            if value & (1 << 25): value -= 1 << 26
            self.assertEqual(entry + index * 4 + value * 4, expected)
        for index in (9, 13):
            self.assertEqual(index + ((words[index] >> 5) & 0x7FFFF), 19)
        with self.assertRaises(ValueError):
            probe.branch(entry, entry + (1 << 28), 26, 0x94000000)

    def test_prepare_preserves_source_resources_and_identity(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source, library, output = root / "source.ipa", root / "probe.dylib", root / "result.ipa"
            app = "Payload/Campus.app/"
            info = {"CFBundleExecutable": "Campus", "CFBundleIdentifier": "com.tmall.campus4iphone", "CFBundleShortVersionString": "5.7.2", "UIApplicationSceneManifest": {}}
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(app + "Info.plist", plistlib.dumps(info))
                archive.writestr(app + "Campus", fixture())
                archive.writestr(app + "yw_1222.jpg", b"main")
                archive.writestr(app + "yw_1222_mwua.jpg", b"mwua")
                archive.writestr(app + "_CodeSignature/CodeResources", b"old")
            library.write_bytes(fixture(6))
            before = source.read_bytes()
            with patch.object(probe, "SOURCE_SHA256", hashlib.sha256(fixture()).hexdigest()):
                probe.prepare(source, library, output)
            self.assertEqual(source.read_bytes(), before)
            with zipfile.ZipFile(output) as archive:
                updated = plistlib.loads(archive.read(app + "Info.plist"))
                self.assertEqual(updated["CFBundleIdentifier"], info["CFBundleIdentifier"])
                self.assertEqual(updated["MinimumOSVersion"], "16.0")
                self.assertNotIn("UIApplicationSceneManifest", updated)
                self.assertNotIn(app + "_CodeSignature/CodeResources", archive.namelist())
                self.assertEqual(archive.read(app + "yw_1222.jpg"), b"main")
                self.assertEqual(archive.read(app + probe.LIBRARY_NAME), library.read_bytes())
                self.assertIsNone(archive.testzip())
            with self.assertRaises(ValueError):
                probe.prepare(source, library, output)

    def test_reject_dylib_without_defined_export(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            library = root / "probe.dylib"
            data = bytearray(fixture(6))
            data[1060] = 1  # 将入口标记成未定义导入。
            library.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "导出启动入口"):
                probe.prepare(root / "absent.ipa", library, root / "output.ipa")


if __name__ == "__main__":
    unittest.main()
