"""离线核对破壳 IPA 的 Objective-C 签名入口；不执行代码，不读取或输出密钥。"""
import argparse
import json
import plistlib
import struct
import zipfile
from pathlib import Path

from audit_campus_ios_ipa import macho_header


ENTRY_POINTS = {
    "AppInfo": {"appKey"},
    "TBSecretMgr": {"getAppKeyWithIos", "getAppKeyWithIndex:", "sharedInstance"},
    "TCSyncLauncher": {"setupMTOP", "setupAccount"},
    "SecurityGuardManager": {"getInstance", "getStaticDataStoreComp", "getSDKVersion"},
    "OpenSecurityGuardManager": {"getInstance:withCustomBundlePath:error:", "getSDKVersion"},
    "SecurityGuardStaticDataStore": {"getAppKey:"},
    "SecurityGuardOpenStaticDataStore": {"getAppKey:authCode:"},
    "SecurityGuardOpenUnifiedSecurity": {"init:error:", "getSecurityFactors:error:"},
    "TBSDKSecurity": {"UnifiedTier", "factorSign:input:extendParas:isUseWua:api:requestId:"},
    "TBSDkSignUtility": {
        "getSecurityFactors:withApiName:withApiVersion:withProtocolParam:withBizParam:withHttpHeader:withUseWua:withRequestId:withInstanceId:",
    },
}


class ObjcImage:
    def __init__(self, data):
        self.data = data
        self.header = macho_header(data)
        if self.header["declares_encryption"]:
            raise ValueError("主程序仍声明加密，不能以方法元数据推断可分析的实现")
        self.segments = []
        self.sections = []
        pos = 32
        for _ in range(struct.unpack_from("<I", data, 16)[0]):
            command, length = struct.unpack_from("<II", data, pos)
            if command == 0x19:
                if length < 72:
                    raise ValueError("segment 命令不完整")
                vm, vm_size, offset, size = struct.unpack_from("<4Q", data, pos + 24)
                count = struct.unpack_from("<I", data, pos + 64)[0]
                if count > (length - 72) // 80 or offset + size > len(data) or size > vm_size:
                    raise ValueError("segment 或 section 大小无效")
                if size:
                    self.segments.append((vm, size, offset))
                for i in range(count):
                    name, _, address, size = struct.unpack_from("<16s16sQQ", data, pos + 72 + i * 80)
                    self.sections.append((name.rstrip(b"\0"), address, size))
            pos += length

    def read(self, address, size):
        for start, length, offset in self.segments:
            if start <= address and size >= 0 and address + size <= start + length:
                at = offset + address - start
                return self.data[at:at + size]
        raise ValueError("元数据指针不在文件映射范围")

    def pointer(self, address):
        return struct.unpack("<Q", self.read(address, 8))[0]

    def name(self, address):
        for start, length, _ in self.segments:
            if start <= address < start + length:
                value = self.read(address, min(1024, start + length - address))
                end = value.find(b"\0")
                if end < 0:
                    raise ValueError("元数据名称未终止或过长")
                return value[:end].decode("utf-8", errors="strict")
        raise ValueError("元数据名称指针无效")

    def methods(self, address, allowed):
        if not address:
            return []
        flags, count = struct.unpack("<II", self.read(address, 8))
        relative = bool(flags & 0x80000000)
        stride = flags & 0xFFFF & ~3
        if stride < (12 if relative else 24) or count > 65536:
            raise ValueError("方法列表大小无效")
        self.read(address + 8, stride * count)
        found = []
        for i in range(count):
            at = address + 8 + stride * i
            if relative:
                name, _, imp = struct.unpack("<iii", self.read(at, 12))
                name_address = at + name
                if not flags & 0x40000000:
                    name_address = self.pointer(name_address)
                imp_address = at + 8 + imp
            else:
                name_address, _, imp_address = struct.unpack("<QQQ", self.read(at, 24))
            name = self.name(name_address)
            if name in allowed:
                self.read(imp_address, 4)
                found.append({"selector": name, "implementation": hex(imp_address)})
        return found

    def signing_entries(self):
        result = {}
        for name, address, size in self.sections:
            if name != b"__objc_classlist":
                continue
            if size % 8 or size // 8 > 100000:
                raise ValueError("类列表大小无效")
            self.read(address, size)
            for at in range(address, address + size, 8):
                cls = self.pointer(at)
                ro = self.pointer(cls + 32) & ~7
                name = self.name(self.pointer(ro + 24))
                if name not in ENTRY_POINTS:
                    continue
                meta = self.pointer(cls)
                meta_ro = self.pointer(meta + 32) & ~7
                result[name] = {
                    "instance_methods": self.methods(self.pointer(ro + 32), ENTRY_POINTS[name]),
                    "class_methods": self.methods(self.pointer(meta_ro + 32), ENTRY_POINTS[name]),
                }
        return result


def inspect_signing(path):
    with zipfile.ZipFile(path) as archive:
        plists = [name for name in archive.namelist() if name.startswith("Payload/") and
                  name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(plists) != 1:
            raise ValueError("IPA 必须包含一个主 App")
        info = plistlib.loads(archive.read(plists[0]))
        name = info.get("CFBundleExecutable", "")
        if not name or "/" in name or "\\" in name or name in (".", ".."):
            raise ValueError("主程序名称无效")
        executable = plists[0].rsplit("/", 1)[0] + "/" + name
        if not 32 <= archive.getinfo(executable).file_size <= 512 * 1024 * 1024:
            raise ValueError("主程序大小不支持")
        image = ObjcImage(archive.read(executable))
        return {
            "bundle_id": info.get("CFBundleIdentifier"),
            "version": info.get("CFBundleShortVersionString"),
            "entry_points": image.signing_entries(),
            "note": "仅包含白名单中的类、方法名及实现地址；方法存在不代表候选 SDK 可用或服务器接受签名。",
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = json.dumps(inspect_signing(args.ipa), ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report + "\n", encoding="utf-8")
    print(report)
