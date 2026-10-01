import struct
import unittest

from audit_campus_ios_signing import ObjcImage


BASE = 0x100000000


def image(relative=False, direct=False, cryptid=0):
    data = bytearray(2048)
    encryption = struct.pack("<6I", 0x2C, 24, 0, 0, cryptid, 0)
    segment = struct.pack("<II16s4Q4I", 0x19, 152, b"__DATA", BASE, len(data), 0, len(data), 7, 3, 1, 0)
    section = struct.pack("<16s16sQQ8I", b"__objc_classlist", b"__DATA", BASE + 0x110, 8, 0x110, 0, 0, 0, 0, 0, 0, 0)
    commands = encryption + segment + section
    data[:32] = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 2, 2, len(commands), 0, 0)
    data[32:32 + len(commands)] = commands
    def pointer(at, target):
        struct.pack_into("<Q", data, at, BASE + target if target else 0)
    pointer(0x110, 0x140)
    pointer(0x140, 0x180)
    pointer(0x140 + 32, 0x1C0)
    pointer(0x180 + 32, 0x200)
    pointer(0x1C0 + 24, 0x240)
    pointer(0x1C0 + 32, 0x280)
    name = b"SecurityGuardOpenUnifiedSecurity\0"
    data[0x240:0x240 + len(name)] = name
    for at, name in [(0x300, b"init:error:\0"), (0x320, b"getPrivateSecret\0")]:
        data[at:at + len(name)] = name
    if relative:
        flags = 0x80000000 | (0x40000000 if direct else 0) | 12
        struct.pack_into("<II", data, 0x280, flags, 2)
        for at, name, ref in [(0x288, 0x300, 0x380), (0x294, 0x320, 0x388)]:
            pointer(ref, name)
            struct.pack_into("<iii", data, at, (name if direct else ref) - at, 0, 0x400 - (at + 8))
    else:
        struct.pack_into("<II", data, 0x280, 24, 2)
        for at, name in [(0x288, 0x300), (0x2A0, 0x320)]:
            struct.pack_into("<QQQ", data, at, BASE + name, 0, BASE + 0x400)
    return data


class SigningMetadataTest(unittest.TestCase):
    def test_absolute_and_both_relative_method_formats(self):
        for relative, direct in [(False, False), (True, False), (True, True)]:
            with self.subTest(relative=relative, direct=direct):
                report = ObjcImage(image(relative, direct)).signing_entries()
                self.assertEqual([{"selector": "init:error:", "implementation": hex(BASE + 0x400)}],
                                 report["SecurityGuardOpenUnifiedSecurity"]["instance_methods"])
                self.assertNotIn("getPrivateSecret", str(report))

    def test_encrypted_program_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "声明加密"):
            ObjcImage(image(cryptid=1))

    def test_class_pointer_outside_image_is_rejected(self):
        data = image()
        struct.pack_into("<Q", data, 0x110, BASE + len(data))
        with self.assertRaises(ValueError):
            ObjcImage(data).signing_entries()

    def test_method_list_exceeding_mapping_is_rejected(self):
        data = image()
        struct.pack_into("<I", data, 0x284, 1000)
        with self.assertRaises(ValueError):
            ObjcImage(data).signing_entries()

    def test_segment_and_section_bounds_are_checked(self):
        for at, value in [(32 + 24 + 64, 2), (32 + 24 + 48, len(image()) + 1)]:
            with self.subTest(at=at):
                data = image()
                struct.pack_into("<I", data, at, value)
                with self.assertRaises(ValueError):
                    ObjcImage(data)

    def test_unknown_class_does_not_expose_method_names(self):
        data = image()
        name = b"UnrelatedClass\0"
        data[0x240:0x240 + len(name)] = name
        self.assertEqual({}, ObjcImage(data).signing_entries())

    def test_unterminated_name_is_rejected(self):
        data = image()
        struct.pack_into("<Q", data, 0x1C0 + 24, BASE + len(data) - 1)
        data[-1] = ord("x")
        with self.assertRaises(ValueError):
            ObjcImage(data).signing_entries()


if __name__ == "__main__":
    unittest.main()
