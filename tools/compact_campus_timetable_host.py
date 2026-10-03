"""在资源精简后剥离符号；运行数据、依赖和全部外部符号必须保持一致。"""
import argparse
import copy
import json
import plistlib
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path

from audit_campus_ios_ipa import macho_header
from slim_campus_timetable_host import digest, plan


def runtime_image(data):
    header = macho_header(data)
    if header['cpu'] != '0x100000c' or header['declares_encryption']:
        raise ValueError('符号精简仅接受未加密 arm64 映像。')
    segments, payloads, commands, symbols = [], [], [], []
    symtab = dysymtab = None
    pos = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        cmd, size = struct.unpack_from('<II', data, pos)
        raw = data[pos:pos + size]
        if cmd == 0x19:
            name, vm, vmsize, offset, length, maximum, initial, count, flags = struct.unpack_from('<16sQQQQIIII', data, pos + 8)
            if offset + length > len(data) or size != 72 + count * 80:
                raise ValueError('段范围或段命令无效。')
            if name.rstrip(b'\0') != b'__LINKEDIT':
                sections = [data[pos + 72 + j * 80:pos + 152 + j * 80] for j in range(count)]
                start = struct.unpack_from('<I', sections[0], 48)[0] if offset == 0 and sections else offset
                if length and offset == 0 and (not sections or start < 32 + struct.unpack_from('<I', data, 20)[0]):
                    raise ValueError('不能确定代码段头部与运行数据边界。')
                segments.append((name, vm, vmsize, offset, length, maximum, initial, flags, sections,
                                 digest(data[start:offset + length])))
        elif cmd == 2:
            symtab = struct.unpack_from('<4I', data, pos + 8)
        elif cmd == 0xB:
            dysymtab = struct.unpack_from('<18I', data, pos + 8)
            # 不支持仍带外部引用/模块/重定位表的其它载体，避免错误重映射。
            if any(dysymtab[i] for i in (7, 9, 11, 15, 17)):
                raise ValueError('载体含未覆盖的动态符号辅助表。')
        elif cmd in (0x22, 0x80000022):
            pairs = struct.unpack_from('<10I', data, pos + 8)
            blocks = []
            for i in range(0, 10, 2):
                offset, length = pairs[i:i + 2]
                if offset + length > len(data): raise ValueError('dyld 数据越界。')
                blocks.append(digest(data[offset:offset + length]))
            payloads.append((cmd, blocks))
        elif cmd in (0x26, 0x29, 0x80000033, 0x80000034):
            offset, length = struct.unpack_from('<II', data, pos + 8)
            if offset + length > len(data): raise ValueError('链接数据越界。')
            payloads.append((cmd, digest(data[offset:offset + length])))
        elif cmd != 0x1D:  # 重签会重新生成签名；其余加载命令必须相同。
            commands.append(raw)
        pos += size
    if symtab is None or dysymtab is None:
        raise ValueError('缺少完整符号表。')
    offset, count, strings, string_size = symtab
    if offset + count * 16 > len(data) or strings + string_size > len(data):
        raise ValueError('符号表越界。')

    def symbol(index):
        if not 0 <= index < count: raise ValueError('间接符号索引越界。')
        name, kind, section, desc, value = struct.unpack_from('<IBBHQ', data, offset + index * 16)
        if name >= string_size: raise ValueError('符号名称越界。')
        end = data.find(b'\0', strings + name, strings + string_size)
        if end < 0: raise ValueError('符号名称未终止。')
        return data[strings + name:end], kind, section, desc, value

    for i in range(count):
        kind = data[offset + i * 16 + 4]
        if not kind & 0xE0 and kind & 1:
            symbols.append(symbol(i))
    indirect_offset, indirect_count = dysymtab[12:14]
    if indirect_offset + indirect_count * 4 > len(data): raise ValueError('间接符号表越界。')
    indirect = []
    for i in range(indirect_count):
        index = struct.unpack_from('<I', data, indirect_offset + i * 4)[0]
        indirect.append(index if index & 0xC0000000 else symbol(index))
    return data[:16] + data[24:32], segments, payloads, commands, sorted(symbols), indirect


