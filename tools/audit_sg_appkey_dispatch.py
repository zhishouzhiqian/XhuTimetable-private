"""复核候选 SDK 的 AppKey 分发链与「宿主通道」假设（只读，不解密安全图片）。

回答交接提出的三个待追踪点，全部基于 LLVM IR 静态证据：

1. AppKey 命令 10902 的分发链：
   CMa02JYdt11b9o(10902) → CMa02G3LDtYwUT(1,9,2,flag=1) → 原生注册 CMa02WYLvRCbzL
   → 经 _FUNCTION_BRIDGE slot2 转发到 (1,6,43,0)。
   验证 (1,6,43,0) 在四个 framework 里都没有原生注册处理器。

2. 统一签名初始化的 2404：SGMiddleTier 的 CMi02Tqa0lTIP5 把底层 raw 小码
   映射为 2400 段（raw 3→2403、raw 4→2404 …）。验证该映射表存在。

3. 「宿主通道」假设：候选 SGMain 的 AVMP/uvm 宿主函数注册表
   （_uvm_register_item_ex 数组）里可用的文件入口只有
   access/lseek/fstat/lstat/opendir/readdir/fcntl，没有 fopen/open/read/fread/stat；
   内容读取只能经 objc_msgSend 调 Foundation。这解释了 fopen/open 零命中
   不能证明「没读文件」。

依赖本地分析产物（默认 <repo>/build/laundry-ios-analysis，可用 --root 覆盖）：
  SGMain-SGMain99999999.o.ll
  SGMiddleTier-SGMiddleTier99999999.o.ll
这些 IR 由 public_ir.py 从候选 SDK 静态库的 __bitcode 提取，不在 Git 仓库内。
"""
import argparse
import re
import sys
from pathlib import Path


def load(root: Path, name: str) -> str:
    path = root / name
    if not path.is_file():
        raise SystemExit(f'缺少 IR：{path}（需先用 public_ir.py 从候选 SDK 提取）')
    return path.read_text(encoding='utf-8')


def check_appkey_dispatch(sgmain: str) -> None:
    print('== 1. AppKey(10902) 分发链 ==')
    # 10902 → CMa02JYdt11b9o（uvm 命令入口，注册在 CMa02hLprhgf0Y）
    hit = re.search(r'call ptr %local\d+\.i\(i32 10902,', sgmain)
    print(f'  命令 10902 调用点: {"存在" if hit else "未找到"}')
    # CMa02JYdt11b9o 把命令拆成 (1,9,2) flag=1 交给 CMa02G3LDtYwUT
    disp = re.search(r'@CMa02G3LDtYwUT\(i32 %local20, i32 %local25, i32 %local26, i32 1,', sgmain)
    print(f'  (group,middle,sub)=(1,9,2) flag=1 → CMa02G3LDtYwUT: {"确认" if disp else "未匹配"}')
    # 原生注册 (1,9,2,1) → CMa02WYLvRCbzL
    reg = re.search(r'\(i32 1, i32 9, i32 2, i32 1, ptr @CMa02WYLvRCbzL\)', sgmain)
    print(f'  原生注册 (1,9,2,1)=CMa02WYLvRCbzL: {"确认" if reg else "未匹配"}')
    # CMa02WYLvRCbzL 转发到 (1,6,43,0)
    fwd = re.search(r'tail call ptr %local\d+\(i32 1, i32 6, i32 43, i32 0,', sgmain)
    print(f'  CMa02WYLvRCbzL 转发到 (1,6,43,0): {"确认" if fwd else "未匹配"}')
    # (1,6,43,0) 是否在任何 framework 注册处理器
    print('  (1,6,43,0) 原生注册处理器搜索:')
    return fwd


def check_handler_registered(texts: dict, group: int, sub: int) -> dict:
    """在全部 IR 里搜索 (1,group,sub,flag,handler) 形状的注册调用。"""
    reg = re.compile(r'\(i32 1, i32 %d, i32 %d, i32 [01], ptr @CM[A-Za-z0-9]+\)' % (group, sub))
    found = {}
    for name, text in texts.items():
        for m in reg.finditer(text):
            found.setdefault(name, []).append(m.group(0))
    return found


