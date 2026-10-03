"""给固定破壳样本制作原配本地诊断副本；保留原文件，不签名、不安装、不联网。"""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path

from audit_campus_ios_ipa import macho_header

SOURCE_SHA256 = "3b58d30aa678a997a5413a0d974771c15adcf75dd763ee740302780730e21209"
LIBRARY_NAME = "CampusOriginalProbe.dylib"
LIBRARY_PATH = "@executable_path/" + LIBRARY_NAME
ENTRY_SYMBOL = "CampusOriginalProbeMain"


def layout(data):
    header = macho_header(data)
    if header["cpu"] != "0x100000c" or header["declares_encryption"]:
        raise ValueError("需要未加密的 arm64 Mach-O。")
    count, size = struct.unpack_from("<II", data, 16)
    result = {"header_end": 32 + size, "sections": [], "segments": []}
    pos = 32
    for _ in range(count):
        command, length = struct.unpack_from("<II", data, pos)
        if command == 0x19:
            if length < 72:
                raise ValueError("segment 命令过短。")
            vm, vm_size, off, file_size = struct.unpack_from("<4Q", data, pos + 24)
            if off + file_size > len(data) or file_size > vm_size:
                raise ValueError("segment 文件范围无效。")
            result["segments"].append((vm, off, file_size))
            sections = struct.unpack_from("<I", data, pos + 64)[0]
            if sections > (length - 72) // 80:
                raise ValueError("section 命令越界。")
            for i in range(sections):
                at = pos + 72 + i * 80
                addr, size, offset = struct.unpack_from("<QQI", data, at + 32)
                flags, reserved1, reserved2 = struct.unpack_from("<III", data, at + 64)
                # S_ZEROFILL、S_GB_ZEROFILL、S_THREAD_LOCAL_ZEROFILL 没有文件内容。
                if flags & 255 not in (1, 12, 18) and size:
                    if offset + size > len(data):
                        raise ValueError("section 文件范围无效。")
                    result["sections"].append((addr, size, offset, flags, reserved1, reserved2))
        elif command == 2:
            if length < 24:
                raise ValueError("符号表命令过短。")
            result["symtab"] = struct.unpack_from("<4I", data, pos + 8)
        elif command == 11:
            if length < 80:
                raise ValueError("间接符号表命令过短。")
            fields = struct.unpack_from("<18I", data, pos + 8)
            result["indirect"] = fields[12:14]
        elif command == 0x80000028:
            if length < 24 or "entry" in result:
                raise ValueError("启动入口命令无效。")
            result["entry"] = struct.unpack_from("<Q", data, pos + 8)[0]
        elif command == 0x26:
            if length < 16:
                raise ValueError("函数边界命令过短。")
            result["starts"] = struct.unpack_from("<II", data, pos + 8)
        pos += length
    result["file_type"] = header["file_type"]
    return result


def vm_address(info, offset, length=1):
    for vm, off, size in info["segments"]:
        if off <= offset and offset + length <= off + size:
            return vm + offset - off
    raise ValueError("文件偏移没有映射到 segment。")