def verify_runtime(before, after):
    if runtime_image(before) != runtime_image(after):
        raise ValueError('符号剥离改变了运行段、加载入口、绑定数据、外部或间接符号。')
    return True


def prepare(ipa, output, strip_tool):
    if output.exists() or output.resolve() == ipa.resolve():
        raise ValueError('输出必须是新的独立文件。')
    with zipfile.ZipFile(ipa) as source, tempfile.TemporaryDirectory(prefix='campus-compact-') as directory:
        app, removed, retained, linked = plan(source)
        metadata = plistlib.loads(source.read(app + 'Info.plist'))
        replacements, binaries = {}, []
        for index, name in enumerate((app + metadata['CFBundleExecutable'], app + 'CampusOriginalProbe.dylib')):
            before = source.read(name)
            original, stripped = Path(directory) / f'{index}.original', Path(directory) / f'{index}.stripped'
            original.write_bytes(before)
            # 显式指定选项与独立输出，不使用默认 strip-all 或原地改写。
            subprocess.run([str(strip_tool), '--discard-all', '-o', str(stripped), str(original)], check=True,
                           capture_output=True, timeout=180)
            after = stripped.read_bytes()
            verify_runtime(before, after)
            # Release 库可能已由构建脚本剥离，不为了改变签名而增大或改写它。
            if len(after) >= len(before): after = before
            replacements[name] = after
            binaries.append({'name': name[len(app):], 'beforeBytes': len(before), 'afterBytes': len(after),
                             'beforeSHA256': digest(before), 'afterSHA256': digest(after), 'runtimeVerified': True,
                             'symbolsChanged': before != after})
        metadata['CampusOriginalProbe']['librarySHA256'] = digest(replacements[app + 'CampusOriginalProbe.dylib'])
        metadata['CampusTimetableCompact'] = {'version': 1, 'sourceIPA_SHA256': digest(ipa.read_bytes()),
                                             'binaries': binaries, 'runtimeVerified': True}
        replacements[app + 'Info.plist'] = plistlib.dumps(metadata)
        output.parent.mkdir(parents=True, exist_ok=True)
        created = False
        try:
            with output.open('xb') as stream:
                created = True
                with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as target:
                    for item in source.infolist():
                        if item.filename in removed: continue
                        data = replacements[item.filename] if item.filename in replacements else source.read(item)
                        target.writestr(copy.copy(item), data, compresslevel=9)
            with zipfile.ZipFile(output) as target:
                if target.testzip() or set(target.namelist()) != retained: raise ValueError('精简包完整性不通过。')
                for name in retained:
                    expected = replacements.get(name)
                    if expected is None: expected = source.read(name)
                    if digest(target.read(name)) != digest(expected): raise ValueError('保留文件核对失败。')
                plan(target)
        except Exception:
            if created: output.unlink(missing_ok=True)
            raise
        return {'format': 'xhu-campus-timetable-symbol-compact', 'sourceBytes': ipa.stat().st_size,
                'outputBytes': output.stat().st_size, 'savedBytes': ipa.stat().st_size - output.stat().st_size,
                'binaries': binaries, 'linkedImages': len(linked), 'runtimeVerified': True,
                'note': '资源和符号精简，不移除原校园静态业务代码；须递归重签并在真机验收。'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--strip-tool', type=Path, required=True)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.report and (args.report.exists() or args.report.resolve() in (args.ipa.resolve(), args.output.resolve())):
        parser.error('报告必须是新的独立文件。')
    result = prepare(args.ipa, args.output, args.strip_tool)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.report: args.report.write_text(text + '\n', encoding='utf-8')
    print(text)


if __name__ == '__main__':
    main()