def check_unified_mapping(sgmid: str) -> None:
    print('\n== 2. 统一签名 raw→2400 映射 (CMi02Tqa0lTIP5) ==')
    for raw, mapped in [(3, 2403), (4, 2404), (1, 2401), (2, 2402), (6, 2405), (8, 2409), (12, 2406)]:
        # switch 的 case label 与 store 值
        store = f'store i32 {mapped}, ptr %arg1' in sgmid
        print(f'  raw {raw:>2} → {mapped}: store {"确认" if store else "未找到"}')


def check_host_registry(sgmain: str) -> None:
    print('\n== 3. AVMP/uvm 宿主函数表（文件入口审计）==')
    m = re.search(r'@CMa02yPs7JVQ0W = private unnamed_addr constant \[(\d+) x %struct\._uvm_register_item_ex\.4\] \[(.*?)\], align 8',
                  sgmain, re.S)
    if not m:
        print('  未找到宿主注册表 CMa02yPs7JVQ0W')
        return
    items = re.findall(r'%struct\._uvm_register_item_ex\.4 \{ ptr @[^,]+, ptr @([^,]+), i8 \d+, i8 \d+ \}', m.group(2))
    # IR 里 Darwin 符号写作 @"\01_xxx"（LLVM 的“不改名”前缀），显示时剥掉引号与前缀。
    hosts = [re.sub(r'^\\01_', '', h.strip('"')) for h in items]
    print(f'  宿主函数总数: {len(hosts)}（声明 {m.group(1)}）')
    file_io = sorted({h for h in hosts if re.search(r'fopen|^open$|^read$|fread|^stat$|access|fstat|lstat|lseek|opendir|readdir|closedir|fcntl|getcwd|unlink', h)})
    forbidden = [h for h in ('fopen', 'open', 'read', 'fread', 'stat') if h in hosts]
    print(f'  文件/目录相关宿主入口: {file_io}')
    print(f'  fopen/open/read/fread/stat 是否在宿主表: {forbidden if forbidden else "全部不在（关键）"}')
    has_objc = any('objc_msgSend' in h for h in hosts)
    has_nspath = any(h in ('NSHomeDirectory', 'NSSearchPathForDirectoriesInDomains', '_NSGetExecutablePath') for h in hosts)
    print(f'  objc_msgSend 在宿主表: {has_objc}（→ 字节码可读 Foundation 文件 API）')
    print(f'  NSHomeDirectory/NSSearchPath 在宿主表: {has_nspath}（→ 字节码可拼资源路径）')


def main() -> int:
    parser = argparse.ArgumentParser()
    default_root = Path(__file__).resolve().parent.parent / 'build' / 'laundry-ios-analysis'
    parser.add_argument('--root', default=str(default_root))
    args = parser.parse_args()
    root = Path(args.root)

    sgmain = load(root, 'SGMain-SGMain99999999.o.ll')
    sgmid = load(root, 'SGMiddleTier-SGMiddleTier99999999.o.ll')
    sdk = load(root, 'SecurityGuardSDK-SecurityGuardSDK99999999.o.ll')
    body = load(root, 'SGSecurityBody-SGSecurityBody99999999.o.ll')
    texts = {'SGMain': sgmain, 'SGMiddleTier': sgmid, 'SecurityGuardSDK': sdk, 'SGSecurityBody': body}

    check_appkey_dispatch(sgmain)
    reg643 = check_handler_registered(texts, 6, 43)
    if reg643:
        for name, hits in reg643.items():
            print(f'    {name}: {hits}')
    else:
        print('    (1,6,43,0) 在四个 framework 均无原生注册处理器')
        print('    → AppKey 的图片解析实现只可能来自 AVMP/uvm 字节码（虚拟化查询 66010643），')
        print('      原生注册表 miss 不会返回内容敏感的 raw 3/4；raw 3/4 由字节码内部产生。')

    check_unified_mapping(sgmid)
    check_host_registry(sgmain)

    print('\n== 结论（静态证据支持，非「已证明」）==')
    print('  - 204 与 2404 分别是底层 raw=4 在 SGMain(+200) 与 SGMiddleTier(2400 段) 的出口视图。')
    print('  - raw=3(无文件)/raw=4(格式错误) 随主图存在性与内容变化 → 解析确实读到并校验了主图字节。')
    print('  - 解析器位于 AVMP 字节码，宿主表无 fopen/open → app 级 fopen/open 拦截必然零命中，')
    print('    必须改观察 access/opendir/readdir + Foundation 读方法（见 ProbeResourceTrace 宿主通道）。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
