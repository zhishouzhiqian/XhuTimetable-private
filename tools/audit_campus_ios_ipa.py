"""离线读取 IPA 的目录与 Mach-O 头；不解密、不运行 App、不输出账户或请求内容。"""
import argparse
import json
import plistlib
import struct
import zipfile
from pathlib import Path


def macho_header(data: bytes) -> dict:
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("需要完整的 little-endian 64 位 Mach-O 头")
    _, cpu, _, file_type, count, commands_size, _, _ = struct.unpack_from("<8I", data)
    if commands_size > len(data) - 32 or count > commands_size // 8:
        raise ValueError("Mach-O 命令区不完整")
    end = 32 + commands_size
    pos = 32
    encryption = []
    for _ in range(count):
        if pos + 8 > end:
            raise ValueError("Mach-O 命令越界")
        command, size = struct.unpack_from("<II", data, pos)
        if size < 8 or pos + size > end:
            raise ValueError("Mach-O 命令大小无效")
        if command in (0x21, 0x2C):
            if size < 20:
                raise ValueError("加密命令不完整")
            offset, length, crypt_id = struct.unpack_from("<III", data, pos + 8)
            encryption.append({"cryptid": crypt_id, "offset": offset, "bytes": length})
        pos += size
    if pos != end:
        raise ValueError("Mach-O 命令总大小不匹配")
    return {"cpu": hex(cpu), "file_type": file_type, "encryption": encryption,
            "declares_encryption": any(item["cryptid"] != 0 for item in encryption)}


def inspect_ipa(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        main_plists = [name for name in names if name.startswith("Payload/") and
                       name.endswith(".app/Info.plist") and name.count("/") == 2]
        if len(main_plists) != 1:
            raise ValueError("IPA 必须包含一个主 App")
        info_path = main_plists[0]
        info = plistlib.loads(archive.read(info_path))
        app = info_path.rsplit("/", 1)[0]
        executable = info.get("CFBundleExecutable", "")
        if not executable or "/" in executable or "\\" in executable or executable in (".", ".."):
            raise ValueError("主程序名无效")
        with archive.open(app + "/" + executable) as stream:
            header = macho_header(stream.read(1024 * 1024))
        frameworks = sorted({name.split(".framework/")[0].rsplit("/", 1)[-1] + ".framework"
                             for name in names if ".framework/" in name})
        security_frameworks = [name for name in frameworks if any(part in name.lower()
                               for part in ("mtop", "securityguard", "sgsecurity", "securitybody"))]
        return {"bundle_id": info.get("CFBundleIdentifier"),
                "version": info.get("CFBundleShortVersionString"),
                "ipa_bytes": path.stat().st_size, "main_program": header,
                "frameworks": frameworks, "separate_campus_frameworks": security_frameworks,
                "security_resource_count": sum(name.rsplit("/", 1)[-1].startswith("yw_") for name in names),
                "note": "仅凭加密标志和目录不能证明所有安全组件的实现或可移植性；主 App 可执行文件不等同于 SDK。"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = json.dumps(inspect_ipa(args.ipa), ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report + "\n", encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
