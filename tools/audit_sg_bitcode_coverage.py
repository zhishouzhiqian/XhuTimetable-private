"""复核候选 SDK 静态库的 bitcode 覆盖面与关键字面量（只读）。

用途：
1. 列出四个 framework 静态库的全部 .o 成员，标记哪些含 __bitcode、哪些可被 llvmlite 解析；
   以此界定「IR 中不存在」结论的覆盖边界。
2. 在原始二进制内搜索 yw_1222 / mwua / getAppKey 等字面量（不解密任何数据）。

依赖本地分析产物目录（默认 <repo>/build/laundry-ios-analysis，可用 --root 覆盖）：
  campus-ios-probe/frameworks/<C>.framework/<C>   四个候选 SDK 静态库
  deps/llvmlite                                   本地 Python 依赖
  Campus.arm64                                    校园主程序 arm64 切片（可选）
"""
import argparse
import struct
import sys
from pathlib import Path

def arm64_slice(data: bytes) -> bytes:
    if data[:4] == b'\xca\xfe\xba\xbe':
        n = struct.unpack_from('>I', data, 4)[0]
        for i in range(n):
            cpu, subtype, off, length, align = struct.unpack_from('>IIIII', data, 8 + 20*i)
            if cpu == 0x100000c:
                return data[off:off+length]
        raise ValueError('no arm64 slice')
    return data

def members(data: bytes):
    assert data.startswith(b'!<arch>\n')
    pos = 8
    while pos + 60 <= len(data):
        h = data[pos:pos+60]
        length = int(h[48:58])
        blob = data[pos+60:pos+60+length]
        name = h[:16].decode().strip()
        if name.startswith('#1/'):
            n = int(name[3:])
            name = blob[:n].rstrip(b'\0').decode()
            blob = blob[n:]
        yield name, blob
        pos += 60 + length + (length % 2)

def bitcode_sections(blob: bytes):
    if blob[:4] != b'\xcf\xfa\xed\xfe':
        return None
    out = []
    at = 32
    for _ in range(struct.unpack_from('<I', blob, 16)[0]):
        cmd, size = struct.unpack_from('<II', blob, at)
        if cmd == 0x19:
            count = struct.unpack_from('<I', blob, at+64)[0]
            for k in range(count):
                section, segment, addr, siz, off = struct.unpack_from('<16s16sQQI', blob, at+72+k*80)
                if section.rstrip(b'\0') == b'__bitcode':
                    out.append(blob[off:off+siz])
        at += size
    return out

def main() -> int:
    parser = argparse.ArgumentParser()
    default_root = Path(__file__).resolve().parent.parent / 'build' / 'laundry-ios-analysis'
    parser.add_argument('--root', default=str(default_root))
    args = parser.parse_args()
    root = Path(args.root)
    fw_dir = root.parent / 'campus-ios-probe/frameworks'
    sys.path.insert(0, str(root / 'deps'))
    from llvmlite import binding as llvm

    print('== bitcode 覆盖面 ==')
    for framework in ('SGMain', 'SGMiddleTier', 'SecurityGuardSDK', 'SGSecurityBody'):
        data = (fw_dir / (framework + '.framework') / framework).read_bytes()
        data = arm64_slice(data)
        for name, blob in members(data):
            if not name.endswith('.o'):
                continue
            bcs = bitcode_sections(blob)
            if bcs is None:
                print(f'{framework:16} {name:40} not-macho({len(blob)})')
                continue
            if not bcs:
                print(f'{framework:16} {name:40} NO __bitcode ({len(blob)})')
                continue
            for bc in bcs:
                try:
                    mod = llvm.parse_bitcode(bc)
                    nf = sum(1 for f in mod.functions if not f.is_declaration)
                    print(f'{framework:16} {name:40} bitcode OK  {len(bc):>9}B  defines={nf}')
                except RuntimeError as e:
                    print(f'{framework:16} {name:40} bitcode UNPARSED {len(bc):>9}B  ({e})')

    print()
    print('== 二进制内字面量搜索（原始字节，不解密）==')
    needles = [b'yw_1222', b'mwua', b'.jpg', b'getAppKey', b'customBundelPath', b'SEC_ERROR']
    targets = list(fw_dir.glob('*.framework'))
    campus = root / 'Campus.arm64'
    if campus.exists():
        targets.append(campus)
    for t in targets:
        binp = t / t.name.replace('.framework', '') if t.suffix == '.framework' else t
        if not binp.exists():
            continue
        data = binp.read_bytes()
        hits = {n.decode(): data.count(n) for n in needles}
        hits = {k: v for k, v in hits.items() if v}
        print(f'{binp.name:40} size={len(data):>10}  hits={hits if hits else "无"}')
    return 0

if __name__ == '__main__':
    sys.exit(main())
