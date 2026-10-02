"""针对探针 Objective-C 源文件的轻量静态自检（Windows 侧无 Xcode，只能做文本级核对）。

检查项：
1. 大括号平衡（忽略字符串/字符字面量/注释）——防止 patch 过程中截断函数。
2. 每个探针里用到的 ProbeOriginal* 函数指针都有对应的 dlsym 解析与声明。
3. 声明与定义不成对的符号（例如已删除的 read/pread 拦截不得有残留引用）。
4. 报告文案里出现的通道名必须与 ProbeHostChannelNames 一一对应。
只读，不修改任何文件。
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
TOOLS = root / 'tools' / 'ios-component-probe'
impl = (TOOLS / 'ProbeResourceTrace.m').read_text(encoding='utf-8', errors='replace')
tests = (TOOLS / 'ProbeTests.m').read_text(encoding='utf-8', errors='replace')
header = (TOOLS / 'ProbeResourceTrace.h').read_text(encoding='utf-8', errors='replace')

errors = []


def strip_noise(text):
    """去掉注释与字符串/字符字面量，避免把字面量里的花括号计入平衡。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == '/*':
            end = text.find('*/', i + 2)
            i = n if end < 0 else end + 2
            continue
        if two == '//':
            end = text.find('\n', i)
            i = n if end < 0 else end
            continue
        if two == '@"':
            i += 2
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
            i += 1
            continue
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
            i += 1
            continue
        if ch == "'":
            i += 1
            while i < n and text[i] != "'":
                i += 2 if text[i] == '\\' else 1
            i += 1
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


# 1. 括号平衡
for name, text in [('ProbeResourceTrace.m', impl), ('ProbeTests.m', tests),
                   ('ProbeResourceTrace.h', header)]:
    clean = strip_noise(text)
    for opener, closer in (('{', '}'), ('(', ')'), ('[', ']')):
        delta = clean.count(opener) - clean.count(closer)
        if delta != 0:
            errors.append(f'{name} {opener}{closer} 不平衡：相差 {delta}')

# 2. ProbeOriginal* 声明与赋值齐备。
# 声明形式是函数指针：static <ret> (*ProbeOriginalXxx)(args);
# 赋值分两类：C 函数指针经 dlsym 解析；ObjC 的 IMP 指针经
# ProbeInstallInterceptor 的出参 (IMP *)&ProbeOriginalXxx 赋值，不走 dlsym。
declared = set(re.findall(r'\(\*(ProbeOriginal\w+)\)\s*\(', impl))
dlsym_resolved = set(re.findall(r'(ProbeOriginal\w+)\s*=\s*\(', impl))
imp_resolved = set(re.findall(r'\(IMP \*\)&(ProbeOriginal\w+)', impl))
resolved = dlsym_resolved | imp_resolved
# 调用点：名字后紧跟左括号（声明处是 ) 紧跟，不会误配）。
used = set(re.findall(r'(ProbeOriginal\w+)\s*\(', impl)) - declared
for name in sorted(declared):
    if name not in resolved:
        errors.append(f'{name} 已声明但没有被赋值（dlsym 或 IMP 出参）')
for name in sorted(resolved - declared):
    errors.append(f'{name} 被赋值但没有声明')
for name in sorted(used - declared):
    errors.append(f'{name} 被调用但没有声明')
# IMP 出参的指针必须真的被 ProbeInstallInterceptor 消费，否则拦截形同未装。
intercept_calls = re.findall(r'ProbeInstallInterceptor\([^;]*?\(IMP \*\)&(ProbeOriginal\w+)\)', impl, re.S)
if len(intercept_calls) != len(imp_resolved):
    errors.append(f'ProbeInstallInterceptor 调用数 {len(intercept_calls)} 与 IMP 出参数 '
                  f'{len(imp_resolved)} 不一致')
for name in sorted(imp_resolved - set(intercept_calls)):
    errors.append(f'{name} 取地址但不是 ProbeInstallInterceptor 的出参')

# 3. 已移除的 read/pread 拦截不得残留引用
for banned in ['ProbeOriginalRead', 'ProbeOriginalPread', 'ProbeMandatoryChannels',
               'ProbeBestEffortChannels', 'ProbeHostChannelReaddir']:
    if banned in impl or banned in tests:
        errors.append(f'残留已移除的符号引用：{banned}')
# read/pread 不得再被定义为拦截入口
for sig in [r'^ssize_t read\(int fd', r'^ssize_t pread\(int fd']:
    if re.search(sig, impl, re.M):
        errors.append(f'不应存在拦截定义：{sig}')

# 4. 通道名与报告一致
names = re.search(r'ProbeHostChannelNames\[ProbeHostChannelCount\] = \{([^}]*)\}', impl, re.S)
if not names:
    errors.append('找不到 ProbeHostChannelNames 定义')
else:
    channels = re.findall(r'"(\w+)"', names.group(1))
    if not re.search(r'ProbeHostChannelCount', impl):
        errors.append('缺少 ProbeHostChannelCount 枚举')
    # 只从 enum 体内取 ProbeHostChannel* 成员，避免把 typedef ProbeHostChannelIndex 算进去。
    enum_body = re.search(r'enum\s*\{([^}]*)\}\s*;', impl, re.S)
    enum_members = []
    if enum_body:
        for token in re.findall(r'(ProbeHostChannel\w+)', enum_body.group(1)):
            if token != 'ProbeHostChannelCount' and token not in enum_members:
                enum_members.append(token)
    if len(enum_members) != len(channels):
        errors.append(f'枚举成员 {len(enum_members)} 个与通道名 {len(channels)} 个不一致：'
                      f'{enum_members} vs {channels}')
    # 测试里断言过的通道名都必须真实存在，且每条通道都要被断言。
    test_channels = re.search(r'const char \*channels\[\] = \{([^}]*)\}', tests, re.S)
    asserted = set(re.findall(r'HostReport\(rows, @"(\w+)"\)', tests))
    if test_channels:
        asserted |= set(re.findall(r'"(\w+)"', test_channels.group(1)))
    for name in sorted(asserted - set(channels)):
        errors.append(f'测试断言了不存在的通道：{name}')
    missing = set(channels) - asserted
    if missing:
        errors.append(f'以下通道没有被测试断言：{sorted(missing)}')

# 5. 自检判据与窗口否决
if 'record->calls > 0 && (record->target > 0 || record->scoped > 0)' not in impl:
    errors.append('宿主通道自检判据缺失')
if 'valid = valid && record->selfChecked' in impl:
    errors.append('宿主通道自检不得否决窗口有效性')
if 'selfChecked' not in impl:
    errors.append('缺少 selfChecked 标注')

# 6. 死锁防御：持锁路径内调用 fstat/pread 必须先抬高 ProbeHostDepth
if 'ProbeHostDepth++;' not in impl:
    errors.append('缺少 ProbeHostDepth 抑制，内部读取可能递归计数')

print('探针静态自检：')
if errors:
    for item in errors:
        print('  ✗', item)
    sys.exit(1)
print('  全部通过（括号平衡、函数指针配对、通道名一致、自检判据、递归抑制）')
