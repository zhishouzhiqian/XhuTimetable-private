import struct
import tempfile
import unittest
from pathlib import Path

import compact_campus_timetable_host as compact


def image(stripped=False, name=b'_entry', value=0x100000200, binding=b'bind', code=b'code'):
    rows = [(name, 0xF, 1, 0x300, value)] if stripped else [
        (b'local-debugging-name', 0xE, 1, 0, value), (b'debug-file', 0x64, 0, 0, 0),
        (name, 0xF, 1, 0x300, value)]
    strings = b'\0'
    symbols = b''
    for symbol, kind, section, desc, address in rows:
        symbols += struct.pack('<IBBHQ', len(strings), kind, section, desc, address)
        strings += symbol + b'\0'
    symoff, stringoff = 1024, 1024 + len(symbols)
    indirectoff = stringoff + len(strings)
    bindoff = indirectoff + 4
    segment = struct.pack('<II16sQQQQIIII', 0x19, 152, b'__TEXT', 0x100000000, 1024, 0, 1024, 5, 5, 1, 0)
    section = struct.pack('<16s16sQQ8I', b'__text', b'__TEXT', 0x100000200, 512, 512, 2, 0, 0, 0, 0, 0, 0)
    symtab = struct.pack('<6I', 2, 24, symoff, len(rows), stringoff, len(strings))
    external = 0 if stripped else 2
    dysymtab = struct.pack('<20I', 0xB, 80, 0, external, external, 1, len(rows), 0,
                          0, 0, 0, 0, 0, 0, indirectoff, 1, 0, 0, 0, 0)
    dyld = struct.pack('<12I', 0x80000022, 48, 0, 0, bindoff, len(binding), 0, 0, 0, 0, 0, 0)
    entry = struct.pack('<IIQQ', 0x80000028, 24, 512, 0)
    commands = segment + section + symtab + dysymtab + dyld + entry
    header = struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, 5, len(commands), 0, 0)
    return (header + commands).ljust(512, b'\0') + code.ljust(512, b'\0') + symbols + strings + struct.pack('<I', external) + binding


class CompactTests(unittest.TestCase):
    def test_local_debug_names_removed_and_indirect_indices_remapped(self):
        before, after = image(), image(stripped=True)
        self.assertLess(len(after), len(before))
        self.assertTrue(compact.verify_runtime(before, after))

    def test_code_change_rejected(self):
        with self.assertRaisesRegex(ValueError, '运行段'):
            compact.verify_runtime(image(), image(stripped=True, code=b'changed'))

    def test_external_symbol_name_or_address_change_rejected(self):
        for changed in (image(stripped=True, name=b'_other'), image(stripped=True, value=0x100000204)):
            with self.assertRaises(ValueError): compact.verify_runtime(image(), changed)

    def test_binding_payload_change_rejected(self):
        with self.assertRaises(ValueError):
            compact.verify_runtime(image(), image(stripped=True, binding=b'changed'))

    def test_entrypoint_change_rejected(self):
        after = bytearray(image(stripped=True))
        pos = after.find(struct.pack('<IIQQ', 0x80000028, 24, 512, 0))
        struct.pack_into('<Q', after, pos + 8, 516)
        with self.assertRaises(ValueError): compact.verify_runtime(image(), bytes(after))

    def test_truncated_image_rejected(self):
        with self.assertRaises(ValueError): compact.runtime_image(image()[:300])

    def test_existing_output_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'result.ipa'; output.write_bytes(b'existing')
            with self.assertRaises(ValueError): compact.prepare(Path(directory) / 'absent.ipa', output, Path('unused-tool'))
            self.assertEqual(output.read_bytes(), b'existing')


if __name__ == '__main__':
    unittest.main()