def import_stubs(data, info):
    sym, count, strings, string_size = info["symtab"]
    indirect, indirect_count = info["indirect"]
    if sym + count * 16 > len(data) or strings + string_size > len(data) or indirect + indirect_count * 4 > len(data):
        raise ValueError("符号表越界。")
    found = {}
    for addr, size, _, flags, base, stride in info["sections"]:
        if flags & 255 != 8:
            continue
        if not stride or size % stride or base + size // stride > indirect_count:
            raise ValueError("symbol stub 范围无效。")
        for i in range(size // stride):
            index = struct.unpack_from("<I", data, indirect + (base + i) * 4)[0]
            if index & 0xC0000000:
                continue
            if index >= count:
                raise ValueError("间接符号索引越界。")
            name_index = struct.unpack_from("<I", data, sym + index * 16)[0]
            if name_index >= string_size:
                raise ValueError("符号名称越界。")
            end = data.find(b"\0", strings + name_index, strings + string_size)
            if end < 0:
                raise ValueError("符号名称未结束。")
            name = data[strings + name_index:end]
            if name in (b"_dlopen", b"_dlsym"):
                if name in found:
                    raise ValueError("加载入口符号不唯一。")
                found[name] = addr + i * stride
    if len(found) != 2:
        raise ValueError("原主程序缺少明确的 dlopen/dlsym stub。")
    return found


def function_span(data, info):
    off, size = info["starts"]
    if off + size > len(data):
        raise ValueError("函数边界表越界。")
    starts, value, shift, current = [], 0, 0, 0
    for byte in data[off:off + size]:
        if shift > 63:
            raise ValueError("函数边界 ULEB 无效。")
        value |= (byte & 127) << shift
        if byte & 128:
            shift += 7
            continue
        if not value:
            break
        current += value
        starts.append(current)
        value = shift = 0
    try:
        index = starts.index(info["entry"])
        return starts[index + 1] - starts[index]
    except (ValueError, IndexError) as error:
        raise ValueError("无法确认原启动函数边界。") from error


def branch(pc, target, bits, opcode):
    delta = target - pc
    if delta % 4 or not -(1 << (bits + 1)) <= delta < (1 << (bits + 1)):
        raise ValueError("arm64 分支超出范围。")
    return opcode | ((delta // 4) & ((1 << bits) - 1))


def address_pair(register, pc, target):
    pages = ((target & ~4095) - (pc & ~4095)) // 4096
    if not -(1 << 20) <= pages < (1 << 20):
        raise ValueError("arm64 ADRP 超出范围。")
    return [0x90000000 | ((pages & 3) << 29) | (((pages >> 2) & 0x7FFFF) << 5) | register,
            0x91000000 | ((target & 4095) << 10) | (register << 5) | register]


def trampoline(entry, path, symbol, dlopen, dlsym):
    # 保存 argc/argv 和返回地址；失败返回 EX_CONFIG，不执行原校园入口。
    words = [0xA9BE4FF4, 0xA9017BFD, 0x910043FD, 0xAA0003F3, 0xAA0103F4]
    words += address_pair(0, entry + len(words) * 4, path)
    words += [0x52800041, branch(entry + 32, dlopen, 26, 0x94000000), 0]
    words += address_pair(1, entry + len(words) * 4, symbol)
    words += [branch(entry + 48, dlsym, 26, 0x94000000), 0,
              0xAA0003E8, 0xAA1303E0, 0xAA1403E1, 0xD63F0100, 0,
              0x528009C0, 0xA9417BFD, 0xA8C24FF4, 0xD65F03C0]
    # CBZ 的立即数位于 bits 5..23；两个失败点均跳到 mov w0,#78。
    for i in (9, 13):
        delta = 19 - i
        words[i] = 0xB4000000 | (delta << 5)
    words[18] = branch(entry + 72, entry + 80, 26, 0x14000000)
    return struct.pack("<" + "I" * len(words), *words)


def patch_main(data):
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise ValueError("不是已检查的校园 5.7.2 主程序，拒绝套用启动补丁。")
    info = layout(data)
    if info["file_type"] != 2:
        raise ValueError("原文件必须是 MH_EXECUTE。")
    span = function_span(data, info)
    first = min(section[2] for section in info["sections"])
    strings = LIBRARY_PATH.encode() + b"\0" + ENTRY_SYMBOL.encode() + b"\0"
    end = info["header_end"] + len(strings)
    if end > first or any(data[info["header_end"]:end]):
        raise ValueError("头部没有足够的空白空间，拒绝覆盖。")
    stub = import_stubs(data, info)
    start = info["entry"]
    code = trampoline(vm_address(info, start), vm_address(info, info["header_end"]),
                      vm_address(info, info["header_end"] + len(LIBRARY_PATH) + 1),
                      stub[b"_dlopen"], stub[b"_dlsym"])
    if len(code) > span or start + span > len(data):
        raise ValueError("补丁超过已确认的启动函数边界。")
    patched = bytearray(data)
    patched[info["header_end"]:end] = strings
    patched[start:start + len(code)] = code
    return bytes(patched)


def prepare(ipa, library, output):
    if output.exists() or output.resolve() in (ipa.resolve(), library.resolve()):
        raise ValueError("输出必须是新的独立文件。")
    if not 32 <= library.stat().st_size <= 16 * 1024 * 1024:
        raise ValueError("诊断库大小无效。")
    dylib = library.read_bytes()
    info = layout(dylib)
    if info["file_type"] != 6:
        raise ValueError("诊断库必须是 arm64 MH_DYLIB。")
    # 入口必须是已定义的外部符号，不能只在导入名称或其它字符串中出现。
    sym, count, strings, string_size = info.get("symtab", (0, 0, 0, 0))
    if sym + count * 16 > len(dylib) or strings + string_size > len(dylib):
        raise ValueError("诊断库符号表越界。")
    exported = False
    for i in range(count):
        index, kind, section, _, value = struct.unpack_from("<IBBHQ", dylib, sym + i * 16)
        if kind & 0xE0 or kind & 0x0F != 0x0F or not section or not value or index >= string_size:
            continue
        end = dylib.find(b"\0", strings + index, strings + string_size)
        if end >= 0 and dylib[strings + index:end] == b"_" + ENTRY_SYMBOL.encode():
            exported = True
    if not exported:
        raise ValueError("诊断库缺少已定义的导出启动入口。")
    with zipfile.ZipFile(ipa) as source:
        names = source.namelist()
        if len(names) != len(set(names)):
            raise ValueError("IPA 存在重复 ZIP 条目。")
        plists = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if len(plists) != 1:
            raise ValueError("IPA 主应用不唯一。")
        app = plists[0].rsplit("/", 1)[0]
        metadata = plistlib.loads(source.read(plists[0]))
        exe = metadata.get("CFBundleExecutable", "")
        if not exe or "/" in exe or "\\" in exe or exe in (".", ".."):
            raise ValueError("主程序名称无效。")
        binary_name = app + "/" + exe
        if metadata.get("CFBundleIdentifier") != "com.tmall.campus4iphone" or metadata.get("CFBundleShortVersionString") != "5.7.2":
            raise ValueError("仅支持已检查的原校园样本。")
        if source.getinfo(binary_name).file_size > 512 * 1024 * 1024:
            raise ValueError("原主程序过大。")
        binary = patch_main(source.read(binary_name))
        resources = {}
        for name in ("yw_1222.jpg", "yw_1222_mwua.jpg"):
            item = source.getinfo(app + "/" + name)
            if not 0 < item.file_size <= 65536:
                raise ValueError("原配资源大小无效。")
            content = source.read(item)
            resources[name] = {"bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}
        for key in ("UIApplicationSceneManifest", "UIMainStoryboardFile", "NSMainNibFile"):
            metadata.pop(key, None)
        metadata["CFBundleDisplayName"] = "校园原配诊断"
        minimum = str(metadata.get("MinimumOSVersion", "0"))
        try:
            minimum_parts = tuple(int(part) for part in minimum.split("."))
        except ValueError as error:
            raise ValueError("原包最低系统版本无效。") from error
        if minimum_parts < (16, 0):
            metadata["MinimumOSVersion"] = "16.0"
        metadata["CampusOriginalProbe"] = {"version": 1, "sourceBinarySHA256": SOURCE_SHA256,
                                           "librarySHA256": hashlib.sha256(dylib).hexdigest(), "resources": resources}
        library_name = app + "/" + LIBRARY_NAME
        if library_name in names:
            raise ValueError("原包已包含诊断库。")
        output.parent.mkdir(parents=True, exist_ok=True)
        destination = output.open("xb")
        try:
            with destination, zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as target:
                for item in source.infolist():
                    # 重签前去除原主应用签名清单，嵌套组件交给签名工具递归处理。
                    if item.filename.startswith(app + "/_CodeSignature/"):
                        continue
                    if item.filename == binary_name:
                        target.writestr(item, binary)
                    elif item.filename == plists[0]:
                        target.writestr(item, plistlib.dumps(metadata))
                    else:
                        with source.open(item) as original, target.open(item, "w") as copy:
                            import shutil
                            shutil.copyfileobj(original, copy)
                item = zipfile.ZipInfo(library_name)
                item.external_attr = 0o100755 << 16
                item.compress_type = zipfile.ZIP_DEFLATED
                target.writestr(item, dylib)
        except Exception:
            # 只删除本函数以 xb 新建的未完成输出，不删除已有文件。
            output.unlink(missing_ok=True)
            raise
    return {"format": "campus-original-probe", "version": 1, "resources": resources,
            "note": "未签名诊断副本；保留原 Bundle ID，需飞行模式和递归重签。原文件未改动。"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--dylib", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.ipa, args.dylib, args.output), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
